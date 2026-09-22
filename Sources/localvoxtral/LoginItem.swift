import Foundation
import ServiceManagement

/// What the system says about the app's login item, reduced to the four
/// answers the General pane's toggle has to render.
enum LoginItemState: Equatable, Sendable {
    /// Registered, and macOS will launch the app at the next login.
    case enabled
    /// Not registered.
    case disabled
    /// Registered, but macOS will not launch it until the user approves it in
    /// System Settings. Reached by turning the toggle on after turning it off
    /// there — approval, once withdrawn, is the user's to give back.
    case requiresApproval
    /// There is no login item to register: the running binary is not an
    /// installed `.app` (a `swift run` build, or a copy the system refuses).
    case unavailable
}

/// The system's login-item registration, behind a seam.
///
/// Tests must never reach the real one: `SMAppService.mainApp.register()`
/// from a test run would add the XCTest runner's host to the user's login
/// items, on the developer's own Mac.
@MainActor
protocol LoginItemRegistering: AnyObject {
    func currentState() -> LoginItemState
    func register() throws
    func unregister() throws
    /// Opens System Settings on Login Items, for the approval the app cannot
    /// give itself.
    func openSystemSettings()
}

/// `SMAppService.mainApp`: the app registers ITSELF as the login item, so no
/// helper bundle ships inside `Contents/Library/LoginItems`.
@MainActor
final class SystemLoginItemRegistrar: LoginItemRegistering {
    func currentState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        // A status this build does not know cannot be rendered as a switch
        // honestly: reported as off, it would spring back the moment the user
        // flipped it. The row says nothing can be done here instead.
        @unknown default: return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Backs "Open localvoxtral at login".
///
/// The system registration is the single source of truth — nothing is mirrored
/// into `SettingsStore`. The user can remove the login item from System
/// Settings without the app running, so a stored copy would be a second answer
/// that is wrong from the moment they do.
@MainActor
@Observable
final class LoginItemController {
    private(set) var state: LoginItemState
    /// Set when the last change did not land, cleared by the next read of the
    /// system. One short sentence, like every other row status.
    private(set) var failure: String?

    private let registrar: LoginItemRegistering

    init(registrar: LoginItemRegistering = SystemLoginItemRegistrar()) {
        self.registrar = registrar
        let state = registrar.currentState()
        self.state = state
        // What the system said at launch, once per launch. A row that refuses
        // to work is otherwise indistinguishable in the field from one that
        // works and was never turned on.
        Log.diagnostics.info(
            "Login item state at launch: \(String(describing: state), privacy: .public)"
        )
    }

    /// Where the toggle sits. Awaiting approval counts as on: the app is
    /// registered, and the switch must not spring back while the user is being
    /// asked to allow what they just asked for.
    var isOn: Bool {
        state == .enabled || state == .requiresApproval
    }

    var isAvailable: Bool {
        state != .unavailable
    }

    /// The app is registered and macOS is waiting for the user to allow it.
    /// The only state with somewhere to send them.
    var needsApproval: Bool {
        state == .requiresApproval
    }

    var statusMessage: String? {
        if let failure { return failure }
        switch state {
        case .requiresApproval: return "Needs your approval in System Settings."
        case .unavailable: return "Only an installed copy can do this."
        case .enabled, .disabled: return nil
        }
    }

    /// Re-reads the system. Called whenever the pane appears, because System
    /// Settings can have turned the login item off since it was last read.
    func refresh() {
        failure = nil
        state = registrar.currentState()
    }

    func openSystemSettings() {
        registrar.openSystemSettings()
    }

    func setOn(_ isOn: Bool) {
        failure = nil
        do {
            if isOn {
                try registrar.register()
            } else {
                try registrar.unregister()
            }
            Log.diagnostics.notice(
                "Login item \(isOn ? "registered" : "unregistered", privacy: .public)."
            )
        } catch {
            Log.diagnostics.error(
                """
                Login item \(isOn ? "registration" : "removal", privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """
            )
            failure = isOn
                ? "Couldn't add localvoxtral to your login items."
                : "Couldn't remove localvoxtral from your login items."
        }
        // The system's answer, not ours: a register() that returned without
        // throwing can still land on `requiresApproval`.
        state = registrar.currentState()
    }
}
