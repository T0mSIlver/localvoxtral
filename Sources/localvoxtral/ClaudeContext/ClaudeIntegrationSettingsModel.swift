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
        public var isRevoked: Bool
        public var lastSeenAt: Date?

        /// The part of the status that is not a date.
        ///
        /// A `RelativeDateTimeFormatter` cached in a `static let` here would be
        /// non-Sendable global state — a Swift 6 error — and building one per
        /// row per redraw is worse. The view renders `lastSeenAt` with
        /// `Text(_:style:)`, which also keeps ticking on its own.
        public var statusText: String {
            if isRevoked { return "Revoked" }
            return lastSeenAt == nil ? "Enrolled — not seen yet" : "Last seen"
        }
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
    /// copy it, and rotation is the recovery path.
    public struct EnrollmentPresentation: Identifiable, Equatable, Sendable {
        public var id: String { host.id }
        public var host: ClaudeRemoteHost
        public var token: String
        public var plan: ClaudeRemoteEnrollmentService.SetupPlan
        /// Rotation reuses this sheet; the copy differs because the user's
        /// situation does (their remote is currently broken, on purpose).
        public var isRotation: Bool
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
    /// Short result copy for the local plugin action, e.g. "Installed." Cleared
    /// when a new action starts.
    public private(set) var pluginResult: String?
    public private(set) var isPerformingPluginAction = false
    public private(set) var presentedPlan: EnrollmentPresentation?
    public var alert: DetailAlert?

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
    /// Runs one plugin action and returns its failure, or nil.
    ///
    /// Off the main actor by default: `claude plugin install` fetches, and 60s
    /// of beachball is not a UI. Injected so tests run it synchronously — the
    /// production hop would make every assertion a race.
    private let performAsync:
        @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure?

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
        performAsync: @escaping @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure? = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            }.value
        }
    ) {
        self.registry = registry
        self.listener = listener
        self.pluginService = pluginService
        self.performAsync = performAsync
        refreshHosts()
        refreshListenerStatus()
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
        case .commandFailed(_, let exitCode, let message):
            return "`claude plugin` exited with code \(exitCode).\n\n\(message)"
        case .none:
            return failure.describedError
        }
    }

    // MARK: - Remote hosts

    public func refreshHosts() {
        hosts = (registry?.hosts() ?? []).map {
            HostRow(id: $0.id, label: $0.label, isRevoked: $0.isRevoked, lastSeenAt: $0.lastSeenAt)
        }
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
            let enrollment = try registry.enroll(label: label)
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                sshHostAlias: alias,
                token: enrollment.token,
                port: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port
            )
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
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
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                // The alias is not persisted — it is the user's ssh config, not
                // ours — so the label is the best guess we have, and the sheet
                // says so rather than pretending.
                sshHostAlias: ClaudeRemoteEnrollmentService.isValidHostAlias(enrollment.host.label)
                    ? enrollment.host.label
                    : "your-ssh-host",
                token: enrollment.token,
                port: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port
            )
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                plan: plan,
                isRotation: true
            )
            refreshHosts()
            // Rotation reinstates a revoked host, so it can be a 0→1 transition.
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "rotate the token for")
        }
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

    public func dismissPlan() {
        // The plaintext goes with it. Nothing else holds a copy.
        presentedPlan = nil
    }

    private func reconcileListener() {
        guard let listener else { return }
        do {
            try listener.reconcile()
            listenerStatus = listener.isListening ? .listening(port: listener.boundPort) : .idle
        } catch {
            listenerStatus = Self.status(for: error, port: listener.boundPort)
            alert = DetailAlert(
                title: "Remote Claude Code context",
                detail: Self.listenerFailureDetail(error, port: listener.boundPort)
            )
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
