import ClaudeContextWire
import CoreGraphics
import Foundation

extension ClaudeSessionJoinResolver {
    // MARK: - The plain-ssh arm

    /// A Claude Code session in a PLAIN `ssh host` shell on an enrolled remote
    /// host — the shape that lost its only join when the window-title marker
    /// was removed (#250).
    ///
    /// The binding is the TCP CONNECTION, not a label either side chose. sshd
    /// sets `$SSH_CONNECTION` in every session it spawns
    /// (`"<client-ip> <client-port> <server-ip> <server-port>"`), the shim
    /// publishes it, and this arm requires that the surface's own ssh PROCESS
    /// hold an established socket whose local port IS that client port and
    /// whose peer IS that server address and port. The client port is a 16-bit
    /// ephemeral number picked by THIS Mac's kernel; the remote host learns it
    /// only by being the other end of that connection.
    ///
    /// Why that is stronger than the marker it replaces: the marker was a value
    /// we minted and handed back over a channel the remote host fully
    /// controlled and Claude Code overwrote at will (measured present 1.26 % of
    /// the time, 2026-09-05). This asks the remote host to name a number it can
    /// only know by being the peer of a connection whose LOCAL end this process
    /// reads out of its own kernel — and pins that answer to the enrolled host
    /// the hook authenticated from, so a host can at most mis-describe its OWN
    /// connection.
    ///
    /// Every requirement, all of them necessary:
    /// 1. exactly one foreground ssh on the focused surface's tty, with a
    ///    verified OpenSSH executable and an argv the parser accepts
    ///    (`SSHDestinationTTYProbe` — unchanged, and the reason the surface
    ///    claim is worth anything);
    /// 2. no `-J`: with a jump host the local socket goes to the JUMP host
    ///    while the destination's sshd sees the jump host's port, so the two
    ///    halves describe different connections;
    /// 3. that destination resolves to exactly one enrolled host (exact alias,
    ///    then `ssh -G` canonicalization);
    /// 4. the candidate session was registered by a hook AUTHENTICATED FROM
    ///    THAT HOST (`liveRemoteSessions(hostID:)` is scoped to its channel);
    /// 5. the candidate is a plain ssh shell: it reports `$SSH_TTY` and NO
    ///    multiplexer label — see `isPlainSSHShellSession`;
    /// 6. exactly one of this process's established sockets matches the
    ///    reported tuple, and exactly one live session matches at all.
    ///
    /// Nothing here picks a session for being the only one, the newest, or the
    /// one whose cwd looks plausible.
    func resolveViaPlainSSHConnection(
        target: TerminalScreenTarget,
        sshResult: SSHDestinationTTYProbeResult
    ) async -> ClaudeSessionJoin? {
        let connection: SSHSurfaceConnection
        switch sshResult {
        case .noSSHClient:
            // A local shell — the overwhelmingly common surface. Not an
            // abstention, the arm simply does not apply.
            return nil
        case .undeterminable(let cause):
            Self.abstainedPlainSSHJoin(
                outcome: "ssh session undeterminable (\(cause.rawValue))"
            )
            return nil
        case .connection(let value):
            connection = value
        }

        guard !connection.usesProxyJump else {
            Self.abstainedPlainSSHJoin(outcome: "the connection goes through a jump host")
            return nil
        }
        // The ControlMaster case, in TWO causes rather than one. Both abstain,
        // and they always did — but the field could not tell them apart from
        // the abstention alone (2026-09-06), and they call for opposite fixes:
        // a real mux client is the user's own ssh config, an unreadable
        // sibling is a bug or a permission we do not have. The counts ride
        // along because "1 of 1" and "1 of 6" are different stories and
        // neither names a host, a port, or a path.
        let siblings = connection.siblings
        if siblings.socketless > 0 {
            Self.abstainedPlainSSHJoin(
                outcome: "another ssh session to this destination holds no connection of "
                    + "its own (\(siblings.socketless) of \(siblings.considered))"
            )
            return nil
        }
        if siblings.unreadable > 0 {
            Self.abstainedPlainSSHJoin(
                outcome: "another ssh session to this destination is unreadable "
                    + "(\(siblings.unreadable) of \(siblings.considered))"
            )
            return nil
        }
        guard let sockets = connection.sockets else {
            // Nil is UNREADABLE. Treating it as "no sockets" would turn a
            // failed syscall into a decline that looks exactly like a genuine
            // mismatch. `SSHProcessSocketReaderCrossProcessTests` is what says
            // a same-user process this app did not spawn IS readable, so this
            // cause means something went wrong rather than "as expected".
            Self.abstainedPlainSSHJoin(outcome: "this ssh's socket table is unreadable")
            return nil
        }
        guard !sockets.isEmpty else {
            // Readable, and holding nothing. Three ordinary causes, and until
            // the field hit one (2026-09-06) they were reported as a guess
            // between two of them. `ssh -G` can name the commonest exactly,
            // and is consulted only HERE — on a path that is about to abstain
            // anyway, so the ordinary join pays nothing for it.
            switch await proxyJumpShape(connection.destination) {
            case .singleHop:
                Self.abstainedPlainSSHJoin(
                    outcome: "this connection goes through a jump host (ProxyJump)"
                )
            case .chain:
                Self.abstainedPlainSSHJoin(
                    outcome: "this connection goes through a chain of jump hosts"
                )
            case .some(.none), nil:
                // No ProxyJump in the effective config, or no readable config
                // at all: a `ProxyCommand`, or an OpenSSH ControlMaster
                // CLIENT whose whole session rides another process's
                // connection over an AF_UNIX control path.
                Self.abstainedPlainSSHJoin(
                    outcome: "this ssh holds no connection of its own "
                        + "(a ControlMaster client or a ProxyCommand)"
                )
            }
            return nil
        }

        var hosts = enrolledHosts(connection.destination)
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(connection.destination)
        }
        guard !hosts.isEmpty else {
            // An ssh to a host the user never enrolled. No context exists.
            return nil
        }
        guard hosts.count == 1, let host = hosts.first else {
            Self.abstainedPlainSSHJoin(outcome: "ssh destination matches multiple enrolled hosts")
            return nil
        }

        let live = registry.liveRemoteSessions(hostID: host.id)
        guard !live.isEmpty else { return nil }
        let plain = live.filter(Self.isPlainSSHShellSession)
        guard !plain.isEmpty else {
            Self.abstainedPlainSSHJoin(
                outcome: "no live session on this host is a plain ssh shell"
            )
            return nil
        }
        let reported = plain.compactMap {
            snapshot -> (ClaudeSessionSnapshot, ClaudeRemoteSSHConnectionReport)? in
            guard let value = snapshot.remoteSessionEnvironment?.sshConnection,
                  let report = ClaudeRemoteSSHConnectionReport.parse(value)
            else { return nil }
            return (snapshot, report)
        }
        guard !reported.isEmpty else {
            // The actionable one: a host still running a remote plugin older
            // than the release that publishes `$SSH_CONNECTION` looks exactly
            // like this, and nothing else on either machine says so.
            Self.abstainedPlainSSHJoin(
                outcome: "no live session on this host reports its ssh connection"
            )
            return nil
        }

        let matches = reported.filter { _, report in
            sockets.filter { Self.socket($0, matches: report) }.count == 1
        }
        guard matches.count == 1, let (snapshot, _) = matches.first else {
            Self.abstainedPlainSSHJoin(
                outcome: matches.isEmpty
                    ? "no live session reports this surface's connection"
                    : "several live sessions report this surface's connection"
            )
            return nil
        }

        Log.claudeContext.info(
            "Terminal pane joined to a live Claude session via the ssh connection it holds"
        )
        return ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            // Read for parity with the other arms; the authorizer refuses raw
            // AX attachment for this mechanism regardless.
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteSSHConnection
        )
    }

    /// Does this remote session look like a plain interactive ssh shell?
    ///
    /// Two conditions, and the second is the one that matters: it reports an
    /// `$SSH_TTY` (so it is an interactive session on some connection's
    /// terminal, not an `ssh host claude -p …` one-shot), and it reports NO
    /// multiplexer label at all.
    ///
    /// The multiplexer exclusion is not tidiness. A multiplexer SERVER is
    /// started by one connection and outlives it; every pane it later spawns
    /// inherits that first connection's `$SSH_CONNECTION`. Measured on this
    /// repo's dev box (tmux 3.x, 2026-09-05): connection A (client port 36878)
    /// created the session, connection B (client port 36886) attached, and a
    /// process inside the pane still read `SSH_CONNECTION=127.0.0.1 36878 …`.
    /// So such a session's report describes whichever connection happened to
    /// start the server — potentially a DIFFERENT surface, which is a
    /// mis-join, not a missed one. herdr and cmux sessions have arms of their
    /// own that bind the pane; tmux, screen and zellij have none, and this is
    /// why. The labels are listed in `multiplexerLabels`.
    static func isPlainSSHShellSession(_ snapshot: ClaudeSessionSnapshot) -> Bool {
        guard let environment = snapshot.remoteSessionEnvironment else { return false }
        guard environment.sshTTY != nil else { return false }
        return Self.multiplexerLabels.allSatisfy { environment[$0] == nil }
    }

    /// The env labels that mean "a multiplexer server owns this session's
    /// terminal". Written as a list over the wire allowlist rather than as a
    /// chain of `==` so that ADDING a multiplexer label to
    /// `ClaudeRemoteEnvironmentField` and forgetting it here is a visible
    /// omission in one place instead of an invisible one in a boolean.
    ///
    /// `screenSession`/`zellijSession` were added by review (2026-09-05): the
    /// first version checked herdr/cmux/tmux only, and `screen` — which
    /// publishes `$STY`, is a server exactly like tmux, and was not on the
    /// wire at all — reproduced the measured tmux mis-join with nothing able
    /// to see it.
    ///
    /// `bridgeSessionID` is deliberately NOT here: a Remote Control session
    /// has no multiplexer between it and its connection, its own arm runs on a
    /// browser target rather than a terminal one, and excluding it would cost
    /// a legitimate join for nothing.
    static let multiplexerLabels: [ClaudeRemoteEnvironmentField] = [
        .herdrPaneID, .herdrSocketPath, .herdrSession,
        .cmuxSurfaceID, .cmuxSocketPath,
        .tmux, .tmuxPane,
        .screenSession, .zellijSession,
    ]

    /// Does a socket in THIS machine's kernel and a remote session's report
    /// describe the same connection?
    ///
    /// Both ports and the server address, never the client address: the client
    /// address is what the SERVER saw us come from, which after NAT is not a
    /// value this side holds at all. The address is compared as bytes, because
    /// a dual-stack peer is `::ffff:10.0.0.9` to our socket and `10.0.0.9` to
    /// sshd, and both are right.
    static func socket(
        _ socket: SSHClientSocket, matches report: ClaudeRemoteSSHConnectionReport
    ) -> Bool {
        socket.localPort == report.clientPort
            && socket.peerPort == report.serverPort
            && SSHConnectionAddressMatch.sameAddress(socket.peerAddress, report.serverAddress)
    }

    /// Outcome only, never a port, address, host, or session id. The ports ARE
    /// the live join material here — writing one to the unified log would
    /// publish the number the whole binding rests on.
    private static func abstainedPlainSSHJoin(outcome: String) {
        Log.claudeContext.info(
            "Plain ssh connection matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("remote-ssh: \(outcome)")
    }
}
