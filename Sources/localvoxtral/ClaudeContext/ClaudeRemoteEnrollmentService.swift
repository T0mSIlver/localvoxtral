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
    /// The two pieces of text the user actually has to apply, and nothing else.
    ///
    /// Everything copyable here is comment-free (owner rule, 2026-08-04:
    /// "commands you have to copy-paste have comments, that's just dumb —
    /// display it in the app or not at all"). The explanations that used to ride
    /// along as `#` lines are now either decided by the app (verification, see
    /// `executeVerification`) or written as prose in
    /// `docs/remote-claude-context.md`. The only `#` lines left in the snippet
    /// are the BEGIN/END delimiters, which are functional: the idempotent
    /// replace keys on them.
    public struct SetupPlan: Sendable, Equatable {
        /// Idempotent `~/.ssh/config` block. Contains NO token — the credential
        /// belongs to the Claude plugin's userConfig on the remote host, not to
        /// a file that gets copied between machines and pasted into issues.
        public var sshConfigSnippet: String
        /// Run on the REMOTE host, once.
        public var remoteCommands: [String]
    }

    /// One interpreted verdict from `executeVerification`.
    ///
    /// The interpretation IS the deliverable. The old flow shipped three
    /// copy-paste commands wrapped in nine `#` lines explaining how to read
    /// their output — including that HTTP 401 is the success signal — and the
    /// field failure (2026-07-26) was a person reading healthy output as broken
    /// anyway. Anything the app can decide, the app decides; the user gets a ✓
    /// or a ✗ and one short line.
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
        /// Raw command output. Alert detail and the log only, never inline
        /// (owner rule: no long text in a pane).
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
    public static func plan(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        token: String,
        port: UInt16 = ClaudeRemoteListenerLimits.default.port
    ) throws -> SetupPlan {
        guard isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }

        return SetupPlan(
            sshConfigSnippet: sshConfigSnippet(host: host, sshHostAlias: sshHostAlias, port: port),
            remoteCommands: remoteCommands(token: token)
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

    /// The block the user pastes (or lets the app insert) into `~/.ssh/config`.
    ///
    /// Comment-free apart from the two delimiters, which are load-bearing:
    /// `applySSHConfigSnippet` finds and replaces the block by them, which is
    /// what makes a second apply a no-op instead of a duplicate `Host` stanza.
    ///
    /// `ExitOnForwardFailure no` (the default, stated explicitly so a global
    /// `yes` in the user's config cannot claim this host) is deliberate, and the
    /// reasoning that used to sit here as six `#` lines the user had to read
    /// while pasting now lives in `docs/remote-claude-context.md`: `yes` would
    /// refuse the whole SSH session when the remote's port is already bound —
    /// usually by the user's own second window — and a dictation nicety must
    /// never cost someone their shell. The cost of `no` is a silently absent
    /// tunnel, which is exactly what the in-app check reports.
    static func sshConfigSnippet(host: ClaudeRemoteHost, sshHostAlias: String, port: UInt16) -> String {
        """
        \(blockBegin(hostID: host.id))
        Host \(sshHostAlias)
            RemoteForward \(port) 127.0.0.1:\(port)
            ExitOnForwardFailure no
        \(blockEnd(hostID: host.id))
        """
    }

    static func remoteCommands(token: String) -> [String] {
        [
            "claude plugin marketplace add \(repositoryMarketplaceReference)",
            // Leading space: with HISTCONTROL=ignorespace (bash) or
            // HIST_IGNORE_SPACE (zsh) the token stays out of the remote shell
            // history. A habit, not a guarantee — the docs page says so, and
            // rotation is the recovery.
            " claude plugin install \(remotePluginReference) --config '\(tokenConfigKey)=\(token)'",
        ]
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
                snippet: plan.sshConfigSnippet,
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
        Log.claudeContext.info("Claude remote setup execution requested")
        guard let runner else {
            Log.claudeContext.error("Claude remote setup execution failed: runner not configured")
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error("Claude remote setup execution failed: invalid host alias")
            throw ServiceError.invalidHostAlias
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var completed: [ExecutionStep] = []
        for (index, command) in plan.remoteCommands.enumerated() {
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
                    "Claude remote setup step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            let invocation = Invocation(
                // ClearAllForwardings: the setup connection has no use for the
                // 8473 tunnel, and with the user's own session usually holding
                // it, attempting the forward here only produced a scary
                // "remote port forwarding failed" warning inside setup errors
                // (field report 2026-07-26).
                argv: [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                    sshHostAlias, "/bin/sh", "-s",
                ],
                standardInput: Self.remoteScript(command: command),
                timeout: remaining
            )
            Log.claudeContext.info(
                "Claude remote setup step \(index + 1, privacy: .public) requested"
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
                    "Claude remote setup step \(index + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            } catch {
                let redacted = ClaudeRemoteTokenRedaction.redact(String(describing: error), token: token)
                let failure = ServiceError.runnerFailed(
                    step: index, command: displayCommand, message: redacted
                )
                Log.claudeContext.error(
                    "Claude remote setup step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
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
                    "Claude remote setup step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
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
                "Claude remote setup step \(index + 1, privacy: .public) completed"
            )
        }
        Log.claudeContext.info("Claude remote setup execution completed")
        return completed
    }

    // MARK: - Verification (read-only, opt-in only)

    public static let defaultVerificationTimeout: TimeInterval = 30

    /// Check an enrolled host's setup and return interpreted verdicts.
    ///
    /// Read-only by construction: it writes nothing locally (no filesystem seam
    /// is touched) and runs nothing on the host that changes state — one curl
    /// against the forwarded listener and one `claude plugin list`.
    ///
    /// No token is involved. The tunnel probe is deliberately UNAUTHENTICATED:
    /// the listener must refuse it, and that refusal (HTTP 401) is the proof
    /// that the forward reached localvoxtral rather than something else. There
    /// is therefore no credential to redact here — the caller redacts captured
    /// output before it reaches an alert or the log, because the HOST's
    /// `claude plugin list` may echo the plugin's configured token.
    ///
    /// Throws only `.executionNotConfigured` (no runner injected — the default)
    /// and `.invalidHostAlias`. Everything else becomes a failed check, so one
    /// broken probe cannot hide the other's answer.
    public func executeVerification(
        sshHostAlias: String,
        port: UInt16 = ClaudeRemoteListenerLimits.default.port,
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

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        let tunnel = runCheck(
            kind: .tunnel,
            runner: runner,
            deadline: deadline,
            // NO ClearAllForwardings, unlike `executeRemoteSetup`: this probe's
            // whole point is that the alias's own `Host` block asks for the
            // RemoteForward. Clearing it would make the check test a tunnel it
            // just disabled — and pass or fail for the wrong reason.
            argv: ["ssh", "-o", "BatchMode=yes", sshHostAlias, "/bin/sh", "-s"],
            standardInput: Self.tunnelProbeScript(port: port)
        ) { Self.tunnelCheck(result: $0, sshHostAlias: sshHostAlias, port: port) }

        let plugin = runCheck(
            kind: .plugin,
            runner: runner,
            deadline: deadline,
            // ClearAllForwardings here for the same reason setup uses it: this
            // connection has no use for the tunnel, and competing for a port the
            // user's real session already holds only prints a scary warning into
            // the captured output (field report 2026-07-26).
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
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
        deadline: Date,
        argv: [String],
        standardInput: Data,
        interpret: (RunResult) -> VerificationCheck
    ) -> VerificationCheck {
        let remaining = max(deadline.timeIntervalSinceNow, 0)
        guard remaining > 0 else {
            return VerificationCheck(
                kind: kind,
                passed: false,
                summary: "The check ran out of time.",
                hint: "Try again — a host that is slow to answer can need a second run."
            )
        }
        do {
            return interpret(
                try runner(
                    Invocation(argv: argv, standardInput: standardInput, timeout: remaining)
                )
            )
        } catch let failure as RunnerFailure {
            switch failure {
            case .timedOut(let seconds, let message):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The check did not finish within \(Int(seconds))s.",
                    hint: "The host did not answer in time.",
                    detail: message
                )
            case .outputTooLarge(_, let message):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The host produced too much output to read.",
                    detail: message
                )
            }
        } catch {
            return VerificationCheck(
                kind: kind,
                passed: false,
                summary: "The check could not run.",
                detail: String(describing: error)
            )
        }
    }

    /// Unauthenticated probe of the forwarded listener.
    ///
    /// The script always exits 0 and prints the status code, so a non-zero exit
    /// can only mean SSH itself failed. Without that, curl's connect failure
    /// (exit 7) and ssh's own failure (255) would be the same observation, and
    /// "no tunnel" would be reported as "cannot reach the host".
    static func tunnelProbeScript(port: UInt16) -> Data {
        Data("""
        set -u
        code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:\(port)/v1/hook/SessionStart 2>/dev/null) || code=000
        [ -n "$code" ] || code=000
        printf '%s\\n' "$code"

        """.utf8)
    }

    static func tunnelCheck(
        result: RunResult,
        sshHostAlias: String,
        port: UInt16
    ) -> VerificationCheck {
        guard result.succeeded else {
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Could not reach \(sshHostAlias) over SSH.",
                hint: "Check the host alias in ~/.ssh/config and that the host is up.",
                detail: result.message
            )
        }
        let code = result.message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        switch code {
        case "401":
            // 401 IS the pass. An unauthenticated probe must be refused, so
            // being refused proves both that the tunnel carried the request and
            // that localvoxtral — which alone holds the token hashes — answered.
            return VerificationCheck(
                kind: .tunnel,
                passed: true,
                summary: "Tunnel is up and localvoxtral answered.",
                detail: result.message
            )
        case "000", "":
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "No tunnel is live right now.",
                hint: "The forward exists only while an SSH session to \(sshHostAlias) is open.",
                detail: result.message
            )
        default:
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Something else answered on port \(port).",
                hint: "Only localvoxtral should answer there. Find what holds the port and quit it.",
                detail: result.message
            )
        }
    }

    static func pluginCheck(result: RunResult, sshHostAlias: String) -> VerificationCheck {
        if result.exitCode == 127 || result.message.contains("'claude' was not found") {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Claude Code was not found on \(sshHostAlias).",
                hint: "Install Claude Code there, or put it on the non-interactive SSH PATH.",
                detail: result.message
            )
        }
        guard result.succeeded else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Could not list plugins on \(sshHostAlias).",
                hint: "Check the host alias in ~/.ssh/config and that the host is up.",
                detail: result.message
            )
        }
        guard result.message.contains(ClaudePluginAssets.remotePluginName) else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "The plugin is not installed on \(sshHostAlias).",
                hint: "Run step 2 on the host.",
                detail: result.message
            )
        }
        return VerificationCheck(
            kind: .plugin,
            passed: true,
            summary: "The plugin is installed.",
            detail: result.message
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
