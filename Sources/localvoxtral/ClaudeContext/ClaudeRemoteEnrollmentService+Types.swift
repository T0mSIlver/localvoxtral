import Foundation

extension ClaudeRemoteEnrollmentService {
    /// The text the user actually has to apply, and nothing else.
    ///
    /// Everything here is comment-free (owner rule, 2026-08-04: "commands you
    /// have to copy-paste have comments, that's just dumb — display it in the
    /// app or not at all"). The explanations that used to ride along as `#`
    /// lines are now either decided by the app (verification — see
    /// `executeVerification`) or written as prose in
    /// `docs/remote-claude-context.md`. The only `#` lines that survive are the
    /// snippet's BEGIN/END delimiters, which are functional: the idempotent
    /// replace and `sshConfigBlockIsCurrent` both key on them.
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

        /// Which fact produced this verdict.
        ///
        /// Only a verdict decided by the LOCAL listener may be re-evaluated
        /// after the probes return: a listener that rebinds mid-probe makes our
        /// own squatter call wrong, but it cannot turn "the host said nothing"
        /// into "the host answered" (review finding, round 3).
        public enum Decider: String, Sendable, Equatable {
            /// The host's answer decided it — the code, the sentinel, or ssh.
            case remote
            /// This Mac's listener state decided it, and only that.
            case localListener
        }

        public var kind: Kind
        public var passed: Bool
        public var decidedBy: Decider = .remote
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
            detail: String = "",
            decidedBy: Decider = .remote
        ) {
            self.kind = kind
            self.passed = passed
            self.summary = summary
            self.hint = hint
            self.detail = detail
            self.decidedBy = decidedBy
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
        /// Values added to the child process environment. Used by the
        /// SendEnv probe so its nonce never appears in argv or stdin.
        public var environment: [String: String]
        /// How much the runner will carry for this invocation. The default is
        /// what every enrollment script needs and no more; an invocation that
        /// moves FILES (the Vibe hooks setup) asks for a larger one by name.
        public var budget: Budget

        public struct Budget: Sendable, Equatable {
            public var standardInputBytes: Int
            public var outputBytes: Int
            /// How much of the output reaches `RunResult.message`. The default
            /// is a diagnostic-sized prefix; a caller that PARSES the output
            /// needs all of it.
            public var messageCharacters: Int

            public init(standardInputBytes: Int, outputBytes: Int, messageCharacters: Int) {
                self.standardInputBytes = standardInputBytes
                self.outputBytes = outputBytes
                self.messageCharacters = messageCharacters
            }

            public static let standard = Budget(
                standardInputBytes: 8 * 1024,
                outputBytes: ClaudeRemoteEnrollmentService.maxCapturedOutputBytes,
                messageCharacters: 2_000
            )
        }

        public init(
            argv: [String],
            standardInput: Data,
            timeout: TimeInterval,
            environment: [String: String] = [:],
            budget: Budget = .standard
        ) {
            self.argv = argv
            self.standardInput = standardInput
            self.timeout = timeout
            self.environment = environment
            self.budget = budget
        }
    }

    public enum PluginSetupOutcome: Sendable, Equatable {
        case installed
        case updated
        case alreadyCurrent
        /// The host has no Claude Code, so nothing was installed. Not a
        /// failure: the host's setup run installs what it finds.
        case claudeNotFound
    }

    public enum EnvironmentCrossingOutcome: Sendable, Equatable {
        case crossed
        case localSendEnvMissing
        case remoteAcceptEnvMissing
    }

    public enum HerdrSetupOutcome: Sendable, Equatable {
        case configured
        case notFound
        case customized
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
    /// caught by `sanitizedRunnerError`, which keeps only the category and
    /// drops the message; callers never receive one.
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
        /// The LOCAL herdr config already contains an agents table or a rows
        /// key. Same conservative rule as the remote setup step: a federated
        /// herdr 0.9 client renders the `$lvmark` row from its OWN local
        /// config (`ClientShellConfig::from_config`), so this is the file the
        /// enrollment offer patches — and only when it carries no agents
        /// configuration of the user's to clobber.
        case localHerdrPanelConfigAlreadyCustomized
        /// No local herdr config filesystem was injected, which is the default.
        case localHerdrConfigEditingNotConfigured
        /// The local herdr config exists but cannot be read as UTF-8, or is a
        /// symlink a rename would silently replace. Report, never repair.
        case localHerdrConfigUnreadable
    }
}
