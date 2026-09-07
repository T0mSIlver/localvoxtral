import Foundation
import Observation

#if canImport(Darwin)
import Darwin
#endif

/// The plugin half of the Settings surface, as a seam.
///
/// `ClaudePluginInstallService` is a struct that shells out to `claude`; this
/// protocol is what the Settings model actually depends on, so a test can drive
/// every branch — success, CLI absent, command failed — without a Claude Code
/// install on the machine. On CI the build host HAS Claude Code, which is
/// exactly what makes "reports when the CLI is missing" untestable against the
/// real thing.
public protocol ClaudePluginInstalling: Sendable {
    func installPlugin() throws
    func updatePlugin() throws
    func uninstallPlugin() throws
    /// stdout of `claude plugin list`, or nil when the listing is unavailable.
    /// Default nil so test doubles that only exercise install paths keep
    /// working; the pane then reports `.unknown` rather than guessing.
    func pluginListOutput() throws -> String?
}

extension ClaudePluginInstalling {
    public func pluginListOutput() throws -> String? { nil }
}

extension ClaudePluginInstallService: ClaudePluginInstalling {}

/// A Sendable snapshot of a plugin-action failure.
///
/// `any Error` is an existential and is NOT Sendable, so it cannot be returned
/// out of the detached task the action runs in — Swift 6 rejects it, correctly.
/// Everything the pane needs is captured here at the throw site instead: the
/// typed case when it is one of ours, and a description otherwise.
public struct ClaudePluginActionFailure: Sendable, Equatable {
    public var serviceError: ClaudePluginInstallService.ServiceError?
    public var describedError: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudePluginInstallService.ServiceError
        describedError = String(describing: error)
    }
}

public struct ClaudeEnrollmentActionFailure: Sendable, Equatable {
    public var serviceError: ClaudeRemoteEnrollmentService.ServiceError?
    public var describedError: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudeRemoteEnrollmentService.ServiceError
        describedError = String(describing: error)
    }
}

/// The verification counterpart of `ClaudeEnrollmentActionAttempt`: verdicts,
/// or the reason there are none. Same shape for the same reason — `any Error`
/// is not Sendable and cannot come back out of the detached task.
public struct ClaudeVerificationAttempt: Sendable, Equatable {
    public var checks: [ClaudeRemoteEnrollmentService.VerificationCheck]
    public var failure: ClaudeEnrollmentActionFailure?

    public init(
        checks: [ClaudeRemoteEnrollmentService.VerificationCheck],
        failure: ClaudeEnrollmentActionFailure?
    ) {
        self.checks = checks
        self.failure = failure
    }
}

public struct ClaudeEnrollmentActionAttempt: Sendable, Equatable {
    public var steps: [ClaudeRemoteEnrollmentService.ExecutionStep]
    public var failure: ClaudeEnrollmentActionFailure?

    public init(
        steps: [ClaudeRemoteEnrollmentService.ExecutionStep],
        failure: ClaudeEnrollmentActionFailure?
    ) {
        self.steps = steps
        self.failure = failure
    }
}

/// One consented setup attempt for one remote host.
public struct RemoteHostSetupRun: Sendable, Equatable {
    public enum Step: Int, CaseIterable, Sendable, Equatable, Identifiable {
        case sshConfig
        case shellStartup
        case remotePlugin
        case environmentCrossing
        case remoteHerdr
        case checkSetup

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .sshConfig: return "Mac SSH config"
            case .shellStartup: return "Mac shell startup"
            case .remotePlugin: return "Remote plugin"
            case .environmentCrossing: return "Terminal environment"
            case .remoteHerdr: return "Remote herdr"
            case .checkSetup: return "Check setup"
            }
        }
    }

    public enum State: Sendable, Equatable {
        case pending
        case running
        case done(String)
        case skipped(String)
        case failed(reason: String, remedy: String)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var step: Step
        public var state: State
        public var id: Int { step.rawValue }
    }

    public var hostID: String
    public var startedAt: Date
    public var items: [Item]

    public init(hostID: String, startedAt: Date) {
        self.hostID = hostID
        self.startedAt = startedAt
        items = Step.allCases.map { Item(step: $0, state: .pending) }
    }
}

/// What the pane can say about the plain-ssh join's one setup step.
///
/// Two facts, deliberately separate, because they fail for different reasons
/// and only the user can fix the first: is the export in the rc file, and has
/// a session actually arrived carrying it. A block written five seconds ago
/// proves nothing until a NEW ssh session starts, and saying so is the whole
/// value of the second half.
public struct ClaudeShellSetupStatus: Sendable, Equatable {
    public enum RCState: Sendable, Equatable {
        /// The login shell is not one this app writes for.
        case unsupportedShell
        case notApplied
        case applied
        /// The rc file could not be read, or is a symlink we will not write
        /// through.
        case unknown
    }

    public enum CrossingState: Sendable, Equatable {
        /// No enrolled host has a live session at all — nothing to say yet.
        case noSessions
        /// Live sessions, none carrying the value: the usual "you have not
        /// opened a new window yet".
        case notSeen
        case seen
    }

    public var rc: RCState
    public var crossing: CrossingState
    /// The rc file this app would write, relative to `$HOME` — shown so the
    /// user knows what they are being asked to let us edit.
    public var relativeRCPath: String?

    public init(
        rc: RCState = .unknown,
        crossing: CrossingState = .noSessions,
        relativeRCPath: String? = nil
    ) {
        self.rc = rc
        self.crossing = crossing
        self.relativeRCPath = relativeRCPath
    }

    /// One short sentence, per the pane's copy rule. Never restates the label,
    /// never a path or a host.
    public var rcSentence: String {
        switch rc {
        case .unsupportedShell: return "Your login shell is not one this can set up."
        case .notApplied: return "Not set up."
        case .applied: return "Set up."
        case .unknown: return "Could not read your shell startup file."
        }
    }

    public var crossingSentence: String {
        switch crossing {
        case .noSessions: return "No remote session has reported in yet."
        case .notSeen: return "Open a new terminal window for it to take effect."
        case .seen: return "A remote session is reporting its terminal."
        }
    }
}

/// Settings-pane state for both Claude Code integrations.
///
/// `@MainActor @Observable`, per repo convention for stateful UI controllers.
/// Every dependency is injected: no singleton reaches through this type to a
/// real process, a real port, or a real host.
///
/// The division of labour with the view is deliberate. Failures, port
/// conflicts, and short consent text are decided here, where they have tests.
/// The view renders those strings without exposing generated configuration.
@MainActor
@Observable
public final class ClaudeIntegrationSettingsModel {
    /// One row in the enrolled-hosts list. Carries no secret: `ClaudeRemoteHost`
    /// has no token, by construction.
    public struct HostRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        /// Nil for hosts enrolled before the alias was persisted. Never
        /// substituted with `label`: they are different fields on the form, so
        /// guessing one from the other can ssh to a machine the user did not
        /// pick.
        public var sshHostAlias: String?
        public var isRevoked: Bool
        public var lastSeenAt: Date?
        /// The whole status, resolved against the model's injected clock when
        /// the row was built.
        ///
        /// Rendered rather than computed in the view for two reasons. A
        /// `RelativeDateTimeFormatter` cached in a `static let` would be
        /// non-Sendable global state (a Swift 6 error), and building one per row
        /// per redraw is worse — but mostly, "when did this host last send
        /// context" is the answer a user needs to tell a silent tunnel from a
        /// working one, and an answer with a test beats an answer with a
        /// formatter.
        public var statusText: String
        /// Whether this host opted into the app-held SSH forward, and what that
        /// forward is doing right now. Both live on the row so the view stays a
        /// renderer: the toggle reads one Bool, the status line reads one
        /// already-rendered sentence.
        public var persistentForwardEnabled: Bool = false
        public var forwardStatusText: String?
        public var forwardIsFailure: Bool = false
        /// A forward can only be offered where we know where to ssh. The label
        /// is not a substitute for an alias (PR #197).
        public var canHoldForward: Bool = false
        /// Last setup outcome for this host during the current app session.
        public var setupStatusText: String?
    }

    /// "Last context: 2 min ago", from a clock the caller supplies.
    ///
    /// Coarse on purpose: the question is "is this host still talking to me",
    /// and a to-the-second answer would only invite the user to read precision
    /// into a timestamp that is refreshed when the pane appears.
    ///
    /// `lastSeenAt` is the registry's IN-MEMORY value, persisted only on the
    /// next persisting mutation (see `ClaudeRemoteHostRegistry.noteActivity` —
    /// a disk write per hook event would be steady write amplification for a
    /// dictation nicety). So a host that was active before a relaunch reads
    /// "never" until its next hook event. That is the existing trade, not a
    /// missing write.
    static func hostStatusText(isRevoked: Bool, lastSeenAt: Date?, now: Date) -> String {
        if isRevoked { return "Revoked" }
        guard let lastSeenAt else { return "Last context: never" }
        let elapsed = now.timeIntervalSince(lastSeenAt)
        // A clock that stepped backwards (NTP, a DST correction) must not print
        // a negative age. "Just now" is the honest reading of "not in the past".
        guard elapsed >= 60 else { return "Last context: just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "Last context: \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Last context: \(hours) \(hours == 1 ? "hour" : "hours") ago" }
        let days = hours / 24
        return "Last context: \(days) \(days == 1 ? "day" : "days") ago"
    }

    /// What the pane says about the listener, in one short line.
    ///
    /// Short because it goes in Settings next to a row (owner rule: long text
    /// belongs in the alert and the log, never in the popover, and a Settings
    /// status line has the same problem for the same reason). The DETAIL of a
    /// failure goes to `alert` and to `Log`.
    public enum ListenerStatus: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case portConflict(port: UInt16)
        case failed

        public var text: String {
            switch self {
            case .idle: return "Not listening because no hosts are enrolled."
            case .listening(let port): return "Listening on 127.0.0.1:\(port)."
            case .portConflict(let port): return "Port \(port) is already in use."
            case .failed: return "Could not start listening."
            }
        }

        /// The actionable half, when there is one. Settings shows this under the
        /// status; a status that only says "it broke" is a bug report, not a UI.
        public var remedy: String? {
            switch self {
            case .idle, .listening: return nil
            case .portConflict(let port):
                return "Another app holds \(port), often a second copy of localvoxtral. "
                    + "Quit it and press Retry."
            case .failed: return "See Console for details, then press Retry."
            }
        }

        public var isFailure: Bool {
            switch self {
            case .idle, .listening: return false
            case .portConflict, .failed: return true
            }
        }
    }

    /// A freshly issued credential and its setup plan, held for exactly as long
    /// as the sheet showing it is up.
    ///
    /// This is the only place in the app where a plaintext token lives past the
    /// call that made it. It is `private(set)`, it is cleared by `dismissPlan`,
    /// and nothing writes it anywhere. The registry cannot reissue it — that is
    /// the whole point of storing only hashes. It is not persisted locally;
    /// automated setup carries it only in the confirmed SSH process's stdin.
    /// Rotation is the recovery path.
    public struct EnrollmentPresentation: Identifiable, Equatable, Sendable {
        public var id: String { host.id }
        public var host: ClaudeRemoteHost
        public var token: String
        public var sshHostAlias: String
        public var plan: ClaudeRemoteEnrollmentService.SetupPlan
        /// Rotation reuses this sheet because the user's remote is currently
        /// broken on purpose and needs the same complete setup run.
        public var isRotation: Bool
        /// False when `sshHostAlias` is the sheet's placeholder rather than an
        /// alias the user gave us — a legacy host rotated before the alias was
        /// persisted. Automated execution is withheld because it would hand a
        /// fresh token to whichever machine answered to a guessed name.
        public var canRunRemoteSetup: Bool = true
        /// The port the snippet forwards ON THE HOST — this Mac's allocation.
        /// Carried here rather than re-read at check time so verification can
        /// only ever probe the port the config in front of the user names.
        public var remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort
        /// Sample sheet for screenshots. Every mutating entry point refuses a
        /// preview presentation, so it can neither write ~/.ssh/config, spawn
        /// ssh, nor touch the registry — see `presentPreviewPlan`.
        public var isPreview: Bool = false
    }

    /// The generated update plan for one enrolled host.
    public struct PluginUpdatePresentation: Identifiable, Equatable, Sendable {
        public var id: String { hostID }
        public var hostID: String
        /// The alias automated execution uses, or nil for a legacy host that
        /// must be re-enrolled before the app can safely address it.
        public var sshHostAlias: String?
        public var commands: [String]
        /// This host's regenerated ssh-config block, when the local one does
        /// not already forward the port these commands are about to store on
        /// the remote — nil when it already matches and there is nothing to
        /// write.
        ///
        /// The two are ONE migration and the review that caught this was right
        /// to call it a blocker: storing `port=285xx` in the plugin while
        /// `~/.ssh/config` still says `RemoteForward 8473` points every hook on
        /// that host at a port this Mac does not forward, and the result fails
        /// open — silently, which is the whole #215 failure class reintroduced
        /// by the fix for it.
        public var sshConfigSnippet: String?
        public var canRun: Bool { sshHostAlias != nil }

        /// Exact generated text retained as a test seam. Settings never renders
        /// or copies it; the user-facing command reference lives in the docs.
        public var applicationText: String {
            guard let sshConfigSnippet else { return commands.joined(separator: "\n") }
            return "# 1. Replace this host's block in ~/.ssh/config on this Mac:\n"
                + sshConfigSnippet
                + "\n\n# 2. Then, on the SSH host:\n"
                + commands.joined(separator: "\n")
        }
    }

    public enum EnrollmentAction: Sendable, Equatable {
        case insertSSHConfig
        case runRemoteSetup
        case setupHost
        /// Per-host, because the pane shows one row per host and the outcome
        /// has to render in the row whose button ran it.
        case updateRemotePlugin(hostID: String)
        case updateHost(hostID: String)
        case configureHerdrPanel(hostID: String)
    }

    public struct EnrollmentConfirmation: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var action: EnrollmentAction
        public var title: String
        public var preview: String
        public var confirmButtonTitle: String
    }

    public struct EnrollmentStepStatus: Identifiable, Equatable, Sendable {
        public var id: Int
        public var text: String
        public var succeeded: Bool
        public var detail: String
    }

    /// Long-form detail. Alerts and the log take this; the pane never renders it
    /// inline (owner rule).
    public struct DetailAlert: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var title: String
        public var detail: String
    }

    // MARK: - Observable state

    public private(set) var hosts: [HostRow] = []
    public private(set) var listenerStatus: ListenerStatus = .idle
    /// One short sentence when connections have been rejected since launch, nil
    /// otherwise. See `rejectionHint(for:)`.
    public private(set) var rejectionHint: String?
    /// Short result copy for the local plugin action, e.g. "Installed." Cleared
    /// when a new action starts.
    public private(set) var pluginResult: String?
    public private(set) var isPerformingPluginAction = false
    public private(set) var presentedPlan: EnrollmentPresentation?
    /// The update plan for the host whose automated setup panel is open.
    public private(set) var presentedPluginUpdate: PluginUpdatePresentation?
    public private(set) var enrollmentConfirmation: EnrollmentConfirmation?
    public private(set) var enrollmentStepStatuses: [EnrollmentStepStatus] = []
    /// Which action produced `enrollmentStepStatuses`. The sheet renders each
    /// outcome inside the section whose button the user actually clicked; a
    /// pooled results area below step 2 is how a step-1 success went unseen
    /// and got re-confirmed (field report 2026-07-26).
    public private(set) var enrollmentResultsAction: EnrollmentAction?
    public private(set) var isPerformingEnrollmentAction = false
    /// Step 3's verdicts. Empty until the user presses Check Setup — a check
    /// nobody asked for would spawn ssh on opening a sheet.
    public private(set) var verificationChecks: [ClaudeRemoteEnrollmentService.VerificationCheck] = []
    public private(set) var isPerformingVerification = false
    public private(set) var setupRun: RemoteHostSetupRun?
    public private(set) var setupManualInstructions: String?
    private var setupCancellationRequested = false
    private var setupSummaries: [String: String] = [:]
    public var alert: DetailAlert?

    /// One busy flag for the sheet, so no two actions can interleave: an
    /// insertion, a remote setup, a plugin update, and a check all drive the
    /// same seams and the same result rows.
    public var isEnrollmentBusy: Bool { isPerformingEnrollmentAction || isPerformingVerification }

    /// Whether THIS Mac currently holds the listener port.
    ///
    /// `.listening` and nothing else: `.portConflict` and `.failed` both mean
    /// the port is not ours, which is exactly the case a forwarded 401 must not
    /// pass. Read at two different moments by `runVerification`, so it is one
    /// property rather than two copies of the same expression.
    var listenerIsBound: Bool {
        guard let listener, listener.isListening else { return false }
        return listenerStatus == .listening(port: listener.boundPort)
    }

    /// What the cmux control socket last told us, as one short sentence in the
    /// pane. Written by the join resolver on every attempt, so a user who
    /// dictates and sees no cmux context can read WHY here instead of in the
    /// log. `.ok` renders nothing — a working feature says nothing.
    var cmuxStatus: CmuxSocketStatus = .ok

    /// Set by the join probe after a successful stamp whose value never
    /// appeared in the focused grid. This is inferential, not a config read.
    var herdrPanelStatus: HerdrPanelConfigurationStatus = .ok
    /// The plain-ssh join's setup step, refreshed with the rest of the pane.
    var shellSetupStatus = ClaudeShellSetupStatus()

    // MARK: - Integrations rows (Settings → Integrations)

    /// The local plugin's install state, refreshed with the rest of the pane
    /// and after every plugin action. Starts unknown: nothing has probed yet.
    public private(set) var localPluginStatus: ClaudePluginStatus = .unknown
    /// The status line's state, refreshed with the rest of the pane.
    public private(set) var statuslineStatus: ClaudeStatuslineInstallService.Status = .unknown
    /// Short outcome of the last statusline action, e.g. "Installed.".
    public private(set) var statuslineResult: String?
    public private(set) var isPerformingStatuslineAction = false
    /// The opencode plugin's state, refreshed with the rest of the pane.
    public private(set) var opencodeStatus: OpencodePluginInstallService.Status = .unknown
    /// Short outcome of the last opencode action, e.g. "Installed.".
    public private(set) var opencodeResult: String?
    public private(set) var isPerformingOpencodeAction = false
    /// Whether the herdr row is shown at all. Refreshed with the rest of the
    /// pane; hidden until something reports herdr.
    public private(set) var isHerdrDetected = false

    /// The herdr row's one status sentence. A constant: the row is
    /// status-only, and presence is the whole fact.
    public static let herdrDetectedSentence = "Found; panes join automatically."

    /// The password field's live text. Never seeded from the Keychain: the
    /// stored secret is not shown back to anyone, and an empty field on a
    /// machine that HAS a password must not read as "no password set" — which
    /// is what `hasCmuxPassword` is for.
    var cmuxPasswordField = ""

    /// Whether a password is stored, refreshed after every save. A Bool, never
    /// the value or its length.
    private(set) var hasCmuxPassword = false

    /// One short line under the cmux row: the socket's last word, or the setup
    /// state when it has not spoken yet.
    var cmuxStatusText: String {
        if let message = cmuxStatus.message { return message }
        return hasCmuxPassword ? "Password saved." : "No password saved."
    }

    /// Enrollment form. Free-form because the user is typing; validated on
    /// submit, not on every keystroke — a field that shouts while you are still
    /// typing the second character is hostile.
    public var enrollLabel = ""
    public var enrollSSHAlias = ""

    public var canEnroll: Bool {
        !ClaudeRemoteHostRegistry.sanitizeLabel(enrollLabel).isEmpty
            && ClaudeRemoteEnrollmentService.isValidHostAlias(enrollSSHAlias)
    }

    // MARK: - Dependencies

    private let registry: ClaudeRemoteHostRegistry?
    /// The user's login shell, or nil for one this app will not write for.
    /// Injected so no test spawns `dscl`.
    private let loginShell: @Sendable () -> ClaudeShellKind?
    /// Reads and writes the rc block for a shell. Nil disables the whole
    /// setup step — which is what a test that forgets to inject must get, so
    /// nothing can touch a real `~/.zshrc`.
    private let shellRCWriter: @Sendable (ClaudeShellKind) -> ClaudeShellRCWriter?
    /// Does any live remote session report a local tty? Nil means "no way to
    /// ask", which reports as no sessions rather than as a failure.
    private let liveLocalTTYReport: @Sendable () -> ClaudeShellSetupStatus.CrossingState
    /// stdout of `claude plugin list`, or nil when the listing is
    /// unavailable. Async because the listing shells out; injected so tests
    /// drive the status derivation from fixtures.
    private let fetchPluginListOutput: @Sendable () async -> String?
    /// This app's marketplace version, for the update comparison. Nil when
    /// the bundled manifest could not be read.
    private let bundledPluginVersion: String?
    /// Reads and writes the `statusLine` key. Nil disables the row's actions.
    private let statuslineService: @Sendable () -> ClaudeStatuslineInstallService?
    /// The hook command the statusline entry points at, e.g.
    /// `/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook
    /// --statusline`. Nil when the publisher binary cannot be located — the
    /// row then cannot offer Install.
    private let statuslineHookCommand: @Sendable () -> String?
    /// Copies the bundled opencode plugin and edits `tui.json`. Nil disables
    /// the row's actions.
    private let opencodeService: @Sendable () -> OpencodePluginInstallService?
    /// Whether a herdr binary is on this Mac's PATH. Synchronous and fast,
    /// so the row's visibility is reserved at construction instead of
    /// popping in after the first async refresh.
    private let herdrBinaryAvailable: @Sendable () -> Bool
    /// Whether any live session — local or remote — reports a herdr pane.
    /// Refreshed with the rest of the pane. Injected so tests pin row
    /// visibility without a herdr install.
    private let herdrPresenceReport: @Sendable () -> Bool
    private let listener: (any ClaudeRemoteListenerControlling)?
    private let pluginService: @Sendable () -> any ClaudePluginInstalling
    private let enrollmentService: ClaudeRemoteEnrollmentService
    /// Runs one plugin action and returns its failure, or nil.
    ///
    /// Off the main actor by default: `claude plugin install` fetches, and 60s
    /// of beachball is not a UI. Injected so tests run it synchronously — the
    /// production hop would make every assertion a race.
    private let performAsync:
        @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure?
    private let performEnrollmentAsync:
        @Sendable (@escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]) async
            -> ClaudeEnrollmentActionAttempt
    private let performVerificationAsync:
        @Sendable (@escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.VerificationCheck]) async
            -> ClaudeVerificationAttempt
    /// Injected wall clock, read once per refresh to age the host rows. No
    /// `Date()` in the view, and no timer: the rows are rebuilt when the pane
    /// appears and after every action that touches a host.
    private let now: @Sendable () -> Date
    /// This Mac's allocated port on the remote side of the tunnel
    /// (`ClaudeRemoteForwardPort`), passed in rather than read here so the pane
    /// has no opinion about where it comes from — and so a test can pin it.
    /// Every generated artifact that names a remote port takes it from this one
    /// value: the ssh block, the install command, the verify probe, the
    /// update/migration commands.
    private let remoteForwardPort: UInt16
    /// Keychain-backed cmux password storage. Nil in previews and in tests that
    /// do not exercise the cmux row — the row then reports that it cannot save,
    /// rather than silently pretending it did.
    private let cmuxPasswords: (any CmuxPasswordStoring)?
    /// Owns the app-held ssh forwards. Optional for the same reason `listener`
    /// is: previews and plugin-only tests have none, and the pane then simply
    /// does not offer the toggle.
    private let forwards: ClaudeRemoteForwardCoordinator?

    /// - Parameters:
    ///   - registry: nil when the host file could not be read at launch. The
    ///     pane then shows the remote surface as unavailable rather than
    ///     offering an Enroll button that cannot work.
    ///   - listener: nil in previews and in tests that only exercise the plugin
    ///     half.
    public init(
        registry: ClaudeRemoteHostRegistry?,
        listener: (any ClaudeRemoteListenerControlling)?,
        pluginService: @escaping @Sendable () -> any ClaudePluginInstalling,
        enrollmentService: ClaudeRemoteEnrollmentService = ClaudeRemoteEnrollmentService(),
        performAsync: @escaping @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure? = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            }.value
        },
        performEnrollmentAsync: @escaping @Sendable (
            @escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]
        ) async -> ClaudeEnrollmentActionAttempt = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }.value
        },
        performVerificationAsync: @escaping @Sendable (
            @escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.VerificationCheck]
        ) async -> ClaudeVerificationAttempt = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }.value
        },
        now: @escaping @Sendable () -> Date = { Date() },
        // Defaults to the legacy shared port: a caller that has not been taught
        // about per-Mac allocation describes exactly the pre-#215 setup, which
        // still works. Production passes the allocation.
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        cmuxPasswords: (any CmuxPasswordStoring)? = nil,
        forwards: ClaudeRemoteForwardCoordinator? = nil,
        loginShell: @escaping @Sendable () -> ClaudeShellKind? = { nil },
        shellRCWriter: @escaping @Sendable (ClaudeShellKind) -> ClaudeShellRCWriter? = { _ in nil },
        liveLocalTTYReport: @escaping @Sendable () -> ClaudeShellSetupStatus.CrossingState = {
            .noSessions
        },
        fetchPluginListOutput: @escaping @Sendable () async -> String? = { nil },
        bundledPluginVersion: String? = nil,
        statuslineService: @escaping @Sendable () -> ClaudeStatuslineInstallService? = { nil },
        statuslineHookCommand: @escaping @Sendable () -> String? = { nil },
        opencodeService: @escaping @Sendable () -> OpencodePluginInstallService? = { nil },
        herdrBinaryAvailable: @escaping @Sendable () -> Bool = { false },
        herdrPresenceReport: @escaping @Sendable () -> Bool = { false }
    ) {
        self.loginShell = loginShell
        self.shellRCWriter = shellRCWriter
        self.liveLocalTTYReport = liveLocalTTYReport
        self.fetchPluginListOutput = fetchPluginListOutput
        self.bundledPluginVersion = bundledPluginVersion
        self.statuslineService = statuslineService
        self.statuslineHookCommand = statuslineHookCommand
        self.opencodeService = opencodeService
        self.herdrBinaryAvailable = herdrBinaryAvailable
        self.herdrPresenceReport = herdrPresenceReport
        // m8: reserve the herdr row's visibility synchronously — the binary
        // check is a fast PATH scan, so herdr machines paint the row on
        // first paint instead of gaining it one beat late. The session half
        // still refreshes below.
        isHerdrDetected = herdrBinaryAvailable()
        self.registry = registry
        self.listener = listener
        self.pluginService = pluginService
        self.enrollmentService = enrollmentService
        self.performAsync = performAsync
        self.performEnrollmentAsync = performEnrollmentAsync
        self.performVerificationAsync = performVerificationAsync
        self.now = now
        self.remoteForwardPort = remoteForwardPort
        self.cmuxPasswords = cmuxPasswords
        self.forwards = forwards
        refreshHosts()
        refreshListenerStatus()
        // A presence check, not a read into any field: this is the one place
        // the stored secret is touched at construction, and only to answer
        // "is one set".
        hasCmuxPassword = cmuxPasswords?.password() != nil
        // The pane renders COPIES of the rows, so without this the tunnel
        // status is whatever it happened to be when Settings appeared: the
        // first "Connecting…" snapshot, frozen, while the real supervisor goes
        // on to forward, retry, or fail where nobody can see it. Every
        // transition now patches its row in place.
        forwards?.onStateChange = { [weak self] hostID in
            self?.applyForwardState(hostID: hostID)
        }
    }

    /// Patch one row's forward fields from the coordinator.
    ///
    /// Deliberately NOT `refreshHosts()`: that re-reads the registry file and
    /// re-derives every row's age text, which is a lot of work to do on a
    /// transition that changed one string — and it would move the "last seen"
    /// times under the user mid-read for a reason they never asked for.
    private func applyForwardState(hostID: String) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let state = forwards?.states[hostID]
        hosts[index].forwardStatusText = state?.text
        hosts[index].forwardIsFailure = state?.isFailure ?? false
    }

    // MARK: - cmux socket

    /// Saves (or clears) the cmux socket password and forgets the typed text.
    ///
    /// Clearing on save is deliberate: the field is an input, not a display,
    /// and a secret left sitting in a SwiftUI string is one screen-share away
    /// from being read out loud. An empty or rejected value REMOVES the stored
    /// password rather than leaving the previous one quietly in force.
    func saveCmuxPassword() {
        guard let cmuxPasswords else {
            alert = DetailAlert(
                title: "Could not save the cmux password",
                detail: "The keychain is unavailable in this build."
            )
            return
        }
        let accepted = CmuxPasswordValidation.normalized(cmuxPasswordField) != nil
        let stored = cmuxPasswords.setPassword(cmuxPasswordField)
        cmuxPasswordField = ""
        hasCmuxPassword = accepted && stored
        if !stored {
            alert = DetailAlert(
                title: "Could not save the cmux password",
                detail: "The keychain refused the item. See Console for the OSStatus."
            )
            return
        }
        // A stored password says nothing about whether cmux will accept it, so
        // the socket's verdict is reset rather than assumed good: the next
        // dictation writes the real answer.
        cmuxStatus = .ok
    }

    public var isRemoteAvailable: Bool { registry != nil }

    // MARK: - Local plugin

    public func installPlugin() async {
        await runPluginAction("Installed.") { try $0.installPlugin() }
    }

    public func updatePlugin() async {
        await runPluginAction("Updated.") { try $0.updatePlugin() }
    }

    public func uninstallPlugin() async {
        await runPluginAction("Removed.") { try $0.uninstallPlugin() }
    }

    private func runPluginAction(
        _ successCopy: String,
        _ body: @escaping @Sendable (any ClaudePluginInstalling) throws -> Void
    ) async {
        guard !isPerformingPluginAction else { return }
        isPerformingPluginAction = true
        pluginResult = nil
        defer { isPerformingPluginAction = false }

        let service = pluginService()
        guard let failure = await performAsync({ try body(service) }) else {
            pluginResult = successCopy
            await refreshLocalPluginStatus()
            return
        }
        // Short line in the pane; the CLI's actual output — which can be pages of
        // it — goes to the alert and the log only.
        pluginResult = Self.shortPluginFailure(failure)
        alert = DetailAlert(
            title: "Claude Code plugin",
            detail: Self.pluginFailureDetail(failure)
        )
        Log.claudeContext.error(
            "Claude plugin action failed: \(failure.describedError, privacy: .public)"
        )
        await refreshLocalPluginStatus()
    }

    /// Re-probe `claude plugin list` after an action (or with the pane's
    /// refresh) so the row's sentence describes the new state.
    public func refreshLocalPluginStatus() async {
        let output = await fetchPluginListOutput()
        localPluginStatus = ClaudePluginStatus.derive(
            listOutput: output, bundledVersion: bundledPluginVersion
        )
    }

    /// One short sentence, never the CLI's output.
    static func shortPluginFailure(_ failure: ClaudePluginActionFailure) -> String {
        switch failure.serviceError {
        case .claudeCLINotFound: return "Claude Code CLI not found."
        case .marketplaceUnavailable: return "Plugin files missing from the app."
        case .commandTimedOut: return "Claude Code did not respond."
        case .outputTooLarge: return "Claude Code produced too much output."
        case .commandFailed, .none: return "Claude Code reported an error."
        }
    }

    static func pluginFailureDetail(_ failure: ClaudePluginActionFailure) -> String {
        switch failure.serviceError {
        case .claudeCLINotFound:
            return "localvoxtral could not find the `claude` command. Install Claude Code, or make sure "
                + "`claude` is on the PATH that GUI apps see."
        case .marketplaceUnavailable:
            return "The bundled plugin files are missing from this build of localvoxtral. Reinstall the app."
        case .commandTimedOut(_, _, let seconds):
            return "`claude plugin` did not finish within \(Int(seconds))s and was stopped."
        case .outputTooLarge(_, let capBytes):
            return "`claude plugin` produced more than \(capBytes / 1024) KB of output and was stopped."
        case .commandFailed(_, let exitCode, let message):
            return "`claude plugin` exited with code \(exitCode).\n\n\(message)"
        case .none:
            return failure.describedError
        }
    }

    // MARK: - Remote hosts

    public func refreshHosts() {
        // One clock reading for the whole list, so two rows of the same age
        // cannot disagree about what "now" was.
        let timestamp = now()
        hosts = (registry?.hosts() ?? []).map { host in
            let forwardState = forwards?.states[host.id]
            return HostRow(
                id: host.id,
                label: host.label,
                sshHostAlias: host.sshHostAlias,
                isRevoked: host.isRevoked,
                lastSeenAt: host.lastSeenAt,
                statusText: Self.hostStatusText(
                    isRevoked: host.isRevoked, lastSeenAt: host.lastSeenAt, now: timestamp
                ),
                persistentForwardEnabled: host.persistentForwardEnabled,
                // Nil when this host has no forward running, which is not the
                // same as a forward that is off: a row with the toggle off has
                // nothing to report, and a status line saying so would be noise
                // in a list of hosts.
                forwardStatusText: forwardState?.text,
                forwardIsFailure: forwardState?.isFailure ?? false,
                canHoldForward: forwards != nil
                    && !host.isRevoked
                    && host.sshHostAlias.map(ClaudeRemoteEnrollmentService.isValidHostAlias) == true,
                setupStatusText: setupSummaries[host.id]
            )
        }
        refreshRejectionHint()
    }

    /// Re-read the listener's rejection counters.
    ///
    /// Deliberately part of `refreshHosts` rather than a timer of its own: that
    /// is what the pane already calls on appear and after every host action, and
    /// a background timer redrawing Settings is a cost with no reader.
    public func refreshRejectionHint() {
        guard let listener else {
            rejectionHint = nil
            return
        }
        rejectionHint = Self.rejectionHint(for: listener.rejectionSnapshot)
    }

    /// One sentence naming the likely cause, or nil when nothing was rejected.
    ///
    /// Short by owner rule — a Settings row has the same "no long text" problem
    /// the popover does — and count-free on purpose: the number of rejections is
    /// noise (a busy session produces one every few minutes), while WHICH KIND
    /// they were is the whole diagnosis. The detail stays in the log.
    ///
    /// The hedge in "a host MAY have" is deliberate. An enrolled host is not the
    /// only thing that can reach a loopback port, and a rejection carries no
    /// identity — only a shape.
    ///
    /// What the hedge no longer has to cover is the anonymous caller. A probe or
    /// a `curl` with no `Authorization` header used to land in the same category
    /// as a pre-1.1.0 plugin, so checking your own setup raised a hint accusing
    /// a healthy host; those are now `.absentAuthorization`, which
    /// `Snapshot.isEmpty` excludes and this sentence therefore never describes.
    static func rejectionHint(for snapshot: ClaudeRemoteRejectionTally.Snapshot) -> String? {
        guard !snapshot.isEmpty else { return nil }
        let cause: String
        switch (snapshot.emptyCredential > 0, snapshot.unknownToken > 0) {
        case (true, true):
            cause = "an outdated plugin or a stale token"
        case (true, false):
            return "Rejected connections suggest an outdated plugin; use Update host."
        case (false, true):
            return "Rejected connections suggest a stale token; rotate it and rerun setup."
        case (false, false):
            cause = "a malformed authorization header"
        }
        return "Rejected connections suggest \(cause)."
    }

    public func refreshListenerStatus() {
        guard let listener else { return }
        if listener.isListening {
            listenerStatus = .listening(port: listener.boundPort)
        } else if listenerStatus.isFailure {
            // Preserve a failure we already diagnosed: "not listening" is the
            // symptom, and overwriting the cause with it is how a port conflict
            // turns into a shrug.
            return
        } else {
            listenerStatus = .idle
        }
    }

    /// Enroll, then bind — in that order, and both before returning.
    ///
    /// The listener starts here rather than at next launch. "Enroll a host, then
    /// quit and reopen the app" is not a setup step anyone would guess, and the
    /// failure it produces is silent: the tunnel connects to a closed port, the
    /// hook fails open, and the user concludes the feature does not work.
    public func enroll() async {
        guard let registry else { return }
        let label = enrollLabel
        let alias = enrollSSHAlias
        guard ClaudeRemoteEnrollmentService.isValidHostAlias(alias) else {
            alert = DetailAlert(
                title: "Invalid SSH host",
                detail: "\"\(alias)\" is not an SSH host alias. Use the name from your ~/.ssh/config. "
                    + "letters, digits, dots, dashes and underscores only."
            )
            return
        }
        do {
            let enrollment = try registry.enroll(label: label, sshHostAlias: alias)
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                sshHostAlias: alias,
                token: enrollment.token,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
            // A fresh sheet must not inherit a previous host's step results —
            // a still-running earlier action can repopulate the statuses after
            // dismissPlan() cleared them.
            enrollmentConfirmation = nil
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
            verificationChecks = []
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias,
                plan: plan,
                isRotation: false,
                remoteForwardPort: remoteForwardPort
            )
            enrollLabel = ""
            enrollSSHAlias = ""
            refreshHosts()
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "enroll")
        }
    }

    /// Issue a new token for an existing host and show it once.
    public func rotate(hostID: String) async {
        guard let registry else { return }
        do {
            let enrollment = try registry.rotateToken(hostID: hostID)
            // The alias the user enrolled with, or nothing. The label is NOT a
            // fallback: name and alias are separate fields, so `prod` named
            // over alias `builder` would have sent the new token to whatever
            // answers to `prod` (review finding, PR #197). A host enrolled
            // before the alias was persisted gets the placeholder and cannot
            // run setup until it is re-enrolled with an explicit alias.
            let alias = enrollment.host.sshHostAlias
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                token: enrollment.token,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
            enrollmentConfirmation = nil
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
            verificationChecks = []
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                plan: plan,
                isRotation: true,
                canRunRemoteSetup: alias != nil,
                remoteForwardPort: remoteForwardPort
            )
            refreshHosts()
            // Rotation reinstates a revoked host, so it can be a 0→1 transition.
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "rotate the token for")
        }
    }

    /// Turn the app-held forward on or off for one host.
    ///
    /// Order matters and is the same as everywhere else in this feature: the
    /// registry is the source of truth, so it is written FIRST and the
    /// coordinator reconciles against what was actually persisted. A coordinator
    /// started before the write could be left running a forward for a flag that
    /// never made it to disk.
    public func setPersistentForward(_ enabled: Bool, hostID: String) {
        guard let registry else { return }
        do {
            try registry.setPersistentForwardEnabled(enabled, hostID: hostID)
            forwards?.reconcile()
            refreshHosts()
        } catch {
            presentRegistryFailure(error, verb: enabled ? "enable the tunnel for" : "disable the tunnel for")
        }
    }

    /// Retry one host's failed forward — the move after freeing the port.
    public func retryPersistentForward(hostID: String) {
        forwards?.retry(hostID: hostID)
        refreshHosts()
    }

    public func revoke(hostID: String) async {
        guard let registry else { return }
        do {
            try registry.revoke(hostID: hostID)
            refreshHosts()
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "revoke")
        }
    }

    /// Remove reverses the Mac side of enrollment — this host's ssh-config
    /// block, and the shell startup block only when no other host remains —
    /// and then revokes.
    ///
    /// Reversal NEVER blocks the revocation: the registry entry is the off
    /// switch, and a host whose block could not be edited (a symlinked
    /// `~/.ssh/config`, an unwritable rc) is exactly a host the user must be
    /// able to turn off. A failed reversal is reported in the alert with the
    /// manual cleanup instead; the remote uninstall commands ride along, as
    /// the sheet and docs always offered them.
    public func remove(hostID: String) async {
        guard let registry else { return }
        let isLastHost = registry.hosts().allSatisfy { $0.id == hostID }
        var manualNotes: [String] = []

        if enrollmentService.canEditSSHConfig {
            let service = enrollmentService
            let attempt = await performEnrollmentAsync {
                try service.removeSSHConfig(hostID: hostID)
                return []
            }
            if let failure = attempt.failure {
                Log.claudeContext.error(
                    "Claude remote host removal could not rewrite ~/.ssh/config: \(failure.describedError, privacy: .public)"
                )
                manualNotes.append(
                    "This host's block is still in ~/.ssh/config.\n\n"
                        + Self.enrollmentFailureDetail(failure, action: .insertSSHConfig)
                )
            }
        }

        if isLastHost, let shell = loginShell(), let writer = shellRCWriter(shell) {
            if let failure = await performAsync({ try writer.remove() }) {
                Log.claudeContext.error(
                    "Claude remote host removal could not rewrite the shell startup file: \(failure.describedError, privacy: .public)"
                )
                manualNotes.append(
                    "The LC_LVX_TTY block is still in your shell startup file.\n\n"
                        + failure.describedError
                )
            }
        }

        do {
            try registry.remove(hostID: hostID)
            // The row is going away; its open update panel must not outlive it.
            if presentedPluginUpdate?.hostID == hostID { dismissPluginUpdate() }
            refreshHosts()
            reconcileListener()
            if !manualNotes.isEmpty {
                alert = DetailAlert(
                    title: "Remote host removed",
                    detail: (manualNotes + ["Remove those blocks by hand to finish the cleanup."])
                        .joined(separator: "\n\n")
                )
            }
        } catch {
            presentRegistryFailure(error, verb: "remove")
        }
    }

    /// Retry a failed bind. The user's move after freeing the port.
    public func retryListener() {
        listenerStatus = .idle
        reconcileListener()
    }

    /// Reconcile during app launch without queueing a modal alert for a window
    /// that does not exist yet. The status row and log still retain the exact
    /// failure; opening Settings later shows the remedy and Retry in context.
    public func synchronizeListenerAtLaunch() {
        reconcileListener(presentAlert: false)
    }

    public func dismissPlan() {
        // The plaintext goes with it. Nothing else holds a copy.
        presentedPlan = nil
        enrollmentConfirmation = nil
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        setupRun = nil
        setupManualInstructions = nil
    }

    // MARK: - Shell setup for the plain-ssh join

    /// Re-read both halves. Cheap: one `lstat`+read of one rc file, and one
    /// registry query. Called with the rest of the pane's refresh.
    public func refreshShellSetupStatus() {
        guard let shell = loginShell() else {
            shellSetupStatus = ClaudeShellSetupStatus(
                rc: .unsupportedShell, crossing: liveLocalTTYReport()
            )
            return
        }
        let writer = shellRCWriter(shell)
        let rc: ClaudeShellSetupStatus.RCState
        switch writer?.isApplied() {
        case .some(true): rc = .applied
        case .some(false): rc = .notApplied
        case .none: rc = .unknown
        }
        shellSetupStatus = ClaudeShellSetupStatus(
            rc: rc,
            crossing: liveLocalTTYReport(),
            relativeRCPath: ClaudeShellRCSetup.relativeRCPath(for: shell) { relative in
                FileManager.default.fileExists(
                    atPath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(relative).path
                )
            }
        )
    }

    /// Generated shell text retained for the writer and its test seam.
    public var shellSetupPreview: String? {
        guard let shell = loginShell() else { return nil }
        return ClaudeShellRCSetup.snippet(for: shell)
    }

    public var canApplyShellSetup: Bool { loginShell() != nil }

    public var shellSetupConsentSentence: String {
        "localvoxtral will edit \(shellRCPathForConsent()) on this Mac."
    }

    public func hostSetupConsentSentence(sshHostAlias: String) -> String {
        "localvoxtral will edit ~/.ssh/config and \(shellRCPathForConsent()) on this Mac "
            + "and install its plugin on \(sshHostAlias)."
    }

    /// Write the block. Consent is the CALLER's to obtain, immediately before.
    public func applyShellSetup() async {
        guard let shell = loginShell(), let writer = shellRCWriter(shell) else { return }
        await performShellRCEdit { try writer.apply(shell: shell) }
    }

    public func removeShellSetup() async {
        guard let shell = loginShell(), let writer = shellRCWriter(shell) else { return }
        await performShellRCEdit { try writer.remove() }
    }

    private func performShellRCEdit(_ body: @escaping @Sendable () throws -> Void) async {
        let failure = await performAsync { try body() }
        if let failure {
            // The pane shows one short line; the detail belongs in the alert
            // (owner rule), and this is the one place the symlink refusal
            // becomes visible to a dotfiles user.
            alert = DetailAlert(
                title: "Could not update your shell startup file",
                detail: failure.describedError
            )
        }
        refreshShellSetupStatus()
    }

    // MARK: - Integrations rows

    /// Re-read every Integrations row that comes from disk or a probe. Called
    /// with the rest of the pane's refresh and after every row action.
    public func refreshIntegrationsStatuses() async {
        let output = await fetchPluginListOutput()
        localPluginStatus = ClaudePluginStatus.derive(
            listOutput: output, bundledVersion: bundledPluginVersion
        )
        refreshStatuslineStatus()
        refreshOpencodeStatus()
        isHerdrDetected = herdrBinaryAvailable() || herdrPresenceReport()
    }

    // MARK: Local plugin status

    /// The plugin row's one status sentence.
    public var localPluginSentence: String { localPluginStatus.sentence }

    // MARK: Status line

    /// The row's one status sentence.
    public var statuslineSentence: String {
        ClaudeStatuslineInstallService.sentence(for: statuslineStatus)
    }

    public func refreshStatuslineStatus() {
        guard let service = statuslineService() else {
            statuslineStatus = .unknown
            return
        }
        statuslineStatus = service.status()
    }

    /// Exact generated JSON retained for service tests. Settings never renders
    /// it.
    public var statuslinePreview: String? {
        guard let hookCommand = statuslineHookCommand() else { return nil }
        return ClaudeStatuslineInstallService.preview(hookCommand: hookCommand)
    }

    public var canApplyStatuslineSetup: Bool { statuslineHookCommand() != nil }

    public func applyStatuslineSetup() async {
        guard
            let service = statuslineService(),
            let hookCommand = statuslineHookCommand(),
            !isPerformingStatuslineAction
        else { return }
        isPerformingStatuslineAction = true
        statuslineResult = nil
        defer { isPerformingStatuslineAction = false }
        let failure = await performAsync { try service.apply(hookCommand: hookCommand) }
        if let failure {
            alert = DetailAlert(
                title: "Could not install the status line",
                detail: failure.describedError
            )
            statuslineResult = "Could not install."
        } else {
            statuslineResult = "Installed."
        }
        refreshStatuslineStatus()
        // M3: an edited formerly-ours entry refuses with its own sentence —
        // the generic failure line would hide what to do next.
        if failure != nil, statuslineStatus == .edited {
            statuslineResult = ClaudeStatuslineInstallService.sentence(for: .edited)
        }
    }

    public func removeStatusline() async {
        guard let service = statuslineService(), !isPerformingStatuslineAction else { return }
        isPerformingStatuslineAction = true
        statuslineResult = nil
        defer { isPerformingStatuslineAction = false }
        let failure = await performAsync { try service.remove() }
        if let failure {
            alert = DetailAlert(
                title: "Could not remove the status line",
                detail: failure.describedError
            )
            statuslineResult = "Could not remove."
        } else {
            statuslineResult = "Removed."
        }
        refreshStatuslineStatus()
        if failure != nil, statuslineStatus == .edited {
            statuslineResult = ClaudeStatuslineInstallService.sentence(for: .edited)
        }
    }

    // MARK: opencode plugin

    /// The row's one status sentence.
    public var opencodeSentence: String {
        OpencodePluginInstallService.sentence(for: opencodeStatus)
    }

    public func refreshOpencodeStatus() {
        guard let service = opencodeService() else {
            opencodeStatus = .unknown
            return
        }
        opencodeStatus = service.status()
    }

    public func installOpencodePlugin() async {
        guard let service = opencodeService(), !isPerformingOpencodeAction else { return }
        isPerformingOpencodeAction = true
        opencodeResult = nil
        defer { isPerformingOpencodeAction = false }
        let failure = await performAsync { try service.install() }
        if let failure {
            alert = DetailAlert(
                title: "Could not install the opencode plugin",
                detail: failure.describedError
            )
            opencodeResult = "Could not install."
        } else {
            opencodeResult = "Installed."
        }
        refreshOpencodeStatus()
    }

    public func removeOpencodePlugin() async {
        guard let service = opencodeService(), !isPerformingOpencodeAction else { return }
        isPerformingOpencodeAction = true
        opencodeResult = nil
        defer { isPerformingOpencodeAction = false }
        let failure = await performAsync { try service.remove() }
        if let failure {
            alert = DetailAlert(
                title: "Could not remove the opencode plugin",
                detail: failure.describedError
            )
            opencodeResult = "Could not remove."
        } else {
            opencodeResult = "Removed."
        }
        refreshOpencodeStatus()
    }

    public func requestPluginUpdate(hostID: String) {
        guard !isEnrollmentBusy,
              let host = hosts.first(where: { $0.id == hostID })
        else { return }
        // The ENROLLED alias, never the label: a host named `prod` may be
        // reached over alias `builder`, and `ssh prod …` would then update
        // whatever machine answers to that name (review finding, PR #197).
        // Hosts enrolled before the alias was persisted have none and must be
        // re-enrolled rather than targeting a guessed host.
        let alias = host.sshHostAlias.flatMap {
            ClaudeRemoteEnrollmentService.isValidHostAlias($0) ? $0 : nil
        }
        // A fresh panel must not inherit another action's results, for the same
        // reason a fresh enrollment sheet must not (field report 2026-07-26).
        enrollmentConfirmation = nil
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        // Regenerate the block unless it is already current. `nil` from the
        // service means "cannot tell", and cannot-tell must regenerate: the
        // cost of a redundant idempotent rewrite is nothing, and the cost of
        // assuming a stale block is current is a silently dead host.
        let alreadyCurrent =
            registry?.host(id: hostID).flatMap { host in
                enrollmentService.sshConfigBlockIsCurrent(port: remoteForwardPort, hostID: host.id)
            } ?? false
        let snippet: String? = alreadyCurrent ? nil : registry?.host(id: hostID).map { host in
            ClaudeRemoteEnrollmentService.sshConfigSnippet(
                host: host,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
        }
        presentedPluginUpdate = PluginUpdatePresentation(
            hostID: hostID,
            sshHostAlias: alias,
            commands: ClaudeRemoteEnrollmentService.updateCommands(
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                remoteForwardPort: remoteForwardPort
            ),
            sshConfigSnippet: snippet
        )
    }

    /// Exactly what `performPluginUpdate` will do, retained as a test seam.
    static func updatePreview(for presentation: PluginUpdatePresentation) -> String {
        presentation.applicationText
    }

    /// Stands in for an alias we were never told. It is not a valid target and
    /// exists only for deterministic plans used by documentation and tests.
    static let unknownAliasPlaceholder = "your-ssh-host"

    public func dismissPluginUpdate() {
        switch enrollmentResultsAction {
        case .updateRemotePlugin?, .updateHost?:
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
        default:
            break
        }
        switch enrollmentConfirmation?.action {
        case .updateRemotePlugin?, .updateHost?:
            enrollmentConfirmation = nil
        default:
            break
        }
        setupRun = nil
        setupManualInstructions = nil
        presentedPluginUpdate = nil
    }

    /// Ask before running the legacy plugin-only update path.
    public func requestPluginUpdateRun() {
        guard let presentation = presentedPluginUpdate,
              presentation.canRun,
              !isEnrollmentBusy
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .updateRemotePlugin(hostID: presentation.hostID),
            title: presentation.sshConfigSnippet == nil
                ? "Update the plugin on this SSH host?"
                : "Update ~/.ssh/config on this Mac and the plugin on this SSH host?",
            preview: Self.updatePreview(for: presentation),
            confirmButtonTitle: "Confirm update"
        )
        Log.claudeContext.info("Claude remote plugin update confirmation requested")
    }

    public func requestHostUpdateRun() {
        guard let presentation = presentedPluginUpdate,
              presentation.canRun,
              !isEnrollmentBusy
        else { return }
        setupRun = nil
        setupManualInstructions = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .updateHost(hostID: presentation.hostID),
            title: hostSetupConsentSentence(
                sshHostAlias: presentation.sshHostAlias ?? Self.unknownAliasPlaceholder
            ),
            preview: setupPreview(
                sshConfigSnippet: presentation.sshConfigSnippet,
                remoteCommands: presentation.commands
            ),
            confirmButtonTitle: "Update Host"
        )
        Log.claudeContext.info("Claude remote host update confirmation requested")
    }

    public func requestSSHConfigInsertion() {
        guard let presentation = presentedPlan, !isEnrollmentBusy, !presentation.isPreview else { return }
        enrollmentStepStatuses = []
        // The verdicts described the setup BEFORE this change. Leaving them up
        // beside a fresh result reads as if they described the state after it
        // (review finding, round 3).
        verificationChecks = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .insertSSHConfig,
            title: "Insert this exact block into ~/.ssh/config?",
            preview: presentation.plan.sshConfigSnippet,
            confirmButtonTitle: "Confirm insert"
        )
        Log.claudeContext.info("Claude remote ssh config confirmation requested")
    }

    public func requestRemoteSetup() {
        guard let presentation = presentedPlan,
              // A placeholder alias must not reach ssh: automation would hand
              // the new token to whatever answers to a name we invented.
              presentation.canRunRemoteSetup,
              !isEnrollmentBusy,
              !presentation.isPreview
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .runRemoteSetup,
            title: "Run these commands on the SSH host?",
            preview: Self.redactedRemoteCommands(for: presentation),
            confirmButtonTitle: "Confirm run"
        )
        Log.claudeContext.info("Claude remote setup confirmation requested")
    }

    public func requestHostSetup() {
        guard let presentation = presentedPlan,
              presentation.canRunRemoteSetup,
              !isEnrollmentBusy,
              !presentation.isPreview
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        setupRun = nil
        setupManualInstructions = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .setupHost,
            title: hostSetupConsentSentence(sshHostAlias: presentation.sshHostAlias),
            preview: setupPreview(
                sshConfigSnippet: presentation.plan.sshConfigSnippet,
                remoteCommands: presentation.plan.remoteCommands
            ),
            confirmButtonTitle: "Run Setup"
        )
        Log.claudeContext.info("Claude remote host setup confirmation requested")
    }

    public func requestHerdrPanelConfiguration(hostID: String) {
        guard !isPerformingEnrollmentAction,
              let host = hosts.first(where: { $0.id == hostID }),
              host.sshHostAlias != nil
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .configureHerdrPanel(hostID: hostID),
            title: "Configure this exact herdr agents-panel row?",
            preview: ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet,
            confirmButtonTitle: "Confirm configuration"
        )
        Log.claudeContext.info("Claude remote herdr panel configuration confirmation requested")
    }

    public func cancelEnrollmentActionConfirmation() {
        enrollmentConfirmation = nil
    }

    public func confirmEnrollmentAction() async {
        guard let confirmation = enrollmentConfirmation, !isEnrollmentBusy else { return }
        switch confirmation.action {
        case .insertSSHConfig, .runRemoteSetup:
            await performPlanAction(confirmation)
        case .updateRemotePlugin:
            await performPluginUpdate(confirmation)
        case .setupHost, .updateHost:
            await performSetupRun(confirmation)
        case .configureHerdrPanel:
            await performHerdrPanelConfiguration(confirmation)
        }
    }

    public func cancelSetupRun() {
        guard setupRun != nil, isPerformingEnrollmentAction else { return }
        setupCancellationRequested = true
    }

    private func setupPreview(
        sshConfigSnippet: String?,
        remoteCommands: [String]
    ) -> String {
        var sections: [String] = []
        if let sshConfigSnippet {
            sections.append("Mac ~/.ssh/config:\n\(sshConfigSnippet)")
        }
        if let shellSetupPreview {
            sections.append("Mac shell startup file:\n\(shellSetupPreview)")
        }
        sections.append("Remote host:\n" + remoteCommands.joined(separator: "\n"))
        sections.append(
            "Remote herdr, when installed:\n"
                + ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet
                + "\nherdr server reload-config"
        )
        return sections.joined(separator: "\n\n")
    }

    private func shellRCPathForConsent() -> String {
        guard let shell = loginShell() else { return "your shell startup file" }
        let relative = ClaudeShellRCSetup.relativeRCPath(for: shell) { relative in
            FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(relative).path
            )
        }
        return "~/\(relative)"
    }

    private func performPlanAction(_ confirmation: EnrollmentConfirmation) async {
        // Belt and braces: a preview sheet cannot raise a confirmation in the
        // first place, and if one somehow existed it would run against a host
        // the registry has never heard of.
        guard let presentation = presentedPlan, !presentation.isPreview else { return }
        let service = enrollmentService
        let work: @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]
        switch confirmation.action {
        case .insertSSHConfig:
            work = {
                try service.insertSSHConfig(presentation.plan, hostID: presentation.host.id)
                return []
            }
        case .runRemoteSetup:
            work = {
                try service.executeRemoteSetup(
                    presentation.plan,
                    sshHostAlias: presentation.sshHostAlias,
                    token: presentation.token
                )
            }
        case .updateRemotePlugin, .setupHost, .updateHost:
            // Routed to performPluginUpdate: that action belongs to a host row,
            // has no plan and no token, and must not run against one.
            return
        case .configureHerdrPanel:
            return
        }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let attempt = await performEnrollmentAsync(work)

        // The sheet may have been dismissed (window close) and even replaced
        // while the detached work ran; a late result must not surface under a
        // different sheet. The whole presentation must match, not just the
        // host id — rotation REUSES the host id, and an id-only guard let an
        // old-token outcome render beneath the new token's commands. Rotation
        // mints a fresh token, so value equality distinguishes generations.
        guard presentedPlan == presentation else { return }

        publish(attempt, action: confirmation.action)
    }

    private func performHerdrPanelConfiguration(_ confirmation: EnrollmentConfirmation) async {
        guard case .configureHerdrPanel(let hostID) = confirmation.action,
              let host = hosts.first(where: { $0.id == hostID }),
              let alias = host.sshHostAlias
        else { return }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let attempt = await performEnrollmentAsync {
            try service.configureRemoteHerdrPanel(sshHostAlias: alias)
        }
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        publish(attempt, action: confirmation.action)
        if attempt.failure == nil { herdrPanelStatus = .ok }
    }

    private func performSetupRun(_ confirmation: EnrollmentConfirmation) async {
        let hostID: String
        let alias: String
        let snippet: String?
        let token: String?
        switch confirmation.action {
        case .setupHost:
            guard let presentation = presentedPlan, !presentation.isPreview else { return }
            hostID = presentation.host.id
            alias = presentation.sshHostAlias
            snippet = presentation.plan.sshConfigSnippet
            token = presentation.token
        case .updateHost(let requestedHostID):
            guard let presentation = presentedPluginUpdate,
                  presentation.hostID == requestedHostID,
                  let presentationAlias = presentation.sshHostAlias
            else { return }
            hostID = requestedHostID
            alias = presentationAlias
            snippet = presentation.sshConfigSnippet
            token = nil
        default:
            return
        }

        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        setupCancellationRequested = false
        setupManualInstructions = nil
        setupRun = RemoteHostSetupRun(hostID: hostID, startedAt: now())
        setupSummaries[hostID] = "Setup is running."
        refreshHosts()
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let port = remoteForwardPort
        let snippetToApply = service.sshConfigBlockIsCurrent(port: port, hostID: hostID) == true
            ? nil
            : snippet

        markSetup(.sshConfig, .running)
        let sshAttempt = await performEnrollmentAsync {
            if let snippetToApply {
                try service.insertSSHConfig(snippet: snippetToApply, hostID: hostID)
            }
            return []
        }
        if let failure = sshAttempt.failure {
            failSetup(
                .sshConfig,
                reason: "Could not update this Mac's SSH config.",
                remedy: Self.enrollmentFailureDetail(failure, action: confirmation.action)
            )
            return
        }
        markSetup(
            .sshConfig,
            .done(
                snippetToApply == nil
                    ? "The SSH config block is already current."
                    : "The SSH config block is current."
            )
        )
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.shellStartup, .running)
        if let shell = loginShell(), let writer = shellRCWriter(shell) {
            if writer.isApplied() == true {
                markSetup(.shellStartup, .done("The shell startup block is already applied."))
            } else {
                let shellFailure = await performAsync { try writer.apply(shell: shell) }
                if let shellFailure {
                    setupManualInstructions = "Open Details for manual shell setup."
                    markSetup(
                        .shellStartup,
                        .skipped("The shell startup file was left unchanged; see Details.")
                    )
                    Log.claudeContext.error(
                        "Claude remote setup skipped shell startup edit: \(shellFailure.describedError, privacy: .public)"
                    )
                } else {
                    markSetup(.shellStartup, .done("The shell startup block is applied."))
                }
            }
        } else {
            setupManualInstructions = "Open Details for manual shell setup."
            markSetup(
                .shellStartup,
                .skipped("This login shell is not supported for automatic setup; configure it manually.")
            )
        }
        refreshShellSetupStatus()
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.remotePlugin, .running)
        let pluginAttempt = await performEnrollmentAsync {
            let outcome = try service.setupRemotePlugin(
                sshHostAlias: alias, token: token, remoteForwardPort: port
            )
            return [.init(index: 0, command: "remote plugin", message: String(describing: outcome))]
        }
        if let failure = pluginAttempt.failure {
            failSetup(
                .remotePlugin,
                reason: "The remote plugin could not be installed or updated.",
                remedy: Self.enrollmentFailureDetail(failure, action: confirmation.action)
            )
            return
        }
        switch pluginAttempt.steps.first?.message {
        case "installed": markSetup(.remotePlugin, .done("The remote plugin was installed and verified."))
        case "updated": markSetup(.remotePlugin, .done("The remote plugin was updated and verified."))
        default: markSetup(.remotePlugin, .done("The remote plugin is already current and verified."))
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.environmentCrossing, .running)
        let environmentAttempt = await performEnrollmentAsync {
            let outcome = try service.probeRemoteEnvironment(sshHostAlias: alias)
            return [.init(index: 0, command: "environment probe", message: String(describing: outcome))]
        }
        if let failure = environmentAttempt.failure {
            failSetup(
                .environmentCrossing,
                reason: "The terminal environment check could not run.",
                remedy: Self.enrollmentFailureDetail(failure, action: confirmation.action)
            )
            return
        }
        switch environmentAttempt.steps.first?.message {
        case "crossed":
            markSetup(.environmentCrossing, .done("LC_LVX_TTY crossed the SSH connection."))
        case "localSendEnvMissing":
            failSetup(
                .environmentCrossing,
                reason: "This Mac is not sending LC_LVX_TTY for this SSH host.",
                remedy: "Open Details and follow the SSH environment setup."
            )
            return
        default:
            failSetup(
                .environmentCrossing,
                reason: "The remote SSH server did not accept LC_LVX_TTY.",
                remedy: "Open Details and follow the remote SSH server setup."
            )
            return
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.remoteHerdr, .running)
        let herdrAttempt = await performEnrollmentAsync {
            let outcome = try service.setupRemoteHerdr(sshHostAlias: alias)
            return [.init(index: 0, command: "remote herdr", message: String(describing: outcome))]
        }
        if let failure = herdrAttempt.failure {
            failSetup(
                .remoteHerdr,
                reason: "Remote herdr setup failed.",
                remedy: Self.enrollmentFailureDetail(failure, action: .configureHerdrPanel(hostID: hostID))
            )
            return
        }
        switch herdrAttempt.steps.first?.message {
        case "notFound":
            markSetup(.remoteHerdr, .skipped("herdr is not installed on the remote host."))
        case "customized":
            setupManualInstructions = "The remote herdr table is customized; open Details to update it manually."
            markSetup(.remoteHerdr, .skipped("The existing herdr agents table was left unchanged."))
        default:
            markSetup(.remoteHerdr, .done("The remote herdr agents panel is configured."))
            herdrPanelStatus = .ok
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.checkSetup, .running)
        let listenerWasBound = listenerIsBound
        let checkAttempt = await performVerificationAsync {
            try service.executeVerification(
                sshHostAlias: alias,
                remoteForwardPort: port,
                listenerIsBound: listenerWasBound
            )
        }
        if let failure = checkAttempt.failure {
            failSetup(
                .checkSetup,
                reason: "The final setup check could not run.",
                remedy: Self.verificationFailureDetail(failure)
            )
            return
        }
        verificationChecks = ClaudeRemoteEnrollmentService.reconciled(
            checkAttempt.checks,
            remoteForwardPort: port,
            listenerIsBound: listenerIsBound
        )
        if let failed = verificationChecks.first(where: { !$0.passed }) {
            failSetup(
                .checkSetup,
                reason: failed.summary,
                remedy: failed.hint ?? failed.detail
            )
            return
        }
        markSetup(.checkSetup, .done("The tunnel and remote plugin checks passed."))
        setupSummaries[hostID] = "Setup complete."
        refreshHosts()
        Log.claudeContext.info("Claude remote host setup completed")
    }

    private func markSetup(_ step: RemoteHostSetupRun.Step, _ state: RemoteHostSetupRun.State) {
        guard let index = setupRun?.items.firstIndex(where: { $0.step == step }) else { return }
        setupRun?.items[index].state = state
    }

    private func failSetup(
        _ step: RemoteHostSetupRun.Step,
        reason: String,
        remedy: String
    ) {
        markSetup(step, .failed(reason: reason, remedy: remedy))
        if let hostID = setupRun?.hostID {
            setupSummaries[hostID] = "Setup stopped at \(step.title)."
        }
        refreshHosts()
        alert = DetailAlert(title: step.title, detail: "\(reason)\n\n\(remedy)")
        Log.claudeContext.error(
            "Claude remote host setup stopped at \(step.title, privacy: .public): \(reason, privacy: .public)"
        )
    }

    private func continueSetup(hostID: String) -> Bool {
        guard setupCancellationRequested else { return true }
        if var run = setupRun {
            for index in run.items.indices where run.items[index].state == .pending {
                run.items[index].state = .skipped("Setup was cancelled.")
            }
            setupRun = run
        }
        setupSummaries[hostID] = "Setup cancelled."
        refreshHosts()
        Log.claudeContext.info("Claude remote host setup cancelled")
        return false
    }

    private func performPluginUpdate(_ confirmation: EnrollmentConfirmation) async {
        guard let presentation = presentedPluginUpdate,
              let alias = presentation.sshHostAlias
        else { return }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        // Copied out of self before the detached hop, like `service`: the
        // closure is @Sendable and must not capture the main-actor model.
        let port = remoteForwardPort
        let snippet = presentation.sshConfigSnippet
        let hostID = presentation.hostID
        // ORDER IS THE SAFETY PROPERTY. The local block is rewritten first, and
        // the remote is touched only if that succeeded. Reverse them and a
        // refused local write (symlinked config, untrusted ~/.ssh) leaves the
        // remote posting to a port this Mac does not forward — silently. This
        // way the worst case is "nothing changed anywhere, with an error on
        // screen", which is a state a user can act on.
        let attempt = await performEnrollmentAsync {
            if let snippet {
                try service.insertSSHConfig(snippet: snippet, hostID: hostID)
            }
            return try service.executeRemotePluginUpdate(
                sshHostAlias: alias, remoteForwardPort: port
            )
        }

        // Same rule as the sheet: the row may have been closed, or another
        // host's opened, while ssh was still running — one host's outcome must
        // never render under another host's commands.
        guard presentedPluginUpdate == presentation else { return }

        publish(attempt, action: confirmation.action)
    }

    /// Turn one finished attempt into the statuses its section renders.
    private func publish(_ attempt: ClaudeEnrollmentActionAttempt, action: EnrollmentAction) {
        if let failure = attempt.failure {
            enrollmentStepStatuses = Self.failureStatuses(failure, action: action)
            enrollmentResultsAction = action
            alert = DetailAlert(
                title: Self.failureAlertTitle(for: action),
                detail: Self.enrollmentFailureDetail(failure, action: action)
            )
            Log.claudeContext.error(
                "Claude remote enrollment action failed: \(failure.describedError, privacy: .public)"
            )
            return
        }

        switch action {
        case .insertSSHConfig:
            enrollmentStepStatuses = [
                EnrollmentStepStatus(
                    id: 0, text: "Inserted this host's block into ~/.ssh/config.", succeeded: true, detail: ""
                )
            ]
        case .runRemoteSetup, .updateRemotePlugin:
            enrollmentStepStatuses = attempt.steps.map {
                EnrollmentStepStatus(
                    id: $0.index,
                    text: "Step \($0.index + 1) succeeded.",
                    succeeded: true,
                    detail: $0.message
                )
            }
        case .configureHerdrPanel:
            enrollmentStepStatuses = [
                EnrollmentStepStatus(
                    id: 0,
                    text: "Configured the remote herdr agents panel.",
                    succeeded: true,
                    detail: attempt.steps.first?.message ?? ""
                )
            ]
        case .setupHost, .updateHost:
            break
        }
        enrollmentResultsAction = action
    }

    static func failureAlertTitle(for action: EnrollmentAction) -> String {
        switch action {
        case .insertSSHConfig, .runRemoteSetup, .setupHost: return "Remote Claude Code setup"
        case .updateRemotePlugin: return "Remote Claude Code plugin"
        case .updateHost: return "Remote host update"
        case .configureHerdrPanel: return "Remote herdr panel"
        }
    }

    // MARK: - Step 3: check the setup

    /// Run the read-only checks and publish their verdicts.
    ///
    /// This replaced three copy-paste commands wrapped in a dozen comment lines
    /// telling the user how to read their output. It needs no confirmation
    /// step, unlike step 1 and step 2: it writes nothing, on either machine.
    ///
    /// The local half of the tunnel verdict is decided HERE, because it is a
    /// fact about this Mac: a 401 arriving through the forward proves only that
    /// something on this side answered, and when our own bind failed that
    /// something is the squatter holding the port (review finding, round 1).
    public func runVerification() async {
        guard let presentation = presentedPlan,
              !isEnrollmentBusy,
              !presentation.isPreview,
              // Same gate as one-click setup, for the same reason: with no
              // alias on file the sheet shows a placeholder, and checking
              // `your-ssh-host` would report on whatever machine happens to
              // answer to that name — a wrong answer that looks like an answer
              // (review finding, round 2).
              presentation.canRunRemoteSetup
        else { return }
        isPerformingVerification = true
        verificationChecks = []
        defer { isPerformingVerification = false }

        let service = enrollmentService
        let alias = presentation.sshHostAlias
        // Probe the tunnel that EXISTS, not the one the plan describes.
        //
        // The plan names this install's current allocation, but `~/.ssh/config`
        // may still forward what an earlier install — or the pre-#215 shared
        // 8473 — wrote there, and that is the port the user's live sessions are
        // actually binding. Probing the plan's port in that state answers "no
        // tunnel is live" about a tunnel that is perfectly alive, turning a
        // one-step fix into a mystery (review finding, round 3). A read-only
        // scan of this host's own block settles it; when the config is absent
        // or unreadable there is nothing better than the plan's port.
        let allocated = presentation.remoteForwardPort
        let configured = service.sshConfigForwardState(hostID: presentation.host.id)
        let port: UInt16
        let staleAllocatedPort: UInt16?
        switch configured {
        case .forwards(let configuredPort) where configuredPort != allocated:
            port = configuredPort
            staleAllocatedPort = allocated
        case .forwards, .absent, .unknown:
            port = allocated
            staleAllocatedPort = nil
        }
        let listenerWasBoundAtLaunch = listenerIsBound
        let attempt = await performVerificationAsync {
            try service.executeVerification(
                sshHostAlias: alias,
                remoteForwardPort: port,
                listenerIsBound: listenerWasBoundAtLaunch,
                staleAllocatedPort: staleAllocatedPort
            )
        }

        // Same late-result guard as `performPlanAction`, for the same reason:
        // the sheet can be dismissed — and replaced by a rotation that REUSES
        // the host id — while ssh is still running.
        guard presentedPlan == presentation else { return }

        if let failure = attempt.failure {
            verificationChecks = []
            alert = DetailAlert(
                title: "Check setup",
                detail: Self.verificationFailureDetail(failure)
            )
            Log.claudeContext.error(
                "Claude remote verification failed: \(failure.describedError, privacy: .public)"
            )
            return
        }

        // No redaction step, and none is possible: after a rotation the token a
        // host still has configured is one this process no longer knows. The
        // service therefore never puts probe output in a check at all, which is
        // the only form of that guarantee that survives rotation.
        //
        // The listener fact is read again HERE, on the main actor, after the
        // probes returned: the value handed to the service is up to a full
        // timeout old, and a listener that died in the meantime leaves the port
        // to whoever takes it next — whose 401 is indistinguishable from ours
        // over the wire. The ✓ requires bound at both moments (review finding,
        // round 2).
        verificationChecks = ClaudeRemoteEnrollmentService.reconciled(
            attempt.checks,
            remoteForwardPort: port,
            listenerIsBound: listenerIsBound
        )

        let failed = verificationChecks.filter { !$0.passed }
        guard !failed.isEmpty else { return }
        // Owner rule: the sheet shows one short line per check; the diagnostics
        // belong in the alert and the log.
        alert = DetailAlert(
            title: "Check setup",
            detail: failed
                .map { check in
                    let hint = check.hint.map { " \($0)" } ?? ""
                    return check.detail.isEmpty
                        ? "\(check.title): \(check.summary)\(hint)"
                        : "\(check.title): \(check.summary)\(hint)\n\n\(check.detail)"
                }
                .joined(separator: "\n\n")
        )
        Log.claudeContext.error(
            "Claude remote verification reported \(failed.count, privacy: .public) failed check(s)"
        )
    }

    /// Why a check could not run at all.
    ///
    /// Deliberately NOT routed through `enrollmentFailureDetail`: that one is
    /// written for an action that writes ("SSH setup exited with…"), and it is
    /// keyed on an `EnrollmentAction` a check does not have. Verification can
    /// only throw two things, and everything else here is a "should not happen"
    /// that must still say something true.
    static func verificationFailureDetail(_ failure: ClaudeEnrollmentActionFailure) -> String {
        switch failure.serviceError {
        case .executionNotConfigured:
            return "Checking the setup is not available in this build."
        case .invalidHostAlias:
            return "This host has no usable SSH alias, so there is nothing to check."
        default:
            return "The check could not run."
        }
    }

    // MARK: - Screenshot preview

    /// Hidden debug default that arms the sample enrollment sheet.
    ///
    /// `debug.` prefixed like `debug.log_realtime_deltas`: not a product
    /// preference, no UI, and never surfaced in Settings. It exists so
    /// `scripts/capture-readme-assets.sh` can photograph a sheet that would
    /// otherwise require enrolling a real host and burning a real token.
    public static let enrollmentSheetPreviewDefaultsKey = "debug.enrollment_sheet_preview"

    public static func isEnrollmentSheetPreviewArmed(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: Self.enrollmentSheetPreviewDefaultsKey)
    }

    /// Present a sample sheet for screenshots.
    ///
    /// Nothing here is real: the host is not in the registry, the token is
    /// visibly fake, and `isPreview` makes every mutating entry point refuse.
    /// A preview therefore cannot write `~/.ssh/config`, spawn ssh, or change
    /// the enrolled-host list — the guards are in the model, so the view cannot
    /// forget one.
    public func presentPreviewPlan() {
        guard presentedPlan == nil else { return }
        let host = ClaudeRemoteHost(
            id: "preview0",
            label: "build-host",
            sshHostAlias: "build-host",
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: nil,
            revokedAt: nil
        )
        // Token-shaped so the sheet's layout is honest, and unmistakably not a
        // credential. It is long enough for `ClaudeRemoteTokenRedaction` to
        // treat it as one, so the step-2 preview redacts it exactly as it would
        // redact a real token.
        let token = "lvx-preview-" + String(repeating: "0", count: 31)
        guard let plan = try? ClaudeRemoteEnrollmentService.plan(
            host: host,
            sshHostAlias: "build-host",
            token: token,
            listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
            remoteForwardPort: remoteForwardPort
        ) else { return }
        enrollmentConfirmation = nil
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        presentedPlan = EnrollmentPresentation(
            host: host,
            token: token,
            sshHostAlias: "build-host",
            plan: plan,
            isRotation: false,
            remoteForwardPort: remoteForwardPort,
            isPreview: true
        )
        Log.claudeContext.info("Claude remote enrollment sheet presented in preview mode")
    }

    public static func redactedRemoteCommands(for presentation: EnrollmentPresentation) -> String {
        presentation.plan.remoteCommands
            .map { ClaudeRemoteTokenRedaction.redact($0, token: presentation.token) }
            .joined(separator: "\n")
    }

    private static func failureStatuses(
        _ failure: ClaudeEnrollmentActionFailure,
        action: EnrollmentAction
    ) -> [EnrollmentStepStatus] {
        guard action != .insertSSHConfig else {
            return [EnrollmentStepStatus(id: 0, text: "SSH config update failed.", succeeded: false, detail: failure.describedError)]
        }

        let failedStep: Int
        let detail: String
        switch failure.serviceError {
        case .commandFailed(let step, _, _, let message):
            failedStep = step
            detail = message
        case .commandTimedOut(let step, _, _, let message):
            failedStep = step
            detail = message
        case .runnerFailed(let step, _, let message):
            failedStep = step
            detail = message
        default:
            var text = "Remote setup failed."
            if case .updateRemotePlugin = action { text = "Plugin update failed." }
            if case .configureHerdrPanel = action { text = "Herdr panel setup failed." }
            let detail: String
            if failure.serviceError == .herdrPanelConfigAlreadyCustomized {
                detail = "Open Details for the manual herdr configuration."
            } else {
                detail = failure.describedError
            }
            return [EnrollmentStepStatus(id: 0, text: text, succeeded: false, detail: detail)]
        }
        let succeeded = (0..<failedStep).map {
            EnrollmentStepStatus(id: $0, text: "Step \($0 + 1) succeeded.", succeeded: true, detail: "")
        }
        return succeeded + [
            EnrollmentStepStatus(
                id: failedStep,
                text: "Step \(failedStep + 1) failed.",
                succeeded: false,
                detail: detail
            )
        ]
    }

    /// The alert body. `action` names the work in the user's terms — an alert
    /// that says "SSH setup" after they pressed Update Plugin reads as a
    /// different failure than the one they are looking at.
    static func enrollmentFailureDetail(
        _ failure: ClaudeEnrollmentActionFailure,
        action: EnrollmentAction
    ) -> String {
        var subject = "SSH setup"
        if case .updateRemotePlugin = action { subject = "Plugin update" }
        if case .configureHerdrPanel = action { subject = "Herdr panel setup" }
        switch failure.serviceError {
        case .commandTimedOut(_, _, let seconds, let message):
            let output = message.isEmpty ? "" : "\n\n\(message)"
            return "\(subject) did not finish within \(Int(seconds))s and was stopped.\(output)"
        case .commandFailed(_, _, let exitCode, let message):
            return "\(subject) exited with code \(exitCode).\n\n\(message)"
        case .runnerFailed(_, _, let message):
            return "\(subject) could not run.\n\n\(message)"
        case .invalidSSHConfigEncoding:
            return "~/.ssh/config is not valid UTF-8, so localvoxtral left it unchanged."
        case .sshConfigIsSymlink:
            return "~/.ssh/config or ~/.ssh is a symlink, likely from a dotfiles setup. "
                + "localvoxtral won't replace the link. Open Details and add the block "
                + "to the real file yourself."
        case .sshDirectoryNotTrusted:
            return "~/.ssh is not exclusively writable by you (wrong owner or group/world-"
                + "writable), so localvoxtral left it unchanged. Open Details for the "
                + "manual remedy."
        case .sshConfigEditingNotConfigured:
            return "Editing ~/.ssh/config is not available in this build."
        case .executionNotConfigured:
            return "Running commands over SSH is not available in this build."
        case .invalidHostAlias:
            return "The SSH host alias is invalid."
        case .herdrPanelConfigAlreadyCustomized:
            return "The remote herdr config already has an agents table or rows key, so "
                + "localvoxtral left it unchanged. Open Details for the manual remedy."
        case .none:
            return failure.describedError
        }
    }

    private func reconcileListener(presentAlert: Bool = true) {
        guard let listener else { return }
        // Shutdown is the MIRROR of startup, and this is the shutdown case:
        // revoking the last host is about to close the port, so the forwards
        // into it come down first. Reversed — the documented order everywhere
        // else in this feature — a hook arriving during `listener.stop()` rides
        // a live tunnel into a socket that is already gone, and the Mac's ssh
        // client answers it by printing `connect_to … failed.` into the user's
        // remote terminal.
        if listener.isListening, registry?.hasActiveHosts != true {
            forwards?.stopAll()
        }
        do {
            try listener.reconcile()
            listenerStatus = listener.isListening ? .listening(port: listener.boundPort) : .idle
            // Listener FIRST, forwards second — always, including here. A
            // forward opened before the bind terminates at a closed port: the
            // hooks get connection-refused and fail open (silently), while
            // ssh on this Mac prints `connect_to … failed.` into the user's
            // remote terminal on every dial. The coordinator enforces the same
            // rule itself by refusing to run while the listener is unbound;
            // this ordering is what makes the enabled case take effect without
            // a relaunch.
            forwards?.reconcile()
        } catch {
            // A listener that failed to bind must not leave forwards running
            // into a dead port.
            forwards?.stopAll()
            listenerStatus = Self.status(for: error, port: listener.boundPort)
            if presentAlert {
                alert = DetailAlert(
                    title: "Remote Claude Code context",
                    detail: Self.listenerFailureDetail(error, port: listener.boundPort)
                )
            }
            Log.claudeContext.error(
                "Claude remote listener reconcile failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    static func status(for error: any Error, port: UInt16) -> ListenerStatus {
        if case .bindFailed(let code)? = error as? ClaudeRemoteContextListener.StartFailure,
           code == EADDRINUSE {
            return .portConflict(port: port)
        }
        return .failed
    }

    static func listenerFailureDetail(_ error: any Error, port: UInt16) -> String {
        if case .bindFailed(let code)? = error as? ClaudeRemoteContextListener.StartFailure,
           code == EADDRINUSE {
            return "localvoxtral could not bind 127.0.0.1:\(port), because something else already has it.\n\n"
                + "This is usually a second copy of localvoxtral. Note that a squatter on this port would "
                + "receive your remote hosts' context. It cannot authenticate them because it does not have the "
                + "token hashes), but it does see what they send before the request is rejected. Find and "
                + "quit whatever holds the port rather than moving off it.\n\n"
                + "`lsof -nP -iTCP:\(port) -sTCP:LISTEN` will name the process."
        }
        return String(describing: error)
    }

    private func presentRegistryFailure(_ error: any Error, verb: String) {
        alert = DetailAlert(
            title: "Remote Claude Code context",
            detail: "Could not \(verb) the host.\n\n\(Self.registryFailureDetail(error))"
        )
        Log.claudeContext.error(
            "Claude remote host \(verb, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
    }

    static func registryFailureDetail(_ error: any Error) -> String {
        if let pathFailure = error as? ClaudeSocketGuard.PreconditionFailure {
            switch pathFailure {
            case .permissive(let path, _):
                return "The private host-list folder at \(path) has unsafe permissions."
            case .isSymlink(let path):
                return "The host-list path at \(path) is a symbolic link and was refused."
            case .wrongOwner(let path, _, _):
                return "The host-list path at \(path) is owned by another user."
            case .notADirectory(let path):
                return "The host-list folder path at \(path) is not a directory."
            case .cannotCreate(let path, _):
                return "localvoxtral could not prepare the private host-list folder at \(path)."
            }
        }
        switch error as? ClaudeRemoteHostRegistry.StoreError {
        case .invalidLabel:
            return "The name needs at least one letter or digit."
        case .tooManyHosts(let limit):
            return "You have reached the limit of \(limit) enrolled hosts. Remove one first."
        case .writeFailed(let path):
            return "localvoxtral could not save the host list to \(path)."
        case .unreadable(let path):
            return "The host list at \(path) could not be read."
        case .unsupportedVersion:
            return "The host list was written by a newer version of localvoxtral."
        case .unknownHost, .idAllocationFailed, .none:
            return String(describing: error)
        }
    }
}
