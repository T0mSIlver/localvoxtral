import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

extension ClaudeSessionJoinResolver {
    package func resolveViaHerdr(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        // herdr 0.9 attaches several machines to one client, and while a remote
        // machine is selected the local server keeps a focused pane it has
        // merely stopped presenting. `pane.current` below would then describe a
        // pane nobody is looking at, and every cross-check in this arm would
        // pass on it, so the federation state is read BEFORE the socket
        // question is asked at all (issue #286).
        switch herdrFederation() {
        case .notFederated:
            break
        case .showingMachine(let profile):
            // The selection NAMES the machine, which is exactly what the
            // local arm cannot do with it — so instead of abstaining (#290),
            // the federated arm takes over and resolves against that
            // machine's own herdr, over the app-managed forward.
            return await resolveViaFederatedHerdr(target: target, profile: profile)
        case .unreadable:
            Self.abstainedHerdrJoin(outcome: "herdr machine state unreadable")
            return nil
        case .showingLocal:
            // The selection is one per USER, not one per client: the last
            // client to switch machines wins the file
            // (herdr `src/client/endpoint/catalog.rs`). With a second client on
            // screen it cannot say which machine the FOCUSED surface shows, so
            // only a lone client surface may rely on it. Gated on machines
            // being saved, which leaves every user without them free to keep
            // two herdr windows open.
            guard herdrClientSurfaceCount() == 1 else {
                Self.abstainedHerdrJoin(
                    outcome: "machines are saved and this user has more than one herdr surface"
                )
                return nil
            }
        }

        guard let (pane, snapshot, socketPath) = await focusedLocalHerdrPaneSession(
            abstain: { Self.abstainedHerdrJoin(outcome: $0) }
        ) else { return nil }

        Log.claudeContext.info("Terminal pane joined to a live Claude session via herdr pane")
        return ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .herdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath)
        )
    }

    /// The local herdr arm's pane question, once the surface is bound to a
    /// herdr client showing the local machine: the one live local socket's
    /// focused pane, the live local session registered in it, herdr's own
    /// session claim not disagreeing, and that session's pid in the pane's
    /// foreground. Shared by the context join and the opencode relay
    /// lookup (#733), which must accept exactly what the join accepts.
    package func focusedLocalHerdrPaneSession(
        abstain: (String) -> Void
    ) async -> (pane: HerdrFocusedPane, snapshot: ClaudeSessionSnapshot, socketPath: String)? {
        let sockets = registry.liveLocalHerdrSocketPaths()
        guard sockets.count == 1, let socketPath = sockets.first else {
            abstain(sockets.isEmpty ? "no live registered socket" : "multiple live sockets")
            return nil
        }
        guard let herdrPanes else {
            abstain("pane query capability unavailable")
            return nil
        }
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            abstain("focused pane unavailable")
            return nil
        }

        let snapshot: ClaudeSessionSnapshot
        switch registry.resolve(herdrPaneID: pane.paneID) {
        case .resolved(let resolved):
            snapshot = resolved
        case .unknown:
            abstain("focused pane has no live session")
            return nil
        case .stale:
            abstain("focused pane session stale")
            return nil
        case .ambiguous:
            abstain("focused pane session ambiguous")
            return nil
        }

        // herdr reports the agent's RAW session id; the registry speaks
        // agent-scoped ids (`ClaudeAgentSessionScope`). Scope the claim by the
        // resolved session's own agent before comparing — for Claude that is
        // the identity function, for opencode it adds the same prefix ingest
        // did. Scoping by the snapshot's agent (not by anything herdr says)
        // keeps this a pure cross-check: a claim can only ever CONFIRM the
        // pane-id join, never redirect it.
        if let claimed = pane.claimedClaudeSessionID,
           ClaudeAgentSessionScope.scopedSessionID(
               agent: snapshot.agent, sessionID: claimed
           ) != snapshot.sessionID {
            abstain("pane session claim disagrees")
            return nil
        }
        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            abstain("foreground process query unavailable")
            return nil
        }
        guard let foregroundPIDs = foreground.foregroundPIDs else {
            abstain("foreground process detection unavailable")
            return nil
        }
        guard Self.registeredAgentIsForeground(
            snapshot: snapshot, foregroundPIDs: foregroundPIDs, abstain: abstain
        ) else { return nil }
        return (pane, snapshot, socketPath)
    }

    /// The joined herdr pane's visible text, or nil on any refusal or failure.
    ///
    /// This is the ONLY path that issues a `pane.read`, and it can only read
    /// the pane the join resolved to: the request is keyed by the binding the
    /// herdr arm captured at resolution time, so no other pane — and no other
    /// join mechanism — can reach herdr's socket through it. The returned text
    /// is RAW wire text; the caller owns sanitization, bounding, and every
    /// consent gate (see `SocketPaneScreenContext`).
    package func herdrPaneVisibleText(for join: ClaudeSessionJoin) async -> String? {
        guard join.mechanism == .herdrPane
            || join.mechanism == .remoteHerdrPane
            || join.mechanism == .federatedHerdrPane,
            let binding = join.herdrPane
        else {
            Log.claudeContext.info("Herdr pane read refused: join is not a herdr pane join")
            return nil
        }
        guard let herdrPanes else {
            Log.claudeContext.info("Herdr pane read refused: pane query capability unavailable")
            return nil
        }
        return await herdrPanes.paneVisibleText(
            socketPath: binding.socketPath, paneID: binding.paneID
        )
    }

    /// The route that writes this dictation into the joined herdr pane
    /// (#726), or nil when the join is not a herdr pane join. Like
    /// `herdrPaneVisibleText(for:)`, it is keyed by the binding the arm
    /// captured, so it reaches only the pane the join resolved, over the
    /// socket (or forward) the join already trusted. Before each Enter it
    /// asks that pane again whether the joined agent is foreground, with the
    /// same test the arm joined on: the pid for a local pane, the parent pid
    /// or agent name for a remote one. `frontmostPID` names the app keys
    /// would go to, for the fallback's choice between typing and History.
    package func herdrPromptRoute(
        for join: ClaudeSessionJoin,
        frontmostPID: @escaping @MainActor () -> pid_t?
    ) -> HerdrPanePromptRoute? {
        let mechanism = join.mechanism
        guard mechanism == .herdrPane
            || mechanism == .remoteHerdrPane
            || mechanism == .federatedHerdrPane,
            let binding = join.herdrPane
        else { return nil }
        return herdrPromptRoute(
            binding: binding,
            snapshot: join.snapshot,
            mechanism: mechanism,
            terminalPID: join.target.pid,
            frontmostPID: frontmostPID
        )
    }

    /// The route over one herdr pane binding, found by a join or by the
    /// local lookup without one (#759).
    package func herdrPromptRoute(
        binding: ClaudeHerdrPaneBinding,
        snapshot: ClaudeSessionSnapshot,
        mechanism: ClaudeSessionJoinMechanism,
        terminalPID: pid_t,
        frontmostPID: @escaping @MainActor () -> pid_t?
    ) -> HerdrPanePromptRoute? {
        guard let writer = herdrPaneWriter, let panes = herdrPanes else { return nil }
        return HerdrPanePromptRoute(
            binding: binding,
            writer: writer,
            agentIsForeground: { @MainActor in
                guard let processes = await panes.paneForegroundInfo(
                    socketPath: binding.socketPath, paneID: binding.paneID
                )?.foregroundProcesses else { return false }
                if mechanism == .herdrPane {
                    guard let pid = snapshot.process?.claudePID else { return false }
                    return processes.contains { $0.pid == pid }
                }
                return Self.remoteAgentIsForeground(
                    snapshot: snapshot, foregroundProcesses: processes, noteAbstention: { _ in }
                )
            },
            keysReachThePane: { @MainActor in
                // The frontmost app is read after the socket answers, so a
                // focus change during the query is seen.
                let paneFocused = await panes.focusedPane(socketPath: binding.socketPath)?.paneID == binding.paneID
                return paneFocused && frontmostPID() == terminalPID
            }
        )
    }

    /// Pure pid cross-check kept visible to tests because a snapshot with no
    /// process cannot be produced by a successful pane-id registry lookup, but
    /// the resolver must still fail closed if that invariant ever changes.
    /// Agent-neutral (review F3): the pane may host Claude Code or opencode,
    /// and the registered pid is whichever agent process the session's records
    /// named — the abstention wording must not claim Claude for both.
    package static func registeredAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundPIDs: [Int32],
        abstain: (String) -> Void
    ) -> Bool {
        guard let process = snapshot.process else {
            abstain("registered session has no process metadata")
            return false
        }
        guard foregroundPIDs.contains(process.claudePID) else {
            abstain("registered \(snapshot.agent.rawValue) process is not foreground")
            return false
        }
        return true
    }

    package static func registeredAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundPIDs: [Int32]
    ) -> Bool {
        registeredAgentIsForeground(snapshot: snapshot, foregroundPIDs: foregroundPIDs) {
            abstainedHerdrJoin(outcome: $0)
        }
    }

    /// Outcome only: pane ids, socket paths, tty paths, and payload contents are
    /// all live join material and never belong in the unified log.
    private static func abstainedHerdrJoin(outcome: String) {
        Log.claudeContext.info(
            "Herdr pane matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("herdr: \(outcome)")
    }
}
