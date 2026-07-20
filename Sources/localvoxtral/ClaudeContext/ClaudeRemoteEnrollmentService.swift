import Foundation

/// Generates — and, only when explicitly asked, executes — the setup for a
/// remote Claude Code host.
///
/// The rule this type is built around: **localvoxtral never edits a config file
/// it does not own.** Not `~/.ssh/config`, not `~/.claude/settings.json`, not the
/// remote host's anything. Those files are the user's, they are load-bearing for
/// work that has nothing to do with dictation, and a third-party app rewriting
/// one is how a setup gets corrupted during an unrelated upgrade.
///
/// So the output is a PLAN: a snippet to paste, commands to run, and the exact
/// steps to undo all of it. `applySSHConfigSnippet` exists for the day a UI
/// wants to offer the edit, and it is a pure function over the file's text with
/// a delimited block — but nothing here writes it, and `execute` refuses unless
/// a caller supplied a runner on purpose.
///
/// Nothing in the app supplies one today. This task builds the surface; it
/// mutates no host.
public struct ClaudeRemoteEnrollmentService: Sendable {
    /// Everything the user needs, in the order they need it.
    public struct SetupPlan: Sendable, Equatable {
        /// Idempotent `~/.ssh/config` block. Contains NO token — the credential
        /// belongs to the Claude plugin's userConfig on the remote host, not to
        /// a file that gets copied between machines and pasted into issues.
        public var sshConfigSnippet: String
        /// Run on the REMOTE host, once.
        public var remoteCommands: [String]
        /// Run to check the setup without changing it.
        public var verifyCommands: [String]
        /// Undo, in order: remote first, then local revocation.
        public var uninstallCommands: [String]
        /// Caveats worth reading before the first surprise.
        public var notes: [String]
    }

    public struct RunResult: Sendable, Equatable {
        public var exitCode: Int32
        public var message: String

        public init(exitCode: Int32, message: String) {
            self.exitCode = exitCode
            self.message = message
        }

        public var succeeded: Bool { exitCode == 0 }
    }

    public enum ServiceError: Error, Equatable {
        /// No runner was injected, which is the default. Executing setup is an
        /// opt-in a caller makes deliberately, never a fallback this type
        /// reaches for.
        case executionNotConfigured
        /// `command` and `message` are REDACTED (`ClaudeRemoteTokenRedaction`)
        /// before they reach this case. An `Error` is the single most-copied
        /// string in any app: it lands in alerts, in `Log`, in the user's bug
        /// report, and — because `localizedDescription` is free — in places
        /// nobody audited. A token that reaches an error is a token that leaks,
        /// so it never reaches one.
        case commandFailed(command: [String], exitCode: Int32, message: String)
        case invalidHostAlias
    }

    /// argv in, result out. Injected so tests pin the exact commands without
    /// spawning anything, and so no code path can reach a real host by accident.
    public typealias Runner = @Sendable ([String]) throws -> RunResult

    /// Marketplace reference for a remote host, which has no app bundle to
    /// register a local directory from. `claude plugin marketplace add` accepts
    /// an `owner/repo` shorthand, and the repo root carries a
    /// `.claude-plugin/marketplace.json` listing both plugins for exactly this.
    public static let repositoryMarketplaceReference = "T0mSIlver/localvoxtral"

    /// The plugin's sensitive userConfig key. Claude Code exposes it to hooks as
    /// `CLAUDE_PLUGIN_OPTION_TOKEN`, which the manifest's `allowedEnvVars` lets
    /// it interpolate into the `Authorization` header.
    public static let tokenConfigKey = "token"

    private let runner: Runner?

    public init(runner: Runner? = nil) {
        self.runner = runner
    }

    public static var remotePluginReference: String {
        "\(ClaudePluginAssets.remotePluginName)@\(ClaudePluginAssets.marketplaceName)"
    }

    // MARK: - Plan

    /// Build the setup for one enrolled host.
    ///
    /// - Parameters:
    ///   - sshHostAlias: the `Host` stanza name in `~/.ssh/config`. Validated,
    ///     not escaped — an alias is a bare token and anything else is a mistake
    ///     we should surface rather than quietly rewrite.
    ///   - token: the plaintext, which exists only here and in the user's
    ///     clipboard. Not stored, not logged.
    public static func plan(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        token: String,
        port: UInt16 = ClaudeRemoteListenerLimits.default.port
    ) throws -> SetupPlan {
        guard isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }

        return SetupPlan(
            sshConfigSnippet: sshConfigSnippet(host: host, sshHostAlias: sshHostAlias, port: port),
            remoteCommands: remoteCommands(token: token),
            verifyCommands: verifyCommands(sshHostAlias: sshHostAlias, port: port),
            uninstallCommands: uninstallCommands(host: host, sshHostAlias: sshHostAlias),
            notes: notes(port: port)
        )
    }

    /// An SSH host alias, as `~/.ssh/config` understands one.
    ///
    /// Deliberately narrow: no whitespace (which would split the `Host` line
    /// into two patterns), no `#` (which would comment out the rest of our
    /// block), no quotes. This is the only user-supplied string that reaches the
    /// generated config, so it is checked rather than escaped — an alias that
    /// needs escaping is not an alias.
    public static func isValidHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 128 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return alias.allSatisfy { allowed.contains($0) }
    }

    static func blockBegin(hostID: String) -> String {
        "# BEGIN localvoxtral claude context (\(hostID))"
    }

    static func blockEnd(hostID: String) -> String {
        "# END localvoxtral claude context (\(hostID))"
    }

    static func sshConfigSnippet(host: ClaudeRemoteHost, sshHostAlias: String, port: UInt16) -> String {
        """
        \(blockBegin(hostID: host.id))
        Host \(sshHostAlias)
            RemoteForward \(port) 127.0.0.1:\(port)
            # ExitOnForwardFailure no (the default) is deliberate: if the remote
            # already has \(port) bound — usually another localvoxtral tunnel from a
            # second window — `yes` would refuse to open the SSH session at all.
            # A dictation nicety must never cost you the shell. The cost of `no`
            # is that a failed forward is silent: the hooks get connection
            # refused, fail open, and you simply get no context.
            ExitOnForwardFailure no
        \(blockEnd(hostID: host.id))
        """
    }

    static func remoteCommands(token: String) -> [String] {
        [
            "claude plugin marketplace add \(repositoryMarketplaceReference)",
            // Leading space: with HISTCONTROL=ignorespace (bash) or
            // HIST_IGNORE_SPACE (zsh) the token stays out of the remote shell
            // history. See `notes` — it is a habit, not a guarantee.
            " claude plugin install \(remotePluginReference) --config '\(tokenConfigKey)=\(token)'",
        ]
    }

    static func verifyCommands(sshHostAlias: String, port: UInt16) -> [String] {
        [
            // Does the forward actually exist? -v prints the remote forwarding
            // request and the remote's answer, which is the only place a failed
            // RemoteForward is visible when ExitOnForwardFailure is `no`.
            "ssh -v \(sshHostAlias) true 2>&1 | grep -i 'remote forward'",
            "ssh \(sshHostAlias) 'claude plugin list'",
            // From the remote side, through the tunnel: 401 proves the tunnel is
            // up and the listener is answering. A connection error means the
            // forward did not take.
            "ssh \(sshHostAlias) 'curl -s -o /dev/null -w \"%{http_code}\\n\" -X POST "
                + "-H \"Content-Type: application/json\" -d \"{}\" http://127.0.0.1:\(port)/v1/hook/SessionStart'",
        ]
    }

    static func uninstallCommands(host: ClaudeRemoteHost, sshHostAlias: String) -> [String] {
        [
            "ssh \(sshHostAlias) 'claude plugin uninstall \(remotePluginReference)'",
            "ssh \(sshHostAlias) 'claude plugin marketplace remove \(ClaudePluginAssets.marketplaceName)'",
            "# then remove the \(blockBegin(hostID: host.id)) block from ~/.ssh/config",
            "# and revoke \(host.id) in localvoxtral — revocation is what actually",
            "# stops the host: the token dies here, not on the remote.",
        ]
    }

    static func notes(port: UInt16) -> [String] {
        [
            "The token authorizes remote context only. A host that presents it can never "
                + "make localvoxtral read a local file: the listener tags every session it accepts "
                + "as remote regardless of what the payload says, and a remote cwd cannot be turned "
                + "into a local path.",
            "Revoking the host in localvoxtral is the real off switch and takes effect immediately. "
                + "Uninstalling the remote plugin only stops it asking.",
            "The install command puts the token in the remote shell's history unless your shell is "
                + "set to ignore space-prefixed commands (HISTCONTROL=ignorespace / setopt "
                + "HIST_IGNORE_SPACE). If it landed there, rotate the token — that is what rotation "
                + "is for.",
            "tmux/screen: a multiplexer owns the window title, so the OSC 2 marker the hook writes "
                + "does not reach Ghostty by default and the pane stays unjoined. `set -g "
                + "set-titles on` in ~/.tmux.conf lets tmux pass the title through. Without it you "
                + "still get the off-screen context (prompt, cwd, files) — you just do not get the "
                + "screen join.",
            "Plain `ssh` with no enrollment keeps working exactly as before: no tunnel, no token, no "
                + "hooks, and the pane stays screen-only and unjoined.",
            "A second concurrent SSH session to the same host will fail to bind \(port) on the "
                + "remote and — because ExitOnForwardFailure is `no` — will connect anyway with no "
                + "tunnel. The first session keeps the forward.",
        ]
    }

    // MARK: - SSH config editing (pure; nothing here writes a file)

    /// Insert or replace this host's block in an ssh config's text.
    ///
    /// Idempotent by delimiter: applying the same snippet twice yields the same
    /// text, because the second application finds and replaces the first block
    /// rather than appending a duplicate `Host` stanza (which OpenSSH would
    /// resolve as first-match-wins, so a stale duplicate above a fresh one would
    /// silently win).
    ///
    /// Everything outside the delimited block is preserved byte for byte. This
    /// function is the whole reason a UI could ever offer to make the edit —
    /// but it is still the caller's decision to write the result anywhere.
    public static func applySSHConfigSnippet(
        to existing: String,
        snippet: String,
        hostID: String
    ) -> String {
        let begin = blockBegin(hostID: hostID)
        let end = blockEnd(hostID: hostID)
        let lines = existing.components(separatedBy: "\n")

        guard let beginIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let endIndex = lines[beginIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == end
              })
        else {
            // No block yet: append after a blank line, so our `Host` stanza can
            // never fuse onto the end of someone else's (an indented keyword
            // under the wrong `Host` is a config change they did not ask for).
            //
            // The exact spacing matters for idempotency, not for looks: the
            // replace branch above reproduces this layout byte for byte, so a
            // second apply is a no-op.
            var prefix = existing
            if !prefix.isEmpty, !prefix.hasSuffix("\n") { prefix += "\n" }
            if !prefix.isEmpty, !prefix.hasSuffix("\n\n") { prefix += "\n" }
            return prefix + snippet + "\n"
        }

        var result = Array(lines[..<beginIndex])
        result.append(contentsOf: snippet.components(separatedBy: "\n"))
        result.append(contentsOf: lines[(endIndex + 1)...])
        return result.joined(separator: "\n")
    }

    /// Remove this host's block, leaving everything else untouched.
    public static func removeSSHConfigSnippet(from existing: String, hostID: String) -> String {
        let begin = blockBegin(hostID: hostID)
        let end = blockEnd(hostID: hostID)
        let lines = existing.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let endIndex = lines[beginIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == end
              })
        else {
            return existing
        }
        var result = Array(lines[..<beginIndex])
        result.append(contentsOf: lines[(endIndex + 1)...])
        return result.joined(separator: "\n")
    }

    // MARK: - Execution (opt-in only)

    /// Run the plan's remote commands through the injected runner.
    ///
    /// Throws `.executionNotConfigured` when no runner was supplied, which is
    /// the default and the state the app ships in — the shipped Settings UI
    /// hands the user copyable commands and executes nothing. The SSH config
    /// snippet is never applied here either: it is the user's file, and the plan
    /// hands them the text.
    ///
    /// **Process-argv exposure — read before injecting a runner.** The install
    /// command carries the token as an argument, so any runner that spawns a
    /// process makes that token visible in the REMOTE host's process list
    /// (`ps`, `/proc/<pid>/cmdline`) for the lifetime of the command, to every
    /// process on that host. `token` is passed separately rather than being
    /// read back out of the plan so that this type can scrub it from anything it
    /// throws; it cannot scrub the runner's own argv, which is why nothing in
    /// the app supplies a runner. A runner that must exist should feed the token
    /// over the child's stdin or environment instead of its argv, and take
    /// `remoteCommands(token:)`'s output apart rather than shelling the string.
    ///
    /// - Parameter token: the plaintext, used ONLY to redact it back out of any
    ///   failure. Nothing here logs or stores it.
    public func executeRemoteSetup(_ plan: SetupPlan, sshHostAlias: String, token: String) throws {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        for command in plan.remoteCommands {
            let argv = ["ssh", sshHostAlias, command.trimmingCharacters(in: .whitespaces)]
            let result = try runner(argv)
            guard result.succeeded else {
                // Redact BOTH halves. The argv contains the token by
                // construction, and the runner's message is remote output that
                // routinely echoes the command that failed.
                throw ServiceError.commandFailed(
                    command: argv.map { ClaudeRemoteTokenRedaction.redact($0, token: token) },
                    exitCode: result.exitCode,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
            }
        }
    }
}
