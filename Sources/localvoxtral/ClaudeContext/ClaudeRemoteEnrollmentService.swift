import Foundation

public struct ClaudeRemoteSSHConfigState: Sendable, Equatable {
    public var directoryExists: Bool
    public var configData: Data?
    public var configPermissions: UInt16?
    /// lstat-derived trust facts. The live filesystem fills them so the pure
    /// service can refuse to write through a path another principal controls;
    /// the defaults describe the trustworthy case so existing fakes stay valid.
    public var directoryIsSymlink: Bool
    public var directoryOwnedByCurrentUser: Bool
    public var directoryPermissions: UInt16?
    public var configIsSymlink: Bool

    public init(
        directoryExists: Bool,
        configData: Data?,
        configPermissions: UInt16?,
        directoryIsSymlink: Bool = false,
        directoryOwnedByCurrentUser: Bool = true,
        directoryPermissions: UInt16? = nil,
        configIsSymlink: Bool = false
    ) {
        self.directoryExists = directoryExists
        self.configData = configData
        self.configPermissions = configPermissions
        self.directoryIsSymlink = directoryIsSymlink
        self.directoryOwnedByCurrentUser = directoryOwnedByCurrentUser
        self.directoryPermissions = directoryPermissions
        self.configIsSymlink = configIsSymlink
    }
}

/// Filesystem seam for the one local file the enrollment flow may edit.
public protocol ClaudeRemoteSSHConfigFileSystem: Sendable {
    func readState() throws -> ClaudeRemoteSSHConfigState
    func createSSHDirectory(permissions: UInt16) throws
    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws
}

/// Generates and, after a separate UI confirmation, applies the setup for a
/// remote Claude Code host. Both mutation paths are injected so tests cannot
/// reach the real home directory or a real SSH host.
public struct ClaudeRemoteEnrollmentService: Sendable {
    /// The text the user actually has to apply, and nothing else.
    ///
    /// Everything here is comment-free (owner rule, 2026-08-04: "commands you
    /// have to copy-paste have comments, that's just dumb — display it in the
    /// app or not at all"). The explanations that used to ride along as `#`
    /// lines are now either decided by the app (verification — see
    /// `executeVerification`) or written as prose in
    /// `docs/remote-claude-context.md`. The only `#` lines that survive are the
    /// snippet's BEGIN/END delimiters, which are functional: the idempotent
    /// replace and `sshConfigForwardsPort` both key on them.
    ///
    /// `verifyCommands`, `uninstallCommands` and `notes` are gone with them —
    /// the first became an in-app action, the other two are documentation.
    public struct SetupPlan: Sendable, Equatable {
        /// Idempotent `~/.ssh/config` block. Contains NO token — the credential
        /// belongs to the Claude plugin's userConfig on the remote host, not to
        /// a file that gets copied between machines and pasted into issues.
        public var sshConfigSnippet: String
        /// Run on the REMOTE host, once.
        public var remoteCommands: [String]
        /// Bring an already-enrolled host to the plugin version this app ships.
        /// Carries no token: `claude plugin update` keeps the config the install
        /// already stored.
        public var updateCommands: [String]
    }

    /// One interpreted verdict from `executeVerification`.
    ///
    /// The interpretation IS the deliverable. The old flow shipped three
    /// copy-paste commands wrapped in a dozen `#` lines explaining how to read
    /// their output — including that HTTP 401 is the success signal — and the
    /// field failure (2026-07-26) was a person reading healthy output as broken
    /// anyway. Anything the app can decide, the app decides.
    ///
    /// `detail` is DERIVED, never captured: see `executeVerification` for why
    /// no byte of a probe's output may travel in it.
    public struct VerificationCheck: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            /// The `RemoteForward` is live and our listener answered through it.
            case tunnel
            /// The remote plugin is installed under the host's `claude`.
            case plugin
        }

        public var kind: Kind
        public var passed: Bool
        /// One short sentence for the sheet. Never command output.
        public var summary: String
        /// The actionable half, when there is one. Also short — a second line
        /// in the sheet, not a paragraph.
        public var hint: String?
        /// Synthesized diagnostics for the alert and the log. Contains only
        /// strings this process composed: exit codes, status codes, and
        /// constants we own.
        public var detail: String

        public init(
            kind: Kind,
            passed: Bool,
            summary: String,
            hint: String? = nil,
            detail: String = ""
        ) {
            self.kind = kind
            self.passed = passed
            self.summary = summary
            self.hint = hint
            self.detail = detail
        }

        public var id: String { kind.rawValue }

        public var title: String {
            switch kind {
            case .tunnel: return "Connection & tunnel"
            case .plugin: return "Claude plugin on the host"
            }
        }
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

    public struct Invocation: Sendable, Equatable {
        /// Complete argv, including `ssh`, so a fake can prove no token reached
        /// any process argument.
        public var argv: [String]
        public var standardInput: Data
        public var timeout: TimeInterval

        public init(argv: [String], standardInput: Data, timeout: TimeInterval) {
            self.argv = argv
            self.standardInput = standardInput
            self.timeout = timeout
        }
    }

    public struct ExecutionStep: Sendable, Equatable {
        public var index: Int
        /// Redacted; kept for diagnostics — the sheet renders only per-step
        /// status text plus `message`.
        public var command: String
        public var message: String

        public init(index: Int, command: String, message: String) {
            self.index = index
            self.command = command
            self.message = message
        }
    }

    /// Errors thrown by a runner before it can return an exit status. They are
    /// caught and redacted by `executeRemoteSetup`; callers never receive one.
    public enum RunnerFailure: Error, Equatable {
        case timedOut(seconds: TimeInterval, message: String)
        case outputTooLarge(capBytes: Int, message: String)
    }

    public enum ServiceError: Error, Equatable {
        /// No runner was injected, which is the default. Executing setup is an
        /// opt-in a caller makes deliberately, never a fallback this type
        /// reaches for.
        case executionNotConfigured
        case sshConfigEditingNotConfigured
        case invalidSSHConfigEncoding
        /// `~/.ssh/config` (or `~/.ssh` itself) is a symlink. A rename-based
        /// atomic write would replace the link with a regular file and silently
        /// desync a dotfiles-managed setup, so the app refuses and leaves the
        /// copy path — which mutates nothing — as the way in.
        case sshConfigIsSymlink
        /// `~/.ssh` exists but is not exclusively the user's to write (wrong
        /// owner, or group/world-writable). Report, never repair.
        case sshDirectoryNotTrusted
        /// `command` and `message` are REDACTED (`ClaudeRemoteTokenRedaction`)
        /// before they reach this case. An `Error` is the single most-copied
        /// string in any app: it lands in alerts, in `Log`, in the user's bug
        /// report, and — because `localizedDescription` is free — in places
        /// nobody audited. A token that reaches an error is a token that leaks,
        /// so it never reaches one.
        case commandFailed(step: Int, command: String, exitCode: Int32, message: String)
        case commandTimedOut(step: Int, command: String, seconds: TimeInterval, message: String)
        case runnerFailed(step: Int, command: String, message: String)
        case invalidHostAlias
    }

    /// Invocation in, result out. The stdin field is load-bearing: the bearer
    /// token must never be placed in argv.
    public typealias Runner = @Sendable (Invocation) throws -> RunResult

    public static let defaultRemoteSetupTimeout: TimeInterval = 60
    static let maxCapturedOutputBytes = 64 * 1024

    /// Marketplace reference for a remote host, which has no app bundle to
    /// register a local directory from. `claude plugin marketplace add` accepts
    /// an `owner/repo` shorthand, and the repo root carries a
    /// `.claude-plugin/marketplace.json` listing both plugins for exactly this.
    public static let repositoryMarketplaceReference = "T0mSIlver/localvoxtral"

    /// The plugin's sensitive userConfig key. Claude Code exposes it to the
    /// plugin's COMMAND-hook shim as `CLAUDE_PLUGIN_OPTION_TOKEN`; the shim
    /// hands it to curl through a private header file, never an argv. (It is
    /// NOT available to declarative http hooks — Claude Code expands their
    /// header `${VAR}`s from the process environment only, which is why the
    /// plugin uses a command shim at all; verified on 2.1.220.)
    public static let tokenConfigKey = "token"

    /// The plugin's non-sensitive userConfig key: which loopback port on the
    /// REMOTE host the shim posts to. Reaches the shim as
    /// `CLAUDE_PLUGIN_OPTION_PORT` exactly like the token does (both are
    /// command-hook environment; verified end to end on Claude Code 2.1.220 —
    /// a hook run with `--config port=28777` dialed 127.0.0.1:28777).
    ///
    /// It must equal the listen port of this Mac's `RemoteForward`. The plan
    /// always emits both halves together for that reason; changing one alone
    /// fails open, which looks exactly like nothing happening.
    public static let portConfigKey = "port"

    private let runner: Runner?
    private let sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)?

    public init(
        runner: Runner? = nil,
        sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)? = nil
    ) {
        self.runner = runner
        self.sshConfigFileSystem = sshConfigFileSystem
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
    ///   - token: the plaintext used to generate the copyable command and, after
    ///     confirmation, its SSH stdin script. Not stored or logged.
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
    /// `applySSHConfigSnippet` and `sshConfigForwardsPort` both find the block
    /// by them, which is what makes a second apply a no-op instead of a
    /// duplicate `Host` stanza. Everything the twelve deleted `#` lines said —
    /// that `remoteForwardPort` is THIS Mac's allocation and must equal the
    /// plugin's `port` option, that another Mac gets a different one so the two
    /// can never fight over one bind, and why `ExitOnForwardFailure` stays `no`
    /// at the cost of a silently absent tunnel — is prose in
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
            // history. See `notes` — it is a habit, not a guarantee.
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

    /// Bring an enrolled host to the plugin version this app ships, as a
    /// copyable set.
    ///
    /// Comment-free like everything else the user pastes. What the seven `#`
    /// lines used to say is on the docs page and in one short line beside the
    /// panel: re-running setup is NOT an update (on Claude Code 2.1.220
    /// `plugin install` exits 0 with "already installed" and `marketplace add`
    /// does not refresh a clone it has), the stored token is preserved, and the
    /// third command only points this host at THIS Mac's allocated port —
    /// required once for a host enrolled before per-Mac ports, harmless after.
    static func updateCommands(sshHostAlias: String, remoteForwardPort: UInt16) -> [String] {
        remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort).map {
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)\($0)'"
        }
    }

    // MARK: - SSH config editing

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

    /// Atomically insert or replace one host's marked block in `~/.ssh/config`.
    /// The caller is responsible for obtaining the user's explicit confirmation
    /// immediately before calling this method.
    public func insertSSHConfig(_ plan: SetupPlan, hostID: String) throws {
        try insertSSHConfig(snippet: plan.sshConfigSnippet, hostID: hostID)
    }

    /// Same write, for a caller that has a block but no plan — the plugin
    /// update path, which regenerates this host's block so the port it is
    /// about to store on the remote and the port this Mac forwards can never
    /// disagree.
    public func insertSSHConfig(snippet: String, hostID: String) throws {
        Log.claudeContext.info("Claude remote ssh config insertion requested")
        guard let sshConfigFileSystem else {
            Log.claudeContext.error("Claude remote ssh config insertion failed: editing not configured")
            throw ServiceError.sshConfigEditingNotConfigured
        }
        do {
            let state = try sshConfigFileSystem.readState()
            // Trust gate before any write decision: never write through a
            // symlink, and never into a directory another principal can also
            // write. The copy path stays available for such setups.
            guard !state.configIsSymlink, !state.directoryIsSymlink else {
                throw ServiceError.sshConfigIsSymlink
            }
            if state.directoryExists {
                guard state.directoryOwnedByCurrentUser,
                      (state.directoryPermissions ?? 0) & 0o022 == 0
                else { throw ServiceError.sshDirectoryNotTrusted }
            }
            let existing: String
            if let data = state.configData {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw ServiceError.invalidSSHConfigEncoding
                }
                existing = decoded
            } else {
                existing = ""
            }
            let updated = Self.applySSHConfigSnippet(
                to: existing,
                snippet: snippet,
                hostID: hostID
            )
            if !state.directoryExists {
                try sshConfigFileSystem.createSSHDirectory(permissions: 0o700)
            }
            try sshConfigFileSystem.atomicWriteConfig(
                Data(updated.utf8),
                permissions: state.configPermissions ?? 0o600
            )
            Log.claudeContext.info("Claude remote ssh config insertion completed")
        } catch {
            Log.claudeContext.error(
                "Claude remote ssh config insertion failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Does this host's marked block already forward `port`?
    ///
    /// `nil` means "cannot tell" — no filesystem seam, or a config we refuse to
    /// read. Callers must treat nil as "not known to match" and regenerate,
    /// never as "fine": assuming a block is current is exactly how a plugin
    /// gets a port this Mac does not forward.
    public func sshConfigForwardsPort(_ port: UInt16, hostID: String) -> Bool? {
        guard let sshConfigFileSystem else { return nil }
        guard let state = try? sshConfigFileSystem.readState(),
              let data = state.configData,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let begin = Self.blockBegin(hostID: hostID)
        let end = Self.blockEnd(hostID: hostID)
        let lines = text.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == begin
        }), let endIndex = lines[beginIndex...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == end
        }) else { return false }
        return lines[beginIndex...endIndex].contains { line in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == "RemoteForward" else { return false }
            return fields[1] == "\(port)"
        }
    }

    // MARK: - Execution (opt-in only)

    /// Run the plan's remote commands through the injected runner.
    ///
    /// Throws `.executionNotConfigured` when no runner was supplied. Each plan
    /// command is sent to `/bin/sh -s` over SSH stdin. The only spawned argv is
    /// `ssh -o BatchMode=yes -o ClearAllForwardings=yes <alias> /bin/sh -s`,
    /// which contains no token.
    ///
    /// - Parameter token: the plaintext, used ONLY to redact it back out of any
    ///   failure. Nothing here logs or stores it.
    @discardableResult
    public func executeRemoteSetup(
        _ plan: SetupPlan,
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: plan.remoteCommands,
            sshHostAlias: sshHostAlias,
            token: token,
            timeout: timeout,
            label: "setup"
        )
    }

    /// Update the remote plugin on an already-enrolled host.
    ///
    /// Token-free by construction: `claude plugin update` preserves the config
    /// the install stored, so this path never has the credential to leak. It is
    /// a separate entry point rather than a plan step because the user runs it
    /// long after enrollment — when the app ships a new plugin version — and by
    /// then the one-time token is gone.
    @discardableResult
    public func executeRemotePluginUpdate(
        sshHostAlias: String,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: Self.remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort),
            sshHostAlias: sshHostAlias,
            token: "",
            timeout: timeout,
            label: "plugin update"
        )
    }

    private func execute(
        commands: [String],
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval,
        label: String
    ) throws -> [ExecutionStep] {
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution requested")
        guard let runner else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: runner not configured"
            )
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: invalid host alias"
            )
            throw ServiceError.invalidHostAlias
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var completed: [ExecutionStep] = []
        for (index, command) in commands.enumerated() {
            let displayCommand = ClaudeRemoteTokenRedaction.redact(
                command.trimmingCharacters(in: .whitespaces),
                token: token
            )
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            guard remaining > 0 else {
                let failure = ServiceError.commandTimedOut(
                    step: index, command: displayCommand, seconds: timeout, message: ""
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            let invocation = Invocation(
                // ClearAllForwardings: this connection has no use for the
                // 8473 tunnel, and with the user's own session usually holding
                // it, attempting the forward here only produced a scary
                // "remote port forwarding failed" warning inside setup errors
                // (field report 2026-07-26).
                // `--` ends OpenSSH's option parsing: the alias is validated
                // above and cannot start with `-`, and this makes an alias that
                // somehow did reach here a failed connection rather than a
                // silently successful option.
                argv: [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    sshHostAlias, "/bin/sh", "-s",
                ],
                standardInput: Self.remoteScript(command: command),
                timeout: remaining
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) requested"
            )
            let result: RunResult
            do {
                result = try runner(invocation)
            } catch let failure as RunnerFailure {
                let error: ServiceError
                switch failure {
                case .timedOut(let seconds, let message):
                    error = .commandTimedOut(
                        step: index,
                        command: displayCommand,
                        seconds: seconds,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                case .outputTooLarge(_, let message):
                    error = .runnerFailed(
                        step: index,
                        command: displayCommand,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                }
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            } catch {
                let redacted = ClaudeRemoteTokenRedaction.redact(String(describing: error), token: token)
                let failure = ServiceError.runnerFailed(
                    step: index, command: displayCommand, message: redacted
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            guard result.succeeded else {
                let failure = ServiceError.commandFailed(
                    step: index,
                    command: displayCommand,
                    exitCode: result.exitCode,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            completed.append(
                ExecutionStep(
                    index: index,
                    command: displayCommand,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) completed"
            )
        }
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution completed")
        return completed
    }

    // MARK: - Verification (read-only, opt-in only)

    /// Per PROBE, not for the run as a whole.
    ///
    /// A shared deadline starved the second probe: a host that stalls the
    /// tunnel check to its limit left the plugin check with zero budget, so one
    /// slow answer silently became two failures and the user learned nothing
    /// about the plugin (review finding, round 1).
    public static let defaultVerificationTimeout: TimeInterval = 20

    /// Check an enrolled host's setup and return interpreted verdicts.
    ///
    /// Read-only by construction: it writes nothing locally (no filesystem seam
    /// is touched) and runs nothing on the host that changes state — one curl
    /// against the forwarded port and one `claude plugin list`.
    ///
    /// **No probe output ever leaves this method.** Not in `summary`, not in
    /// `hint`, not in `detail` — every string returned is composed here from
    /// exit codes, the HTTP status code, and constants we own. The reason is
    /// specific and was a review finding: `claude plugin list` prints the
    /// plugin's stored userConfig, which after a rotation is the host's OLD
    /// token — a value this process no longer knows and therefore cannot
    /// redact. A redactor cannot save a secret it has never seen, so the output
    /// simply does not travel. Matching against it is free (that is input, not
    /// output); emitting any part of it is not, which is why even the matched
    /// plugin line is reported as the constant name we searched for.
    ///
    /// - Parameters:
    ///   - remoteForwardPort: the port the hooks post to ON THE HOST — this
    ///     Mac's allocation, the same number the snippet's `RemoteForward`
    ///     binds and the plugin's `port` option stores. Probing 8473 here would
    ///     check a tunnel that no longer exists on a per-Mac install.
    ///   - listenerIsBound: whether localvoxtral itself is listening on this
    ///     Mac right now. A 401 proves only that SOMETHING on this Mac answered
    ///     through the tunnel: when our own bind failed, a squatter on the
    ///     listener port receives the forwarded request and its 401 would
    ///     otherwise read as a pass (review finding, round 1).
    ///
    /// Throws only `.executionNotConfigured` (no runner injected — the default)
    /// and `.invalidHostAlias`. Everything else becomes a failed check, so one
    /// broken probe cannot hide the other's answer.
    public func executeVerification(
        sshHostAlias: String,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        listenerIsBound: Bool,
        timeout: TimeInterval = defaultVerificationTimeout
    ) throws -> [VerificationCheck] {
        Log.claudeContext.info("Claude remote verification requested")
        guard let runner else {
            Log.claudeContext.error("Claude remote verification failed: runner not configured")
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error("Claude remote verification failed: invalid host alias")
            throw ServiceError.invalidHostAlias
        }

        let tunnel = runCheck(
            kind: .tunnel,
            runner: runner,
            timeout: timeout,
            // NO ClearAllForwardings, unlike every other connection this type
            // opens: this probe's whole point is that the alias's own `Host`
            // block asks for the RemoteForward. Clearing it would test a tunnel
            // the probe itself just disabled — and pass or fail for the wrong
            // reason.
            argv: ["ssh", "-o", "BatchMode=yes", "--", sshHostAlias, "/bin/sh", "-s"],
            standardInput: Self.tunnelProbeScript(remoteForwardPort: remoteForwardPort)
        ) {
            Self.tunnelCheck(
                result: $0,
                sshHostAlias: sshHostAlias,
                remoteForwardPort: remoteForwardPort,
                listenerIsBound: listenerIsBound
            )
        }

        let plugin = runCheck(
            kind: .plugin,
            runner: runner,
            timeout: timeout,
            // ClearAllForwardings here for the same reason `execute` uses it:
            // this connection has no use for the tunnel, and competing for a
            // port the user's own session already holds only produces a scary
            // warning (field report 2026-07-26).
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                sshHostAlias, "/bin/sh", "-s",
            ],
            standardInput: Self.remoteScript(command: "claude plugin list")
        ) { Self.pluginCheck(result: $0, sshHostAlias: sshHostAlias) }

        Log.claudeContext.info(
            "Claude remote verification completed: tunnel=\(tunnel.passed, privacy: .public) plugin=\(plugin.passed, privacy: .public)"
        )
        return [tunnel, plugin]
    }

    private func runCheck(
        kind: VerificationCheck.Kind,
        runner: Runner,
        timeout: TimeInterval,
        argv: [String],
        standardInput: Data,
        interpret: (RunResult) -> VerificationCheck
    ) -> VerificationCheck {
        do {
            return interpret(
                try runner(
                    Invocation(argv: argv, standardInput: standardInput, timeout: max(timeout, 0))
                )
            )
        } catch let failure as RunnerFailure {
            switch failure {
            case .timedOut(let seconds, _):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The check timed out after \(Int(seconds))s.",
                    hint: "The host did not answer in time.",
                    detail: "Probe timed out after \(Int(seconds))s."
                )
            case .outputTooLarge(let capBytes, _):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The host produced too much output to read.",
                    detail: "Probe output exceeded \(capBytes / 1024) KB and was stopped."
                )
            }
        } catch {
            // Deliberately not `String(describing: error)`: a runner's error is
            // not this method's output to vouch for, and the invariant above is
            // absolute.
            return VerificationCheck(
                kind: kind,
                passed: false,
                summary: "The check could not run.",
                detail: "The probe could not be started."
            )
        }
    }

    /// Unauthenticated probe of the forwarded listener.
    ///
    /// The script always exits 0 and prints one token, so a non-zero exit can
    /// only mean SSH itself failed. Without that, curl's connect failure (exit
    /// 7) and ssh's own failure (255) would be the same observation, and "no
    /// tunnel" would be reported as "cannot reach the host".
    /// Prefix that FRAMES the probe's own output.
    ///
    /// The probe's answer is one line this script printed, and nothing else on
    /// the connection may be mistaken for it: a login banner, an rc-file echo,
    /// or a MOTD ending in `401` would otherwise decide a verdict. Parsing takes
    /// the FIRST `LVX_`-framed line and ignores every other byte.
    ///
    /// The residual, stated plainly: a HOSTILE host can print the frame itself
    /// and say whatever it likes about its own reachability. That is accepted —
    /// it is a machine the user enrolled, lying about whether it can reach them,
    /// with no mutation and no credential consequence on either side (the probe
    /// sends none and writes nothing). Framing exists to stop ACCIDENTS, not to
    /// authenticate the host.
    static let probeFramePrefix = "LVX_"
    /// Framed answer carrying the HTTP status code the host observed.
    static let httpFramePrefix = "LVX_HTTP:"
    /// Printed when the host has no `curl`. A missing curl and a refused
    /// connection both produce "nothing came back" otherwise, and they have
    /// completely different fixes — the plugin's shim IS curl, so a host
    /// without it can never deliver context no matter how healthy the tunnel.
    static let missingCurlSentinel = "LVX_NO_CURL"

    static func tunnelProbeScript(remoteForwardPort: UInt16) -> Data {
        Data("""
        set -u
        command -v curl >/dev/null 2>&1 || { printf '%s\\n' '\(missingCurlSentinel)'; exit 0; }
        code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:\(remoteForwardPort)/v1/hook/SessionStart 2>/dev/null) || code=000
        [ -n "$code" ] || code=000
        printf '\(httpFramePrefix)%s\\n' "$code"

        """.utf8)
    }

    /// The first framed line, or nil when the probe never spoke.
    static func framedProbeAnswer(in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(probeFramePrefix) }
    }

    /// The local half of the tunnel verdict, as its own value.
    ///
    /// Shared by the capture-time check and the interpretation-time
    /// reconciliation so the two can never drift into different copy for the
    /// same situation.
    static func squatterTunnelCheck(remoteForwardPort: UInt16) -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: false,
            summary: "Something else answered on port \(remoteForwardPort).",
            hint: "localvoxtral is not listening on this Mac, so the reply came from "
                + "whatever holds the port. Fix that first, then check again.",
            detail: "HTTP 401 arrived while this Mac's listener was not bound."
        )
    }

    /// Re-apply the local half of the tunnel verdict after the probes returned.
    ///
    /// `listenerIsBound` is read TWICE on purpose — once before the probes are
    /// launched and once here, after up to a full timeout of detached ssh work
    /// (review finding, round 2). A listener that died in between leaves the
    /// port to whoever grabs it next, and that squatter answers the forwarded
    /// request with the same 401 we treat as proof. The ✓ therefore requires
    /// bound at BOTH moments; either one false is the squatter verdict.
    ///
    /// Only a PASSING tunnel check can be downgraded here. Every other verdict
    /// already described something the host said, and an unbound listener does
    /// not make "curl is missing over there" less true.
    public static func reconciled(
        _ checks: [VerificationCheck],
        remoteForwardPort: UInt16,
        listenerIsBound: Bool
    ) -> [VerificationCheck] {
        guard !listenerIsBound else { return checks }
        return checks.map { check in
            guard check.kind == .tunnel, check.passed else { return check }
            return squatterTunnelCheck(remoteForwardPort: remoteForwardPort)
        }
    }

    static func tunnelCheck(
        result: RunResult,
        sshHostAlias: String,
        remoteForwardPort: UInt16,
        listenerIsBound: Bool
    ) -> VerificationCheck {
        guard result.succeeded else {
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Could not reach \(sshHostAlias) over SSH.",
                hint: "Run `ssh \(sshHostAlias) true` in a terminal to see why.",
                detail: "ssh exited with code \(result.exitCode)."
            )
        }

        // Only our own framed line decides anything; everything else the
        // connection printed is ignored by construction.
        let answer = framedProbeAnswer(in: result.message)

        if answer == missingCurlSentinel {
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "curl is missing on \(sshHostAlias).",
                hint: "The plugin's hooks are a curl one-liner. Install curl there.",
                detail: "The probe reported no curl on the host."
            )
        }

        // A code is three digits or it is not a code. Anything else — including
        // no framed line at all, which means the script never got to print one
        // — is "nothing answered", not a status.
        let code = answer
            .flatMap { $0.hasPrefix(httpFramePrefix) ? String($0.dropFirst(httpFramePrefix.count)) : nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.count == 3 && $0.allSatisfy(\.isNumber) ? $0 : nil }

        switch code {
        case "401":
            // 401 is the pass — an unauthenticated probe MUST be refused — but
            // only half of it. It proves the request crossed the tunnel and
            // something on this Mac answered; that the something was us is the
            // caller's fact, not the host's, and `reconciled` re-checks it after
            // the probes return.
            guard listenerIsBound else {
                return squatterTunnelCheck(remoteForwardPort: remoteForwardPort)
            }
            return VerificationCheck(
                kind: .tunnel,
                passed: true,
                summary: "Tunnel is up and localvoxtral answered.",
                detail: "HTTP 401 (the expected refusal of an unauthenticated probe)."
            )
        case "000", nil:
            return listenerIsBound
                ? VerificationCheck(
                    kind: .tunnel,
                    passed: false,
                    summary: "No tunnel is live right now.",
                    hint: "The forward exists only while an SSH session to \(sshHostAlias) is open.",
                    detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort)."
                )
                : VerificationCheck(
                    kind: .tunnel,
                    passed: false,
                    summary: "Nothing answered, and localvoxtral is not listening here.",
                    hint: "Fix the listener on this Mac first — this check cannot tell you "
                        + "anything about the tunnel until it is bound.",
                    detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort), "
                        + "and this Mac's listener was not bound."
                )
        case .some(let code):
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Something else answered on port \(remoteForwardPort).",
                hint: "Only localvoxtral should answer there. Find what holds the port and quit it.",
                // Three digits this process validated, not remote text passed
                // through.
                detail: "The reply was HTTP \(code)."
            )
        }
    }

    static func pluginCheck(result: RunResult, sshHostAlias: String) -> VerificationCheck {
        // `contains` reads the output; nothing below emits it. See
        // `executeVerification` for why that line is absolute here.
        if result.exitCode == 127 || result.message.contains("'claude' was not found") {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Claude Code was not found on \(sshHostAlias).",
                hint: "Install Claude Code there, or put it on the non-interactive SSH PATH.",
                detail: "The host's non-interactive shell could not resolve `claude` "
                    + "(the probe's own PATH resolver reported it and exited 127)."
            )
        }
        guard result.succeeded else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Could not list plugins on \(sshHostAlias).",
                hint: "Run `ssh \(sshHostAlias) true` in a terminal to see whether the host is reachable.",
                detail: "`claude plugin list` exited with code \(result.exitCode)."
            )
        }
        guard result.message.contains(ClaudePluginAssets.remotePluginName) else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "The plugin is not installed on \(sshHostAlias).",
                hint: "Run step 2 on the host.",
                detail: "`claude plugin list` did not name \(ClaudePluginAssets.remotePluginName)."
            )
        }
        return VerificationCheck(
            kind: .plugin,
            passed: true,
            summary: "The plugin is installed.",
            // The constant we searched for, never the line we found it in: that
            // line can carry the plugin's stored token.
            detail: "`claude plugin list` named \(ClaudePluginAssets.remotePluginName)."
        )
    }

    /// PATH resolution for `claude` under `ssh <host> /bin/sh -s`.
    ///
    /// Non-interactive SSH shells run with sshd's minimal PATH (no login rc),
    /// which usually lacks the user-local directories claude installs into —
    /// the field failure was dash's bare `claude: not found` on a host where
    /// claude worked fine interactively. Probe the same locations the local
    /// installer does (`ClaudePluginInstallService.claudeCLICandidates`), plus
    /// nvm-style node bins, and fail with an actionable message instead of
    /// dash's. POSIX sh only — the remote /bin/sh is dash on Debian-family
    /// hosts. Token-free by construction, like the `set -eu` line: the
    /// confirmation shows the commands the user authorizes; this is part of
    /// how they run.
    static let claudePathResolverPreamble = """
        if ! command -v claude >/dev/null 2>&1; then
          for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
            if [ -x "$lv_dir/claude" ]; then PATH="$lv_dir:$PATH"; break; fi
          done
        fi
        if ! command -v claude >/dev/null 2>&1; then
          echo "localvoxtral: 'claude' was not found on this host's non-interactive PATH, nor in ~/.claude/local, ~/.local/bin, ~/bin, /opt/homebrew/bin, /usr/local/bin, or ~/.nvm/versions/node/*/bin. Run 'command -v claude' in a normal shell on this host, then rerun setup — or add that directory to PATH for non-interactive SSH shells." >&2
          exit 127
        fi

        """

    static func remoteScript(command: String) -> Data {
        // The resolver only guards commands that actually invoke claude, so a
        // future non-claude step cannot be failed by a missing CLI it never
        // needed.
        let preamble = command.contains("claude") ? claudePathResolverPreamble : ""
        return Data("set -eu\n\(preamble)\(command)\n".utf8)
    }
}
