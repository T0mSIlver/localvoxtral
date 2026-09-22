import Foundation

/// What the login item is doing, reduced to the answers the General pane's
/// toggle has to render.
enum LoginItemState: Equatable, Sendable {
    /// A login item is installed for THIS copy of the app.
    case enabled
    /// A login item is installed, for a copy of localvoxtral somewhere else —
    /// the everyday state on a Mac that also runs a build under test. It reads
    /// ON, because localvoxtral does start at the next login; the row says
    /// which copy.
    case enabledForAnotherCopy
    /// No login item.
    case disabled
    /// Nothing to open at login: the running binary is not in an `.app` bundle
    /// (a `swift run` build).
    case unavailable
}

/// The login item itself, behind a seam so the controller's tests never write
/// into the developer's own `~/Library/LaunchAgents`.
@MainActor
protocol LoginItemRegistering: AnyObject {
    func currentState() -> LoginItemState
    func register() throws
    func unregister() throws
}

/// A launch agent in `~/Library/LaunchAgents` that opens the app at login.
///
/// NOT `SMAppService.mainApp`, which is the modern API and the one to move to:
/// it answers `notFound` for every build this project can produce today —
/// measured on the packaged build from `~/localvoxtral-ui-artifacts`,
/// `~/Applications` and `/Applications` alike (#449). These builds are
/// self-signed (`localvoxtral-dev`, no Team ID), and macOS's background task
/// manager will not take an unnotarized app. Developer ID + notarization is
/// roadmap #1; the day it lands, this class is the only thing that changes.
///
/// `launchd` reads this directory at login, so writing the file IS the
/// registration: nothing is bootstrapped into the running session, and the
/// item takes effect at the next login — which is all the switch promises.
@MainActor
final class LaunchAgentLoginItemRegistrar: LoginItemRegistering {
    /// The file is named after the label, so one glance at the directory says
    /// who installed what.
    static let label = "com.localvoxtral.login"

    private let directory: URL
    /// The `.app` to open at login, or nil when the running binary is not in
    /// one.
    private let appBundle: URL?

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
        appBundle: URL? = LaunchAgentLoginItemRegistrar.runningAppBundle()
    ) {
        self.directory = directory
        self.appBundle = appBundle
    }

    /// `Bundle.main.bundleURL` is the `.app` for a packaged build and the
    /// enclosing directory for a bare executable — the extension is what tells
    /// them apart.
    static func runningAppBundle() -> URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    private var plistURL: URL {
        directory.appending(path: "\(Self.label).plist", directoryHint: .notDirectory)
    }

    func currentState() -> LoginItemState {
        guard let appBundle else { return .unavailable }
        guard let installed = installedAppPath() else { return .disabled }
        return installed == appBundle.path ? .enabled : .enabledForAnotherCopy
    }

    func register() throws {
        guard let appBundle else { throw LoginItemError.notAnAppBundle }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let agent: [String: Any] = [
            "Label": Self.label,
            // `open`, not the executable inside the bundle: LaunchServices is
            // what knows how to start an app — one instance of it, with the
            // bundle identity and the environment a double-click gives it.
            "ProgramArguments": ["/usr/bin/open", appBundle.path],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: agent, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    func unregister() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// The app path the installed agent opens, or nil when there is none. A
    /// file that will not read as our plist counts as none: rewriting it is
    /// exactly what turning the switch on does, and refusing would stand the
    /// user in front of a row that cannot be turned on.
    private func installedAppPath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.last
    }
}

enum LoginItemError: Error {
    case notAnAppBundle
}

/// Backs "Open localvoxtral at login".
///
/// The installed login item is the single source of truth — nothing is
/// mirrored into `SettingsStore`. The user can remove it from System Settings
/// while the app is not running, so a stored copy would be a second answer
/// that is wrong from the moment they do.
@MainActor
@Observable
final class LoginItemController {
    private(set) var state: LoginItemState
    /// Set when the last change did not land, cleared by the next read of the
    /// login item. One short sentence, like every other row status.
    private(set) var failure: String?

    private let registrar: LoginItemRegistering

    init(registrar: LoginItemRegistering = LaunchAgentLoginItemRegistrar()) {
        self.registrar = registrar
        let state = registrar.currentState()
        self.state = state
        // What the login item looked like at launch, once per launch. A row
        // that cannot work is otherwise indistinguishable in the field from
        // one nobody ever turned on.
        Log.diagnostics.info(
            "Login item state at launch: \(String(describing: state), privacy: .public)"
        )
    }

    /// Where the toggle sits. An item installed for another copy is still an
    /// item: localvoxtral does open at login.
    var isOn: Bool {
        state == .enabled || state == .enabledForAnotherCopy
    }

    var isAvailable: Bool {
        state != .unavailable
    }

    var statusMessage: String? {
        if let failure { return failure }
        switch state {
        case .enabledForAnotherCopy: return "Set up for another copy of localvoxtral."
        case .unavailable: return "Only an installed copy can do this."
        case .enabled, .disabled: return nil
        }
    }

    /// Re-reads the login item. Called whenever the pane appears and whenever
    /// the app comes back to the front, because System Settings can have
    /// removed it in between.
    func refresh() {
        failure = nil
        state = registrar.currentState()
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
                "Login item \(isOn ? "installed" : "removed", privacy: .public)."
            )
        } catch {
            Log.diagnostics.error(
                """
                Login item \(isOn ? "install" : "removal", privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """
            )
            failure = isOn
                ? "Couldn't add localvoxtral to your login items."
                : "Couldn't remove localvoxtral from your login items."
        }
        // What is on disk now, not what was asked for.
        state = registrar.currentState()
    }
}
