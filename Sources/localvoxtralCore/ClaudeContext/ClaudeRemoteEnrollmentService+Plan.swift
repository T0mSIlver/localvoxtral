import Foundation

extension ClaudeRemoteEnrollmentService {
    // MARK: - Plan

    /// Build the setup for one enrolled host.
    ///
    /// - Parameters:
    ///   - sshHostAlias: the `Host` stanza name in `~/.ssh/config`. Validated,
    ///     not escaped — an alias is a bare token and anything else is a mistake
    ///     we should surface rather than quietly rewrite.
    ///   - listenerPort: the port the app listens on, HERE, on this Mac. The
    ///     forward's target.
    ///   - remoteForwardPort: the port the forward binds THERE, on the remote
    ///     host — this Mac's per-install allocation
    ///     (`ClaudeRemoteForwardPort`), which is what keeps two Macs from
    ///     contending for one bind (issue #215). Defaults to the legacy shared
    ///     port so every existing caller and fixture describes the pre-#215
    ///     setup, which still works.
    public static func plan(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        listenerPort: UInt16 = ClaudeRemoteListenerLimits.default.port,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort
    ) throws -> SetupPlan {
        guard isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }

        return SetupPlan(
            sshConfigSnippet: sshConfigSnippet(
                host: host,
                sshHostAlias: sshHostAlias,
                listenerPort: listenerPort,
                remoteForwardPort: remoteForwardPort
            )
        )
    }

    /// An SSH host alias, as `~/.ssh/config` understands one.
    ///
    /// Deliberately narrow: no whitespace (which would split the `Host` line
    /// into two patterns), no `#` (which would comment out the rest of our
    /// block), no quotes. This is the only user-supplied string that reaches the
    /// generated config, so it is checked rather than escaped — an alias that
    /// needs escaping is not an alias.
    ///
    /// A leading `-` is refused separately from the charset, because `-` is
    /// legal INSIDE a hostname and fatal in front of one: an alias of `-V`
    /// reaches `ssh`'s argv as an option, and OpenSSH then prints its version
    /// and exits 0 without connecting — every step reports success while
    /// nothing ran on any host (review finding, PR #197). Argv termination in
    /// `execute` is the second layer; this is the first.
    public static func isValidHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 128 else { return false }
        guard !alias.hasPrefix("-") else { return false }
        // "." and ".." would name a directory, not a host, and an all-dot alias
        // resolves to nothing anyone meant.
        guard alias.contains(where: { $0 != "." }) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return alias.allSatisfy { allowed.contains($0) }
    }

    package static func blockBegin(hostID: String) -> String {
        "# BEGIN localvoxtral claude context (\(hostID))"
    }

    package static func blockEnd(hostID: String) -> String {
        "# END localvoxtral claude context (\(hostID))"
    }

    /// The marked ssh-config block for one host. Token-free by construction,
    /// which is what lets the plugin-update path regenerate it for a host whose
    /// one-time token is long gone.
    ///
    /// Comment-free apart from the two delimiters, which are load-bearing:
    /// `applySSHConfigSnippet` and `sshConfigBlockIsCurrent` both find the block
    /// by them, which is what makes a second apply a no-op instead of a
    /// duplicate `Host` stanza. Everything the deleted `#` lines said —
    /// that `remoteForwardPort` is THIS Mac's allocation and must equal the
    /// plugin's `port` option, that another Mac gets a different one so the two
    /// can never fight over one bind, why `ExitOnForwardFailure` stays `no`
    /// at the cost of a silently absent tunnel, and what `SendEnv LC_LVX_TTY`
    /// carries into the session — is prose in
    /// `docs/remote-claude-context.md`, and the silence it warns about is what
    /// `executeVerification` exists to break.
    public static func sshConfigSnippet(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        listenerPort: UInt16,
        remoteForwardPort: UInt16
    ) -> String {
        """
        \(blockBegin(hostID: host.id))
        Host \(sshHostAlias)
            RemoteForward \(remoteForwardPort) 127.0.0.1:\(listenerPort)
            ExitOnForwardFailure no
            SendEnv LC_LVX_TTY
        \(blockEnd(hostID: host.id))
        """
    }
}
