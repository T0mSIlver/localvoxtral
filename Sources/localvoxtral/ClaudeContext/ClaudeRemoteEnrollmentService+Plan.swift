import Foundation

extension ClaudeRemoteEnrollmentService {
    // MARK: - Plan

    /// Build the setup for one enrolled host.
    ///
    /// - Parameters:
    ///   - sshHostAlias: the `Host` stanza name in `~/.ssh/config`. Validated,
    ///     not escaped — an alias is a bare token and anything else is a mistake
    ///     we should surface rather than quietly rewrite.
    ///   - token: the plaintext embedded in the generated documentation/test
    ///     plan and, after consent, its SSH stdin script. Not stored or logged.
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
        token: String,
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
            ),
            remoteCommands: remoteCommands(token: token, remoteForwardPort: remoteForwardPort),
            updateCommands: updateCommands(
                sshHostAlias: sshHostAlias, remoteForwardPort: remoteForwardPort
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
    /// `execute` is the second layer; this is the first, and it is the one that
    /// also covers the commands the user pastes by hand.
    public static func isValidHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 128 else { return false }
        guard !alias.hasPrefix("-") else { return false }
        // "." and ".." would name a directory, not a host, and an all-dot alias
        // resolves to nothing anyone meant.
        guard alias.contains(where: { $0 != "." }) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return alias.allSatisfy { allowed.contains($0) }
    }

    static func blockBegin(hostID: String) -> String {
        "# BEGIN localvoxtral claude context (\(hostID))"
    }

    static func blockEnd(hostID: String) -> String {
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

    /// The first-time setup pair.
    ///
    /// Both are idempotent, but only in the weak sense: on a host that already
    /// has them, `marketplace add` exits 0 without refreshing the clone and
    /// `plugin install` exits 0 without changing the installed version (verified
    /// on Claude Code 2.1.220). `install` DOES apply a new `--config token=`,
    /// which is why rotation reuses this exact command — and why shipping a new
    /// plugin version needs `updateCommands` instead.
    /// `--config` is repeatable and MERGES per key on an already-installed
    /// plugin: verified on Claude Code 2.1.220 (`--help` documents "repeatable";
    /// a second install with only `--config port=` kept the stored token and
    /// replaced only the port). That is what makes the port migratable without
    /// ever re-sending a credential.
    static func remoteCommands(token: String, remoteForwardPort: UInt16) -> [String] {
        [
            "claude plugin marketplace add \(repositoryMarketplaceReference)",
            // Leading space: with HISTCONTROL=ignorespace (bash) or
            // HIST_IGNORE_SPACE (zsh) the token stays out of the remote shell
            // history. See `docs/remote-claude-context.md` ("Shell history and
            // rotation") — it is a habit, not a guarantee.
            " claude plugin install \(remotePluginReference) --config '\(tokenConfigKey)=\(token)'"
                + " --config '\(portConfigKey)=\(remoteForwardPort)'",
        ]
    }

    /// PATH prefix for a `claude` invocation inside `ssh <host> '<command>'`.
    ///
    /// Non-interactive SSH skips the login rc, so `claude` is routinely off PATH
    /// there on a host where it works fine interactively. The stdin script has
    /// its own resolver (`claudePathResolverPreamble`); this is the one-liner
    /// equivalent for the commands a person pastes.
    static let nonInteractiveClaudePathPrefix =
        "PATH=\"$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "

    /// The remote-side commands, in order, with nothing wrapped around them.
    /// Execution sends these through the SSH stdin script;
    /// `updateCommands(sshHostAlias:remoteForwardPort:)` is the same set written
    /// for a person to paste from this Mac.
    ///
    /// The third command is the port MIGRATION, and it is why update takes a
    /// port at all: a host enrolled before #215 has no `port` option, so its
    /// shim posts to the legacy 8473 while this Mac has moved its forward to an
    /// allocated one — two halves that disagree, failing open in silence.
    /// `plugin update` has no `--config` (Claude Code 2.1.220), and `install`
    /// on an installed plugin merges config per key without touching the stored
    /// token, so this line is both the only way and a token-free one.
    static func remotePluginUpdateCommands(remoteForwardPort: UInt16) -> [String] {
        [
            "claude plugin marketplace update \(ClaudePluginAssets.marketplaceName)",
            "claude plugin update \(remotePluginReference)",
            "claude plugin install \(remotePluginReference) --config '\(portConfigKey)=\(remoteForwardPort)'",
        ]
    }

    /// Bring an enrolled host to the plugin version this app ships.
    ///
    /// The generated commands remain a documentation and test seam. The docs
    /// explain that re-running setup is NOT an update (on Claude Code 2.1.220
    /// `plugin install` exits 0 with "already installed" and `marketplace add`
    /// does not refresh a clone it has), the stored token is preserved, and the
    /// third command only points this host at THIS Mac's allocated port —
    /// required once for a host enrolled before per-Mac ports, harmless after.
    static func updateCommands(sshHostAlias: String, remoteForwardPort: UInt16) -> [String] {
        remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort).map {
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)\($0)'"
        }
    }
}
