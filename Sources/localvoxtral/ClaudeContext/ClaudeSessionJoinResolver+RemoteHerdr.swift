import ClaudeContextWire
import CoreGraphics
import Foundation

extension ClaudeSessionJoinResolver {
    /// What the remote herdr arm concluded.
    ///
    /// One decline, not three. The arm used to distinguish "nothing here is
    /// about a remote herdr" from "this surface IS an enrolled host's herdr
    /// and the join still failed" (and a third case for an ssh present but
    /// unreadable) because those three chose differently between falling
    /// through to a window-title marker and stopping the dictation's join
    /// dead. With no title arm left there is nothing to fall through TO, so
    /// every non-join is one answer: this arm has no session for you. The
    /// CAUSES stay distinct — each decline still logs and taps its own
    /// content-free string, which is what the dogfood record and
    /// `--probe-surface` read.
    enum RemoteHerdrArmOutcome {
        case declined
        case joined(ClaudeSessionJoin)
    }

    /// A Claude Code session inside a herdr on an ENROLLED REMOTE host.
    ///
    /// The agents-panel nonce is the primary surface authorization. A readable
    /// ssh destination narrows it to one enrolled host; otherwise up to three
    /// live herdr-bearing hosts are tried. Only when that proof cannot render
    /// does the pre-existing argv path below become the fallback.
    ///
    /// The fallback bindings, all required, remain:
    /// 1. the focused surface's TTY hosts EXACTLY ONE foreground ssh session,
    ///    whose destination is exactly one enrolled host's alias. One, because
    ///    several in a group cannot be told apart from here and unioning them
    ///    let a plain connection borrow a sibling's herdr signal (round 7).
    ///    This is the only step that says anything about what the user is
    ///    looking at;
    /// 2. that CONNECTION is bound to herdr, and it takes BOTH facts: the ssh
    ///    argv names herdr as its remote command (first token), AND this
    ///    terminal holds the only ssh connection to that destination on the
    ///    machine. Neither alone is enough — uniqueness does not say what the
    ///    terminal DISPLAYS (a detached herdr still answers `pane.current`),
    ///    and argv is written by whoever launched the process;
    /// 3. that host has live sessions reporting a herdr pane, all from ONE herdr
    ///    socket. This counts SOCKETS, not sessions: several live sessions on
    ///    one herdr are expected and fine — panes are what a multiplexer is for
    ///    — and it is two herdr SERVERS that leave the surface ambiguous;
    /// 4. over the forward, exactly ONE of those candidates claims that herdr's
    ///    FOCUSED pane id (two claiming the same pane id abstain);
    /// 5. herdr's own session claim for the pane does not disagree, and the pane
    ///    is running that session's agent.
    ///
    /// Every one of these can only ever CONFIRM. No step picks a session because
    /// it is the only one, the most recent, or the one whose cwd looks right.
    func resolveViaRemoteHerdr(
        target: TerminalScreenTarget,
        sshResult: SSHDestinationTTYProbeResult
    ) async -> RemoteHerdrArmOutcome {
        // PRIMARY authorization: stamp each plausible server with a fresh
        // nonce and require that exact value in the focused terminal grid.
        // argv is consulted only after this direct surface proof fails.
        if let panelOutcome = await resolveViaRemoteHerdrPanel(
            target: target,
            sshResult: sshResult
        ) {
            return panelOutcome
        }

        let connection: SSHSurfaceConnection
        switch sshResult {
        case .noSSHClient:
            // The overwhelmingly common case: a local shell. Not logged — this
            // is not an abstention, it is the arm not applying.
            return .declined
        case .undeterminable(let cause):
            // The category is content-free by type (`SSHProbeIndeterminacy` —
            // never a host, path, or option), so it may ride into the log and
            // the dogfood record. Three field dictations were diagnosed blind
            // without it (2026-08-06).
            Self.abstainedRemoteHerdrJoin(outcome: "ssh session undeterminable (\(cause.rawValue))")
            return .declined
        case .connection(let value):
            connection = value
        }

        var hosts = enrolledHosts(connection.destination)
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(connection.destination)
        }
        guard !hosts.isEmpty else {
            // An ssh session to a host the user never enrolled. There is no
            // context to join.
            return .declined
        }
        guard hosts.count == 1, let host = hosts.first, let alias = host.sshHostAlias else {
            Self.abstainedRemoteHerdrJoin(outcome: "ssh destination matches multiple enrolled hosts")
            return .declined
        }

        let candidates = registry.liveRemoteHerdrSessions(hostID: host.id)
        guard !candidates.isEmpty else {
            // Enrolled, but nothing on it reported a herdr pane — a plain
            // remote Claude session, which this arm cannot speak for.
            return .declined
        }
        let socketPaths = Set(candidates.compactMap { $0.remoteSessionEnvironment?.herdrSocketPath })
        guard socketPaths.count == 1, let remoteSocketPath = socketPaths.first else {
            // Mirror of the local single-socket rule: two herdr servers on one
            // host, and no way to tell which one the surface is attached to.
            Self.abstainedRemoteHerdrJoin(outcome: "multiple live herdr sockets on this host")
            return .declined
        }

        // The connection-level bind: this connection's own argv must be a
        // plain herdr whole-view client, and no OTHER connection may be a
        // competing herdr view of the same destination.
        //
        // The invocation requirement is the round-5b lesson unchanged: a herdr
        // whose client detached — or whose pane still runs an agent inside the
        // registry TTL — keeps answering
        // `pane.current`, so being the sole `ssh builder` proves nothing about
        // what this terminal DISPLAYS. herdr exposes no read-only attachment
        // signal (re-verified at v0.8.0 / protocol 19, 2026-08-06: the only
        // `client.*` methods are still `window_title.set`/`clear`, both
        // mutations, and `session.snapshot` has no client records), so the
        // evidence has to come from the invocation — the exec-time argv of a
        // VERIFIED OpenSSH binary, i.e. the command ssh actually ran.
        //
        // The competing-client rule REPLACED machine-wide uniqueness
        // (2026-08-06), on a protocol fact verified in herdr's source: focus
        // is server-global and multi-client attach is a mirror, so a plain
        // shell to the same host cannot be displaying "our" herdr, and a
        // second whole-view client of the SAME server displays the same
        // focused pane — joining is correct for both. What still blocks is a
        // possible client of a DIFFERENT herdr view: another session selector,
        // a single-pane attach, or an argv unreadable enough to be either.
        //
        // The residual cost after panel fallback: a manual `ssh host`, then
        // `herdr` flow still gets no join at all when the sidebar row cannot
        // render (collapsed/narrow/covered/unconfigured), because its argv has
        // no remote command and no other arm can see inside that connection.
        // The surface's own classification first: when the surface argv is the
        // problem, the log must say so — a competing neighbor may exist too,
        // and reporting it instead buried the actionable cause (review nit,
        // 2026-08-06).
        switch connection.herdr {
        case .notHerdr:
            Self.abstainedRemoteHerdrJoin(
                outcome: "the ssh command on this terminal is not herdr itself"
            )
            return .declined
        case .otherHerdrSubcommand:
            // `herdr terminal attach <id>` renders ONE pane and
            // `herdr --session <x>` in a shape we could not normalize may be
            // another server entirely — while the join would read the
            // candidates' server-global focus. Joining would pair the prompt
            // with a pane the user is not looking at.
            Self.abstainedRemoteHerdrJoin(
                outcome: "this terminal attaches a partial or different herdr view"
            )
            return .declined
        case .plainClient:
            break
        }
        guard !connection.hasCompetingHerdrClient else {
            Self.abstainedRemoteHerdrJoin(
                outcome: "another terminal may hold a different herdr view of this destination"
            )
            return .declined
        }

        guard let remoteHerdrForwards else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward capability unavailable")
            return .declined
        }
        guard let herdrPanes else {
            Self.abstainedRemoteHerdrJoin(outcome: "pane query capability unavailable")
            return .declined
        }
        guard let forward = await remoteHerdrForwards.open(
            alias: alias, remoteSocketPath: remoteSocketPath
        ) else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward unavailable")
            return .declined
        }

        if let join = await resolveRemoteHerdrPane(
            target: target,
            hostID: host.id,
            candidates: candidates,
            forward: forward,
            herdrPanes: herdrPanes
        ) {
            Log.claudeContext.info(
                "Terminal pane joined to a live Claude session via remote herdr pane"
            )
            return .joined(join)
        }
        forward.close()
        return .declined
    }

    private struct PanelCandidateMatch {
        let host: ClaudeRemoteHost
        let pane: HerdrFocusedPane
        let snapshot: ClaudeSessionSnapshot
        let forward: ClaudeRemoteHerdrForwardHandle
        let token: String
    }

    /// Returns nil only when the panel did not authorize any server, which is
    /// the one condition that permits the argv fallback below it.
    private func resolveViaRemoteHerdrPanel(
        target: TerminalScreenTarget,
        sshResult: SSHDestinationTTYProbeResult
    ) async -> RemoteHerdrArmOutcome? {
        guard let herdrPanes,
              let remoteHerdrForwards,
              let herdrPanelMetadata
        else { return nil }

        let selectedHosts: [ClaudeRemoteHost]
        let speculative: Bool
        switch sshResult {
        case .connection(let connection):
            let matching = enrolledHosts(connection.destination).filter {
                !$0.isRevoked && $0.sshHostAlias != nil
            }
            guard matching.count == 1 else { return nil }
            selectedHosts = matching
            speculative = false
        case .noSSHClient:
            // A surface with NO ssh at all is a local shell — the
            // overwhelmingly common dictation target. It must not pay remote
            // latency (a cold forward per candidate host) and must not flash
            // a nonce in remote panels the user is not looking at, so it
            // never probes. The cost: a nested wrapper whose inner ssh lives
            // on another pty (tmux) stays unjoinable until a warm-forward
            // speculative mode exists.
            return nil
        case .undeterminable:
            // An ssh IS present but its argv cannot be read (a wrapper the
            // parser refuses). That is a strong prior that the surface shows
            // a remote session, so plausible servers are probed. Registry
            // liveness bounds the candidates, and the hard prefix keeps one
            // join from opening an unbounded number of forwards.
            selectedHosts = Array(speculativeHosts().filter { host in
                !host.isRevoked
                    && host.sshHostAlias != nil
                    && !registry.liveRemoteHerdrSessions(hostID: host.id).isEmpty
            }.prefix(3))
            speculative = true
        }
        guard !selectedHosts.isEmpty else { return nil }

        let probe = HerdrPanelBindingProbe(
            metadata: herdrPanelMetadata,
            readGrid: readFocusedGrid,
            now: panelNow,
            sleepFor: panelSleepFor,
            randomBits: panelRandomBits
        )
        var matches: [PanelCandidateMatch] = []

        for host in selectedHosts {
            guard let alias = host.sshHostAlias else { continue }
            let candidates = registry.liveRemoteHerdrSessions(hostID: host.id)
            // Two live sockets on one host used to abstain outright (the argv
            // fallback still does — it has no way to tell the servers apart).
            // The nonce CAN tell them apart: each socket is stamped with its
            // own fresh token, and only the server this surface displays can
            // render its token. A stale socket — a session registered under a
            // previous herdr boot, inside the registry TTL — simply fails its
            // forward and is skipped (field abstention 2026-08-09). Sorted for
            // determinism; bounded like the host prefix.
            let socketPaths = Set(candidates.compactMap {
                $0.remoteSessionEnvironment?.herdrSocketPath
            }).sorted().prefix(3)

            socketLoop: for remoteSocketPath in socketPaths {
                let socketCandidates = candidates.filter {
                    $0.remoteSessionEnvironment?.herdrSocketPath == remoteSocketPath
                }
                guard let forward = await remoteHerdrForwards.open(
                    alias: alias,
                    remoteSocketPath: remoteSocketPath
                ) else {
                    let cause: HerdrPanelBindingAbstention = speculative
                        ? .speculativeForwardUnavailable : .forwardUnavailable
                    HerdrPanelBindingProbe.noteAbstention(cause)
                    continue
                }

                let socketPath = forward.localSocketPath
                guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
                    Self.abstainedRemoteHerdrJoin(outcome: "panel candidate focused pane unavailable")
                    forward.close()
                    continue
                }
                let paneMatches = socketCandidates.filter {
                    $0.remoteSessionEnvironment?.herdrPaneID == pane.paneID
                }
                guard paneMatches.count == 1, let snapshot = paneMatches.first else {
                    Self.abstainedRemoteHerdrJoin(
                        outcome: paneMatches.isEmpty
                            ? "panel candidate focused pane has no live session"
                            : "panel candidate focused pane is ambiguous"
                    )
                    forward.close()
                    continue
                }

                switch await probe.probe(
                    target: target,
                    socketPath: socketPath,
                    paneID: pane.paneID
                ) {
                case .matched(let match):
                    matches.append(PanelCandidateMatch(
                        host: host,
                        pane: pane,
                        snapshot: snapshot,
                        forward: forward,
                        token: match.token
                    ))
                    // One grid renders exactly one server's panel, and the
                    // forward service holds one entry per host — opening the
                    // NEXT socket would tear down this matched forward. First
                    // match ends the socket loop; the cross-HOST double-match
                    // abstention below is untouched.
                    break socketLoop
                case .noMatch(let cause):
                    HerdrPanelBindingProbe.noteAbstention(cause)
                    // Only a destination-known SINGLE-socket probe may
                    // diagnose the row: with a speculative host or a second
                    // socket in play, a token not rendering usually means the
                    // user is not looking at THAT server, not that its config
                    // is missing.
                    if cause == .settleTimeout, !speculative, socketPaths.count == 1 {
                        reportPanelStatus(.likelyNotConfigured)
                        // Named as CANDIDATES, not as a finding. A stamped
                        // token that did not render has at least four causes
                        // and this side cannot tell them apart (herdr exposes
                        // no client introspection and no config read), so
                        // asserting the first one sends the user to change a
                        // row that is often already correct — measured twice
                        // on 2026-09-05, once where the real cause was column
                        // truncation and once where the agent entry did not
                        // fit an 80x24 client. The grid geometry logged by
                        // `noteRowNotRendered` is the fact that separates them.
                        Log.claudeContext.info(
                            "Remote herdr panel token was stamped but did not render; check the agents-panel row config, the sidebar width, and whether the entry fits this client's height"
                        )
                    }
                    // A truncated row is the OPPOSITE diagnosis: the row is
                    // configured and rendering, and herdr cut the token to the
                    // sidebar's column budget. Saying "likely not configured"
                    // here sends the user to change the one thing that is
                    // already right (field abstention 2026-09-05).
                    if cause == .rowTruncated {
                        Log.claudeContext.info(
                            "Remote herdr panel row rendered a TRUNCATED token; widen the herdr sidebar or make the $lvmark row the agent entry's first row"
                        )
                    }
                    await HerdrPanelBindingProbe.clear(
                        metadata: herdrPanelMetadata,
                        socketPath: socketPath,
                        paneID: pane.paneID
                    )
                    forward.close()
                }
            }
        }

        if !matches.isEmpty { reportPanelStatus(.ok) }
        guard matches.count <= 1 else {
            HerdrPanelBindingProbe.noteAbstention(.multiHostDoubleMatch)
            for match in matches {
                await HerdrPanelBindingProbe.clear(
                    metadata: herdrPanelMetadata,
                    socketPath: match.forward.localSocketPath,
                    paneID: match.pane.paneID
                )
                match.forward.close()
            }
            return .declined
        }
        guard let match = matches.first else { return nil }

        return await confirmPanelAuthorizedRemoteHerdr(
            target: target,
            match: match,
            metadata: herdrPanelMetadata,
            herdrPanes: herdrPanes
        )
    }

    private func confirmPanelAuthorizedRemoteHerdr(
        target: TerminalScreenTarget,
        match: PanelCandidateMatch,
        metadata: any HerdrPanelMetadataReporting,
        herdrPanes: HerdrPaneQuerying
    ) async -> RemoteHerdrArmOutcome {
        let pane = match.pane
        let snapshot = match.snapshot
        let socketPath = match.forward.localSocketPath

        func refuse(_ outcome: String) async -> RemoteHerdrArmOutcome {
            Self.abstainedRemoteHerdrJoin(outcome: outcome)
            await HerdrPanelBindingProbe.clear(
                metadata: metadata,
                socketPath: socketPath,
                paneID: pane.paneID
            )
            match.forward.close()
            return .declined
        }

        // The pane-level confirmation set, unchanged in substance now that the
        // pane title is not consulted: the caller already established that
        // EXACTLY ONE live candidate of this socket claims the focused pane id
        // (`paneMatches.count == 1` above), and the two fail-closed
        // cross-checks below are what stop a REUSED pane — a session that died
        // without a SessionEnd leaves a live registry entry and its pane id
        // behind, and herdr, which watches the pane, is the party that can
        // contradict it.
        if let claimed = pane.claimedClaudeSessionID,
           Self.scopedRemoteSessionID(
               claimed: claimed, hostID: match.host.id, agent: snapshot.agent
           ) != snapshot.sessionID {
            return await refuse("pane session claim disagrees")
        }
        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else { return await refuse("foreground process query unavailable") }
        guard let processes = foreground.foregroundProcesses else {
            return await refuse("foreground process detection unavailable")
        }
        guard Self.remoteAgentIsForeground(
            snapshot: snapshot,
            foregroundProcesses: processes
        ) else { return await refuse("registered remote agent is not foreground") }

        let indicator = HerdrPanelMicIndicator(
            metadata: metadata,
            socketPath: socketPath,
            paneID: pane.paneID,
            token: match.token,
            forward: match.forward,
            sleepFor: indicatorSleepFor
        )
        Log.claudeContext.info(
            "Terminal pane joined to a live Claude session via remote herdr agents-panel binding"
        )
        return .joined(ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteHerdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath),
            remoteHerdrForward: match.forward,
            remoteHerdrIndicator: indicator
        ))
    }

    /// The over-the-forward half: the focused pane, then the fail-closed
    /// cross-checks. Split out so the caller has exactly one `forward.close()`
    /// on the failure path. Nil is the only failure answer — with no title arm
    /// underneath, "nothing was established yet" and "something was, and a
    /// later check refused it" reach the same place.
    private func resolveRemoteHerdrPane(
        target: TerminalScreenTarget,
        hostID: String,
        candidates: [ClaudeSessionSnapshot],
        forward: ClaudeRemoteHerdrForwardHandle,
        herdrPanes: HerdrPaneQuerying
    ) async -> ClaudeSessionJoin? {
        guard let confirmed = await Self.confirmRemoteHerdrPane(
            herdrPanes: herdrPanes,
            socketPath: forward.localSocketPath,
            hostID: hostID,
            candidates: candidates,
            noteAbstention: { Self.abstainedRemoteHerdrJoin(outcome: $0) }
        ) else { return nil }

        return ClaudeSessionJoin(
            target: target,
            snapshot: confirmed.snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteHerdrPane,
            herdrPane: ClaudeHerdrPaneBinding(
                paneID: confirmed.pane.paneID, socketPath: forward.localSocketPath
            ),
            remoteHerdrForward: forward
        )
    }

    /// The pane-level confirmation set every over-a-forward herdr arm resolves
    /// through: the focused pane, EXACTLY ONE candidate claiming that pane id,
    /// herdr's own `agent_session` claim not disagreeing, and the registered
    /// agent in the pane's foreground process list.
    ///
    /// The precondition, stated precisely because a loose reading of it drew a
    /// review finding: exactly one candidate for the FOCUSED PANE ID — NOT one
    /// candidate per socket. Several live sessions on one herdr are expected
    /// and fine; that is what a multiplexer is for, and it is the case these
    /// arms exist to serve. What abstains is two candidates claiming the SAME
    /// pane id, which is the only shape that would force a choice. Nothing
    /// here picks: the survivor still has to be confirmed by herdr's own
    /// session claim and by the foreground process.
    ///
    /// herdr's OWN claim about the pane is the check that catches a reused
    /// pane: session A dies without a SessionEnd, leaving a live registry
    /// entry and its pane id behind; session B starts in that same pane. The
    /// pane id still names A, and herdr — which watches the pane — says B. A
    /// disagreement resolves to NEITHER (review finding 3). Scoped by the
    /// session's own host and agent before comparing, never by anything herdr
    /// says, so a claim can only ever CONFIRM the pane-id join and never
    /// redirect it.
    ///
    /// `noteAbstention` is the CALLING ARM's decline sink, so an abstention
    /// here is attributed to the arm that asked (`.remoteHerdrPane`'s argv
    /// path or the federated arm), with the same content-free outcome strings.
    static func confirmRemoteHerdrPane(
        herdrPanes: HerdrPaneQuerying,
        socketPath: String,
        hostID: String,
        candidates: [ClaudeSessionSnapshot],
        noteAbstention: @MainActor (String) -> Void
    ) async -> (pane: HerdrFocusedPane, snapshot: ClaudeSessionSnapshot)? {
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            noteAbstention("focused pane unavailable")
            return nil
        }
        let matches = candidates.filter {
            $0.remoteSessionEnvironment?.herdrPaneID == pane.paneID
        }
        guard matches.count == 1, let snapshot = matches.first else {
            noteAbstention(
                matches.isEmpty
                    ? "focused pane has no live session"
                    : "two live sessions claim the focused pane id"
            )
            return nil
        }

        if let claimed = pane.claimedClaudeSessionID,
           Self.scopedRemoteSessionID(
               claimed: claimed, hostID: hostID, agent: snapshot.agent
           ) != snapshot.sessionID {
            noteAbstention("pane session claim disagrees")
            return nil
        }

        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            noteAbstention("foreground process query unavailable")
            return nil
        }
        guard let processes = foreground.foregroundProcesses else {
            noteAbstention("foreground process detection unavailable")
            return nil
        }
        guard Self.remoteAgentIsForeground(
            snapshot: snapshot,
            foregroundProcesses: processes,
            noteAbstention: noteAbstention
        ) else { return nil }

        return (pane, snapshot)
    }

    /// A raw session id as herdr reports it, in the registry's namespace.
    ///
    /// Two scopings apply to a remote session and both are recomputed here from
    /// facts WE hold (the authenticating host, the snapshot's agent) rather than
    /// from anything on the wire: the remote listener namespaces by host id, and
    /// the registry then namespaces by agent. For Claude the second is the
    /// identity function; for opencode it adds the same prefix ingest did.
    static func scopedRemoteSessionID(
        claimed: String,
        hostID: String,
        agent: ClaudeHookAgent
    ) -> String {
        ClaudeAgentSessionScope.scopedSessionID(
            agent: agent,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                hostID: hostID, sessionID: claimed
            )
        )
    }

    /// Is the joined pane actually running that session's agent right now?
    ///
    /// The local arm answers this with a pid, which a remote pane cannot: its
    /// numbers live in another machine's namespace. Two signals replace it, and
    /// EITHER is sufficient while NEITHER is optional:
    ///
    /// * the session's reported `hookParentPID` (the remote shim's `$PPID`) is
    /// one of the pane's foreground pids — compared as STRINGS, because that
    /// value is a label and must never become a number this process could
    /// probe;
    /// * a foreground process is NAMED for the session's agent.
    ///
    /// Requiring both, as first designed, would have failed closed forever on
    /// two ordinary installs: `$PPID` is the shim's parent, which is the shell
    /// Claude Code spawns hooks through rather than Claude Code itself, and an
    /// npm-installed Claude Code appears in the process table as `node`. Either
    /// signal alone still proves the pane is running the session — and neither
    /// present (a suspended agent with the user back at the shell, the case
    /// this check exists for) still abstains.
    ///
    /// The abstention sink is a parameter so the federated arm can decline
    /// under its own cause prefix instead of the argv arm's; both log the same
    /// content-free outcome string.
    static func remoteAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundProcesses: [HerdrForegroundProcess],
        noteAbstention: @MainActor (String) -> Void = { outcome in
            Self.abstainedRemoteHerdrJoin(outcome: outcome)
        }
    ) -> Bool {
        if let hookParentPID = snapshot.remoteSessionEnvironment?.hookParentPID,
           foregroundProcesses.contains(where: { String($0.pid) == hookParentPID }) {
            return true
        }
        let agentName = snapshot.agent.rawValue
        if foregroundProcesses.contains(where: { process in
            guard let name = process.name else { return false }
            return (name as NSString).lastPathComponent == agentName
        }) {
            return true
        }
        noteAbstention(
            "no foreground process matches the registered \(snapshot.agent.rawValue) session"
        )
        return false
    }

    /// Outcome only. Pane ids, socket paths, ssh destinations, and titles are
    /// all live join material — and the destination additionally names the
    /// user's infrastructure, which the unified log is emphatically not the
    /// place for.
    private static func abstainedRemoteHerdrJoin(outcome: String) {
        Log.claudeContext.info(
            "Remote herdr pane matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("remote-herdr: \(outcome)")
    }
}
