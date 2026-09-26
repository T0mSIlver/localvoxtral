import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

extension ClaudeSessionJoinResolver {
    // MARK: - The local-tty echo arm

    /// A Claude Code session in a plain `ssh host` shell, joined on the LOCAL
    /// terminal's tty — the value the user's own shell exported and ssh
    /// carried into the session.
    ///
    /// This is the tty arm the local path has always had, with the identifier
    /// taking one extra trip. `resolve(tty:)` compares the focused pane's
    /// device against a device the session's hooks read from `/dev` on THIS
    /// machine; here the session's hooks report a device name that came FROM
    /// this machine, through ssh's own `SendEnv`/`AcceptEnv`, and the
    /// comparison is the same equality.
    ///
    /// Why it succeeds where `.remoteSSHConnection` cannot: ssh carries
    /// environment per SESSION CHANNEL, not per connection. MEASURED,
    /// 2026-09-06: the value arrives unchanged through a `ProxyJump` (where
    /// the connection binding has no chain to follow at all — see
    /// `docs/agent/invariants.md`), and two sessions multiplexed over ONE
    /// ControlMaster connection each receive their OWN value, which is exactly
    /// the case that makes `$SSH_CONNECTION` ambiguous.
    ///
    /// Requirements, all of them:
    /// 1. the focused surface's tty, read through the terminal's own scripting
    ///    interface — the same `focusedTerminalTTY` the local arm uses, not
    ///    anything the remote host said;
    /// 2. exactly one foreground ssh on that surface, whose destination
    ///    resolves to exactly one enrolled host. ProxyJump does not change the
    ///    destination OPERAND, so a jumped connection resolves like any other;
    /// 3. the candidate was registered by a hook AUTHENTICATED FROM THAT HOST;
    /// 4. the candidate is a plain ssh shell — `$SSH_TTY` and no multiplexer
    ///    label. A multiplexer server keeps the FIRST client's environment, so
    ///    a pane's `$LC_LVX_TTY` names whichever window started the server;
    ///    the rule and its measurement are the same as the connection arm's;
    /// 5. its reported local tty is a well-formed device path and EQUALS the
    ///    surface's;
    /// 6. it was FIRST SEEN at or after the surface's ssh process started —
    ///    a tty name is recycled by the kernel and a registry entry is not;
    /// 7. where the surface's ssh does hold sockets, its reported
    ///    `$SSH_CONNECTION` matches one of them;
    /// 8. exactly one live session survives all of that.
    ///
    /// The surface's ssh socket is not REQUIRED. That is the point: the socket
    /// is what ProxyJump and ControlMaster take away. Rule 7 uses it when it
    /// happens to be there, and can only ever refuse.
    package func resolveViaRemoteLocalTTY(
        target: TerminalScreenTarget,
        tty: String,
        sshResult: SSHDestinationTTYProbeResult
    ) async -> ClaudeSessionJoin? {
        let connection: SSHSurfaceConnection
        switch sshResult {
        case .noSSHClient:
            // A local shell. Not an abstention — the arm does not apply.
            return nil
        case .undeterminable(let cause):
            Self.abstainedLocalTTYJoin(
                outcome: "ssh session undeterminable (\(cause.rawValue))"
            )
            return nil
        case .connection(let value):
            connection = value
        }

        var hosts = enrolledHosts(connection.destination)
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(connection.destination)
        }
        guard !hosts.isEmpty else { return nil }
        guard hosts.count == 1, let host = hosts.first else {
            Self.abstainedLocalTTYJoin(outcome: "ssh destination matches multiple enrolled hosts")
            return nil
        }

        let live = registry.liveRemoteSessions(hostID: host.id)
        guard !live.isEmpty else { return nil }
        let plain = live.filter(Self.isPlainSSHShellSession)
        guard !plain.isEmpty else {
            Self.abstainedLocalTTYJoin(
                outcome: "no live session on this host is a plain ssh shell"
            )
            return nil
        }
        let reporting = plain.filter { snapshot in
            guard let value = snapshot.remoteSessionEnvironment?.localTTY else { return false }
            return ClaudeRemoteLocalTTYPath.isAcceptable(value)
        }
        guard !reporting.isEmpty else {
            // The actionable one, and the ONLY thing the user has to do for
            // this arm to work: export `LC_LVX_TTY` from their shell and let
            // ssh send it. Nothing else on either machine says so.
            Self.abstainedLocalTTYJoin(
                outcome: "no live session on this host reports its local tty"
            )
            return nil
        }

        let matches = reporting.filter { $0.remoteSessionEnvironment?.localTTY == tty }
        guard !matches.isEmpty else {
            Self.abstainedLocalTTYJoin(outcome: "no live session reports this terminal's tty")
            return nil
        }

        // THE TTY NAME IS RECYCLED AND THE REGISTRY ENTRY IS NOT. macOS hands
        // out pty minors first-free (XNU `bsd/kern/tty_ptmx.c`, `ptmx_clone`
        // scans for the first free slot and `ptmx_free_ioctl` returns the
        // minor on last close), so closing a window gives its `/dev/ttysNNN`
        // to the next window opened — while a remote session's entry lives on
        // for the full session TTL, with no liveness check available for
        // another machine's pid. Without this gate: close a Claude-over-ssh
        // window, open a new one to the same host, dictate, and the dead
        // session's repo and prior prompt attach to it. Found by review
        // (2026-09-06); the connection arm was immune because a new window's
        // ssh has a new ephemeral port.
        //
        // The gate is kernel truth on both sides: an ssh that STARTED after a
        // session was first seen cannot be the ssh that session was created
        // in. `firstSeen` is when this app first saw the session, so it is
        // always at or after the moment its ssh existed.
        guard let sshStartedAt = connection.surfaceProcessStartTime else {
            Self.abstainedLocalTTYJoin(
                outcome: "this terminal's ssh has no readable start time"
            )
            return nil
        }
        let contemporary = matches.filter { $0.firstSeen >= sshStartedAt }
        guard !contemporary.isEmpty else {
            Self.abstainedLocalTTYJoin(
                outcome: "the session claiming this tty predates this terminal's ssh"
            )
            return nil
        }

        // And where the kernel CAN still speak about the connection, it must
        // agree too. This is a pure negative check — it can only refuse — and
        // it makes the tty arm strictly stronger than the connection arm
        // wherever both could run. In the shapes this arm exists for
        // (ProxyJump, ControlMaster) there are no sockets to consult, which is
        // exactly why the freshness gate above is not optional.
        let confirmed: [ClaudeSessionSnapshot]
        if let sockets = connection.sockets, !sockets.isEmpty {
            confirmed = contemporary.filter { snapshot in
                guard let value = snapshot.remoteSessionEnvironment?.sshConnection,
                      let report = ClaudeRemoteSSHConnectionReport.parse(value)
                else { return false }
                return sockets.contains { Self.socket($0, matches: report) }
            }
            guard !confirmed.isEmpty else {
                Self.abstainedLocalTTYJoin(
                    outcome: "the session claiming this tty is not on this terminal's connection"
                )
                return nil
            }
        } else {
            confirmed = contemporary
        }

        guard confirmed.count == 1, let snapshot = confirmed.first else {
            Self.abstainedLocalTTYJoin(outcome: "several live sessions claim this terminal's tty")
            return nil
        }

        Log.claudeContext.info(
            "Terminal pane joined to a live Claude session via the local tty it echoed back"
        )
        return ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteLocalTTY
        )
    }

    /// Outcome only. A tty device path is the join material here, exactly as
    /// it is for the local arm, and the local arm's abstention has never
    /// carried one either.
    private static func abstainedLocalTTYJoin(outcome: String) {
        Log.claudeContext.info(
            "Local tty echo matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("remote-tty: \(outcome)")
    }
}
