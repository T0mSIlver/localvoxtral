import ClaudeContextWire
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

extension ClaudeSessionJoinResolver {
    func resolveViaHerdr(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
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

        let sockets = registry.liveLocalHerdrSocketPaths()
        guard sockets.count == 1, let socketPath = sockets.first else {
            Self.abstainedHerdrJoin(
                outcome: sockets.isEmpty ? "no live registered socket" : "multiple live sockets"
            )
            return nil
        }
        guard let herdrPanes else {
            Self.abstainedHerdrJoin(outcome: "pane query capability unavailable")
            return nil
        }
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            Self.abstainedHerdrJoin(outcome: "focused pane unavailable")
            return nil
        }

        let snapshot: ClaudeSessionSnapshot
        switch registry.resolve(herdrPaneID: pane.paneID) {
        case .resolved(let resolved):
            snapshot = resolved
        case .unknown:
            Self.abstainedHerdrJoin(outcome: "focused pane has no live session")
            return nil
        case .stale:
            Self.abstainedHerdrJoin(outcome: "focused pane session stale")
            return nil
        case .ambiguous:
            Self.abstainedHerdrJoin(outcome: "focused pane session ambiguous")
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
            Self.abstainedHerdrJoin(outcome: "pane session claim disagrees")
            return nil
        }
        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            Self.abstainedHerdrJoin(outcome: "foreground process query unavailable")
            return nil
        }
        guard let foregroundPIDs = foreground.foregroundPIDs else {
            Self.abstainedHerdrJoin(outcome: "foreground process detection unavailable")
            return nil
        }
        guard Self.registeredAgentIsForeground(
            snapshot: snapshot, foregroundPIDs: foregroundPIDs
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

    /// The joined herdr pane's visible text, or nil on any refusal or failure.
    ///
    /// This is the ONLY path that issues a `pane.read`, and it can only read
    /// the pane the join resolved to: the request is keyed by the binding the
    /// herdr arm captured at resolution time, so no other pane — and no other
    /// join mechanism — can reach herdr's socket through it. The returned text
    /// is RAW wire text; the caller owns sanitization, bounding, and every
    /// consent gate (see `SocketPaneScreenContext`).
    func herdrPaneVisibleText(for join: ClaudeSessionJoin) async -> String? {
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

    /// Pure pid cross-check kept visible to tests because a snapshot with no
    /// process cannot be produced by a successful pane-id registry lookup, but
    /// the resolver must still fail closed if that invariant ever changes.
    /// Agent-neutral (review F3): the pane may host Claude Code or opencode,
    /// and the registered pid is whichever agent process the session's records
    /// named — the abstention wording must not claim Claude for both.
    static func registeredAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundPIDs: [Int32]
    ) -> Bool {
        guard let process = snapshot.process else {
            abstainedHerdrJoin(outcome: "registered session has no process metadata")
            return false
        }
        guard foregroundPIDs.contains(process.claudePID) else {
            abstainedHerdrJoin(
                outcome: "registered \(snapshot.agent.rawValue) process is not foreground"
            )
            return false
        }
        return true
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
