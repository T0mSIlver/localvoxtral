import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

extension ClaudeSessionJoinResolver {
    // MARK: - The federated herdr arm (herdr 0.9, `.showingMachine`)

    /// A Claude Code session inside the herdr on the machine a LOCAL herdr
    /// 0.9 client is showing (issue #288, Part B).
    ///
    /// This arm runs only from `resolveViaHerdr`'s `.showingMachine` dispatch:
    /// the surface is already bound to a herdr client by `HerdrClientTTYProbe`
    /// (herdr-or-nothing from there), and herdr's own selection state has
    /// NAMED the machine — the one fact every other remote arm has to infer
    /// from an ssh argv this surface does not have. There is no ssh on the
    /// surface at all, which is why `.remoteHerdrPane` abstains by
    /// construction here and why this arm's evidence is an entirely different
    /// set:
    ///
    /// 1. a LONE herdr client surface — the selection is one per USER, not
    ///    one per client, so a second client on screen makes it unable to say
    ///    which machine the FOCUSED surface shows (same reason as the Local
    ///    arm's #290 guard);
    /// 2. the selected machine's `target` names exactly one non-revoked
    ///    enrolled host (exact alias first, then `ssh -G` canonicalization,
    ///    which parses the `ssh://user@host:port` URI targets `herdr machine
    ///    add` saves);
    /// 3. that host has live sessions on exactly ONE socket that is the
    ///    socket of the profile's named herdr session
    ///    (`HerdrSessionSocket`); two herdr servers answering for the same
    ///    session name leave the surface ambiguous;
    /// 4. over the app-managed forward, the shared pane confirmation set
    ///    (`confirmRemoteHerdrPane`): exactly one candidate claims the
    ///    focused pane id, herdr's own `agent_session` claim does not
    ///    disagree, and the registered agent is in the pane's foreground;
    /// 5. the agents-panel nonce, REQUIRED, as the SURFACE confirmation: the
    ///    stamped pane must render the fresh token in the focused grid. On a
    ///    0.9 client that proves the surface is a WHOLE-VIEW client that
    ///    federates this server (an attach/observe surface renders no sidebar).
    ///    It does NOT name the machine — the selection state did, in step 2 —
    ///    because a 0.9 client composes its agents panel from every federated
    ///    machine at once and marks the active one by background color, which a
    ///    text grid read cannot see. And it does NOT prove the selection is
    ///    fresh: a token stamped on machine B's pane renders while the surface
    ///    shows A, so a selection file lagging the live client still joins B.
    ///    That lag is bounded by the lone-surface rule and herdr's own
    ///    selection writes, and closing it needs an upstream herdr change (an
    ///    active-endpoint report on the socket), not a stronger token.
    ///
    /// Speculative probing does not exist in this arm: the machine is named,
    /// so exactly one server is stamped, once, and only after every pane-level
    /// confirmation has passed. On match the token stays lit as the dictation's
    /// mic indicator, exactly like the `.remoteHerdrPane` panel path.
    ///
    /// Every failure is a distinct content-free cause through
    /// `abstainedFederatedHerdrJoin` — log plus dogfood tap — and every one
    /// abstains: with the surface positively bound to herdr there is no weaker
    /// arm underneath to fall through to.
    package func resolveViaFederatedHerdr(
        target: TerminalScreenTarget,
        profile: HerdrMachineProfile
    ) async -> ClaudeSessionJoin? {
        // 1. A lone client surface. The selection file is rewritten by the
        // last client to switch machines, so it can only speak for the focused
        // surface when it is the only one (herdr
        // `src/client/endpoint/catalog.rs`; the same reasoning as #290).
        guard herdrClientSurfaceCount() == 1 else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "the machine selection is per user and cannot speak for "
                    + "one of several herdr surfaces"
            )
            return nil
        }

        // 2. The machine's target names the enrolled host. Exact alias
        //    equality first; only when that finds nothing, `ssh -G`
        //    canonicalization — the same order and the same seams the argv
        //    arm uses, so no new process runs on the joining path. The exact
        //    hits are filtered to non-revoked hosts with an alias here, like
        //    the panel path filters its own: a withdrawn credential must read
        //    as "matches no enrolled host", never as a join.
        var hosts = enrolledHosts(profile.target).filter {
            !$0.isRevoked && $0.sshHostAlias != nil
        }
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(profile.target)
        }
        guard !hosts.isEmpty else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "the selected machine's target matches no enrolled host"
            )
            return nil
        }
        guard hosts.count == 1, let host = hosts.first, let alias = host.sshHostAlias else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "the selected machine's target matches several enrolled hosts"
            )
            return nil
        }

        // 3. Live sessions on the selected herdr session's socket. herdr
        //    derives that socket from the session name alone, so the
        //    classification is pure path shape — and two distinct paths both
        //    classifying for one session name means two herdr servers (say, a
        //    relocated XDG config dir and a stock one) with no way to tell
        //    which one this client federates. The count is over NORMALIZED
        //    paths (`HerdrSessionSocket`): two spellings of one server are one
        //    server, and the forward opens the normalized spelling so a
        //    trailing `/.` cannot break the connect.
        let candidates = registry.liveRemoteHerdrSessions(hostID: host.id).filter {
            guard let path = $0.remoteSessionEnvironment?.herdrSocketPath else { return false }
            return HerdrSessionSocket.isSocket(path, ofSessionNamed: profile.session)
        }
        let socketPaths = Set(candidates.compactMap {
            $0.remoteSessionEnvironment?.herdrSocketPath.map(HerdrSessionSocket.normalizedSocketPath)
        })
        guard !socketPaths.isEmpty else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "no live session on the selected herdr session"
            )
            return nil
        }
        guard socketPaths.count == 1, let remoteSocketPath = socketPaths.first else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "two herdr servers answer for the selected herdr session"
            )
            return nil
        }

        // 4. The forward and the shared pane confirmations. The capabilities
        //    are the ones the argv arm requires too; a resolver constructed
        //    without them (a test that forgot, or `--probe-surface`) must get
        //    an abstention, never a spawn.
        guard let remoteHerdrForwards,
              let herdrPanes,
              let herdrPanelMetadata
        else {
            Self.abstainedFederatedHerdrJoin(
                outcome: "forward or panel capability unavailable"
            )
            return nil
        }
        guard let forward = await remoteHerdrForwards.open(
            alias: alias, remoteSocketPath: remoteSocketPath
        ) else {
            Self.abstainedFederatedHerdrJoin(outcome: "forward unavailable")
            return nil
        }
        guard let confirmed = await Self.confirmRemoteHerdrPane(
            herdrPanes: herdrPanes,
            socketPath: forward.localSocketPath,
            hostID: host.id,
            candidates: candidates,
            noteAbstention: { Self.abstainedFederatedHerdrJoin(outcome: $0) }
        ) else {
            forward.close()
            return nil
        }

        // 5. The panel nonce as the surface confirmation. One server, one
        //    stamp, and only now that every pane-level check has passed — a
        //    nonce must not flash in a panel whose join is about to be refused
        //    anyway.
        let probe = HerdrPanelBindingProbe(
            metadata: herdrPanelMetadata,
            readGrid: readFocusedGrid,
            now: panelNow,
            sleepFor: panelSleepFor,
            randomBits: panelRandomBits
        )
        switch await probe.probe(
            target: target,
            socketPath: forward.localSocketPath,
            paneID: confirmed.pane.paneID
        ) {
        case .matched(let match):
            Log.claudeContext.info(
                "Terminal pane joined to a live Claude session via federated herdr agents-panel binding"
            )
            return ClaudeSessionJoin(
                target: target,
                snapshot: confirmed.snapshot,
                windowID: focusedWindowID(target.pid),
                mechanism: .federatedHerdrPane,
                herdrPane: ClaudeHerdrPaneBinding(
                    paneID: confirmed.pane.paneID, socketPath: forward.localSocketPath
                ),
                remoteHerdrForward: forward,
                remoteHerdrIndicator: HerdrPanelMicIndicator(
                    metadata: herdrPanelMetadata,
                    socketPath: forward.localSocketPath,
                    paneID: confirmed.pane.paneID,
                    token: match.token,
                    forward: forward,
                    sleepFor: indicatorSleepFor
                )
            )
        case .noMatch(let cause):
            HerdrPanelBindingProbe.noteAbstention(cause)
            // The machine is named and one server was stamped once, so a
            // stamped token that never rendered is the destination-known
            // case the remote arm diagnoses — except the row lives in the
            // LOCAL herdr config on a 0.9 client (`ClientShellConfig`
            // reads `config.ui.sidebar.agents` on the machine the client
            // runs on), so the hint points there, and at the one residual
            // the app cannot do itself: the app cannot reliably locate the
            // herdr binary to run `herdr server reload-config`.
            if cause == .settleTimeout {
                Log.claudeContext.info(
                    "Federated herdr panel token was stamped but did not render; check the LOCAL agents-panel row config, the sidebar width, and whether the entry fits this client's height, then reload config in herdr"
                )
            }
            // A truncated row is the OPPOSITE diagnosis: the row is
            // configured and rendering, and herdr cut the token to the
            // sidebar's column budget (field abstention 2026-09-05).
            if cause == .rowTruncated {
                Log.claudeContext.info(
                    "Federated herdr panel row rendered a TRUNCATED token; widen the herdr sidebar or make the $lvmark row the agent entry's first row"
                )
            }
            await HerdrPanelBindingProbe.clear(
                metadata: herdrPanelMetadata,
                socketPath: forward.localSocketPath,
                paneID: confirmed.pane.paneID
            )
            forward.close()
            Self.abstainedFederatedHerdrJoin(
                outcome: "federated-panel-not-rendered (\(cause.rawValue))"
            )
            return nil
        }
    }

    /// Outcome only, mirroring the other arms' sinks: machine targets name
    /// the user's infrastructure, and socket paths, pane ids and nonce values
    /// are all live join material — none of it belongs in the unified log.
    private static func abstainedFederatedHerdrJoin(outcome: String) {
        Log.claudeContext.info(
            "Federated herdr pane matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("federated-herdr: \(outcome)")
    }
}
