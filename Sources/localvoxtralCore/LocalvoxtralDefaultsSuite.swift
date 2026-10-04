import Foundation

/// Where the app keeps its preferences: its own defaults domain
/// (`com.localvoxtral.app`), or the suite named by
/// `LOCALVOXTRAL_DEFAULTS_SUITE` when set (#1029).
///
/// The override is for the UI Smoke and e2e lanes on the owner's Mac: they
/// write their forced settings into a suite of their own and launch the app on
/// it, so no lane writes, snapshots or restores the owner's domain. A suite
/// name the system will not open (the app's own domain, `NSGlobalDomain`)
/// is refused, never replaced by the app's own domain.
package enum LocalvoxtralDefaultsSuite {
    package static let environmentKey = "LOCALVOXTRAL_DEFAULTS_SUITE"

    package enum Resolution {
        case standard
        case suite(name: String, defaults: UserDefaults)
        case refused(name: String)
    }

    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Resolution {
        guard let name = environment[environmentKey], !name.isEmpty else { return .standard }
        guard name != bundleIdentifier, name != UserDefaults.globalDomain,
              let defaults = UserDefaults(suiteName: name)
        else { return .refused(name: name) }
        return .suite(name: name, defaults: defaults)
    }
}
