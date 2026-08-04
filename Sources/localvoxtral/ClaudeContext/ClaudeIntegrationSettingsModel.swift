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

/// Settings-pane state for both Claude Code integrations.
///
/// `@MainActor @Observable`, per repo convention for stateful UI controllers.
/// Every dependency is injected: no singleton reaches through this type to a
/// real process, a real port, or a real host.
///
/// The division of labour with the view is deliberate. Everything that could be
/// wrong — a failed install, a port conflict, a token that must be shown exactly
/// once — is decided and shaped here, where it has a test. The view renders
/// strings.
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
            case .idle: return "Not listening — no hosts enrolled."
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
                return "Another app — often a second copy of localvoxtral — holds \(port). "
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
    /// the whole point of storing only hashes — so the user gets one chance to
    /// copy it. It is not persisted locally; one-click setup only carries it in
    /// the confirmed SSH process's stdin. Rotation is the recovery path.
    public struct EnrollmentPresentation: Identifiable, Equatable, Sendable {
        public var id: String { host.id }
        public var host: ClaudeRemoteHost
        public var token: String
        public var sshHostAlias: String
        public var plan: ClaudeRemoteEnrollmentService.SetupPlan
        /// Rotation reuses this sheet; the copy differs because the user's
        /// situation does (their remote is currently broken, on purpose).
        public var isRotation: Bool
        /// False when `sshHostAlias` is the sheet's placeholder rather than an
        /// alias the user gave us — a legacy host rotated before the alias was
        /// persisted. The commands are still copyable; what is withheld is
        /// one-click execution, which would otherwise hand a fresh token to
        /// whichever machine happened to answer to a guessed name.
        public var canRunRemoteSetup: Bool = true
    }

    /// The two commands that bring one enrolled host to the plugin version this
    /// app ships, plus the host they belong to.
    ///
    /// Carries no token — `claude plugin update` keeps the config the install
    /// stored — so unlike `EnrollmentPresentation` this can be shown at any
    /// time, which is the point: the user needs it long after the one-time
    /// token is gone.
    public struct PluginUpdatePresentation: Identifiable, Equatable, Sendable {
        public var id: String { hostID }
        public var hostID: String
        /// The alias one-click execution would use, or nil when the host's
        /// label is not a usable one. The alias belongs to the user's ssh
        /// config and is never persisted, so the label is the only guess
        /// available; when it does not qualify the commands are copy-only and
        /// name a placeholder instead of pretending.
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

        /// Everything this update consists of, in the order it must be applied.
        ///
        /// ONE rendering, used by all three surfaces — the panel's text, its
        /// Copy button, and the confirmation preview. They diverged once
        /// already: the executable path wrote the ssh block while the panel
        /// showed and copied only the commands, so the copy-only paths (a host
        /// with no recorded alias, and the symlink refusal that explicitly
        /// tells the user to copy) updated the remote port and left this Mac on
        /// 8473 — the original split brain, reachable by exactly the users most
        /// likely to hit it. A single source is the fix; three call sites that
        /// "should stay in sync" is what produced the bug.
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
        /// Per-host, because the pane shows one row per host and the outcome
        /// has to render in the row whose button ran it.
        case updateRemotePlugin(hostID: String)
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
    /// The update commands the user asked to see, for one host at a time.
    public private(set) var presentedPluginUpdate: PluginUpdatePresentation?
    public private(set) var enrollmentConfirmation: EnrollmentConfirmation?
    public private(set) var enrollmentStepStatuses: [EnrollmentStepStatus] = []
    /// Which action produced `enrollmentStepStatuses`. The sheet renders each
    /// outcome inside the section whose button the user actually clicked; a
    /// pooled results area below step 2 is how a step-1 success went unseen
    /// and got re-confirmed (field report 2026-07-26).
    public private(set) var enrollmentResultsAction: EnrollmentAction?
    public private(set) var isPerformingEnrollmentAction = false
    public var alert: DetailAlert?

    /// What the cmux control socket last told us, as one short sentence in the
    /// pane. Written by the join resolver on every attempt, so a user who
    /// dictates and sees no cmux context can read WHY here instead of in the
    /// log. `.ok` renders nothing — a working feature says nothing.
    var cmuxStatus: CmuxSocketStatus = .ok

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
        now: @escaping @Sendable () -> Date = { Date() },
        // Defaults to the legacy shared port: a caller that has not been taught
        // about per-Mac allocation describes exactly the pre-#215 setup, which
        // still works. Production passes the allocation.
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        cmuxPasswords: (any CmuxPasswordStoring)? = nil,
        forwards: ClaudeRemoteForwardCoordinator? = nil
    ) {
        self.registry = registry
        self.listener = listener
        self.pluginService = pluginService
        self.enrollmentService = enrollmentService
        self.performAsync = performAsync
        self.performEnrollmentAsync = performEnrollmentAsync
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
                    && host.sshHostAlias.map(ClaudeRemoteEnrollmentService.isValidHostAlias) == true
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
    /// The hedge in "a host MAY have" is deliberate. The listener counts every
    /// rejected connection, and an enrolled host is not the only thing that can
    /// reach a loopback port: a probe or a curl with no `Authorization` header
    /// lands in `.missingToken` exactly like a pre-1.1.0 plugin does. Naming a
    /// cause with certainty would sometimes accuse a host of a fault it does
    /// not have.
    static func rejectionHint(for snapshot: ClaudeRemoteRejectionTally.Snapshot) -> String? {
        guard !snapshot.isEmpty else { return nil }
        let cause: String
        switch (snapshot.missingToken > 0, snapshot.unknownToken > 0) {
        case (true, true):
            cause = "an outdated plugin or a stale token"
        case (true, false):
            cause = "an outdated plugin — use Update Plugin"
        case (false, true):
            cause = "a stale token — rotate it and re-run setup"
        case (false, false):
            cause = "a malformed authorization header"
        }
        return "Rejected connections detected — a host may have \(cause)."
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
                detail: "“\(alias)” is not an SSH host alias. Use the name from your ~/.ssh/config — "
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
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias,
                plan: plan,
                isRotation: false
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
            // before the alias was persisted gets the placeholder and copy-only
            // commands, which is honest about what we know.
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
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                plan: plan,
                isRotation: true,
                canRunRemoteSetup: alias != nil
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

    public func remove(hostID: String) async {
        guard let registry else { return }
        do {
            try registry.remove(hostID: hostID)
            // The row is going away; its open update panel must not outlive it.
            if presentedPluginUpdate?.hostID == hostID { dismissPluginUpdate() }
            refreshHosts()
            reconcileListener()
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
    }

    /// Show one host's plugin-update commands in its row.
    ///
    /// Needed because `claude plugin install` is not an update: on an installed
    /// plugin it exits 0 and leaves the old version in place (Claude Code
    /// 2.1.220), so re-running enrollment does nothing and a host stays on a
    /// plugin the app has since fixed — silently, because the hooks fail open.
    public func requestPluginUpdate(hostID: String) {
        guard !isPerformingEnrollmentAction,
              let host = hosts.first(where: { $0.id == hostID })
        else { return }
        // The ENROLLED alias, never the label: a host named `prod` may be
        // reached over alias `builder`, and `ssh prod …` would then update
        // whatever machine answers to that name (review finding, PR #197).
        // Hosts enrolled before the alias was persisted have none, and get
        // copy-only commands rather than a guess.
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
        let alreadyForwards =
            registry?.host(id: hostID).flatMap { host in
                enrollmentService.sshConfigForwardsPort(remoteForwardPort, hostID: host.id)
            } ?? false
        let snippet: String? = alreadyForwards ? nil : registry?.host(id: hostID).map { host in
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

    /// Exactly what `performPluginUpdate` will do, in order — and exactly what
    /// the panel shows and copies. Same text, one source.
    static func updatePreview(for presentation: PluginUpdatePresentation) -> String {
        presentation.applicationText
    }

    /// Stands in for an alias we were never told. Not a valid target and not
    /// meant to be one — it is there so the copyable commands read correctly
    /// with an obvious blank to fill in.
    static let unknownAliasPlaceholder = "your-ssh-host"

    public func dismissPluginUpdate() {
        if case .updateRemotePlugin? = enrollmentResultsAction {
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
        }
        if case .updateRemotePlugin? = enrollmentConfirmation?.action {
            enrollmentConfirmation = nil
        }
        presentedPluginUpdate = nil
    }

    /// Ask before running the update commands, repeating the exact pair.
    public func requestPluginUpdateRun() {
        guard let presentation = presentedPluginUpdate,
              presentation.canRun,
              !isPerformingEnrollmentAction
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .updateRemotePlugin(hostID: presentation.hostID),
            title: presentation.sshConfigSnippet == nil
                ? "Update the plugin on this SSH host?"
                : "Update ~/.ssh/config on this Mac and the plugin on this SSH host?",
            // Both halves, verbatim, in the order they will run. The rule that
            // one-click actions repeat their exact text does not get weaker
            // because an action now has two parts — it gets more important.
            preview: Self.updatePreview(for: presentation),
            confirmButtonTitle: "Confirm Update"
        )
        Log.claudeContext.info("Claude remote plugin update confirmation requested")
    }

    public func requestSSHConfigInsertion() {
        guard let presentation = presentedPlan, !isPerformingEnrollmentAction else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .insertSSHConfig,
            title: "Insert this exact block into ~/.ssh/config?",
            preview: presentation.plan.sshConfigSnippet,
            confirmButtonTitle: "Confirm Insert"
        )
        Log.claudeContext.info("Claude remote ssh config confirmation requested")
    }

    public func requestRemoteSetup() {
        guard let presentation = presentedPlan,
              // A placeholder alias must not reach ssh: one-click would hand
              // the new token to whatever answers to a name we invented.
              presentation.canRunRemoteSetup,
              !isPerformingEnrollmentAction
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .runRemoteSetup,
            title: "Run these commands on the SSH host?",
            preview: Self.redactedRemoteCommands(for: presentation),
            confirmButtonTitle: "Confirm Run"
        )
        Log.claudeContext.info("Claude remote setup confirmation requested")
    }

    public func cancelEnrollmentActionConfirmation() {
        enrollmentConfirmation = nil
    }

    public func confirmEnrollmentAction() async {
        guard let confirmation = enrollmentConfirmation, !isPerformingEnrollmentAction else { return }
        switch confirmation.action {
        case .insertSSHConfig, .runRemoteSetup:
            await performPlanAction(confirmation)
        case .updateRemotePlugin:
            await performPluginUpdate(confirmation)
        }
    }

    private func performPlanAction(_ confirmation: EnrollmentConfirmation) async {
        guard let presentation = presentedPlan else { return }
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
        case .updateRemotePlugin:
            // Routed to performPluginUpdate: that action belongs to a host row,
            // has no plan and no token, and must not run against one.
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
        }
        enrollmentResultsAction = action
    }

    static func failureAlertTitle(for action: EnrollmentAction) -> String {
        switch action {
        case .insertSSHConfig, .runRemoteSetup: return "Remote Claude Code setup"
        case .updateRemotePlugin: return "Remote Claude Code plugin"
        }
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
            return [EnrollmentStepStatus(id: 0, text: text, succeeded: false, detail: failure.describedError)]
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
            return "~/.ssh/config (or ~/.ssh) is a symlink — likely a dotfiles setup. "
                + "localvoxtral won't replace the link; use the Copy button and add the block "
                + "to the real file yourself."
        case .sshDirectoryNotTrusted:
            return "~/.ssh is not exclusively writable by you (wrong owner or group/world-"
                + "writable), so localvoxtral left it unchanged. Fix its permissions "
                + "(chmod 700 ~/.ssh) or use the Copy button."
        case .sshConfigEditingNotConfigured:
            return "Editing ~/.ssh/config is not available in this build."
        case .executionNotConfigured:
            return "Running commands over SSH is not available in this build."
        case .invalidHostAlias:
            return "The SSH host alias is invalid."
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
                + "receive your remote hosts' context — it cannot authenticate them (it does not have the "
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
