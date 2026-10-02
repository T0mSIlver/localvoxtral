import Foundation

/// The app's preferences, resolved once per launch (`LocalvoxtralDefaultsSuite`).
/// Every app read and write of `UserDefaults` goes through `shared`.
public enum AppDefaults {
    public static let shared: UserDefaults = {
        switch LocalvoxtralDefaultsSuite.resolve() {
        case .standard:
            return .standard
        case .suite(let name, let defaults):
            Log.backends.info("Preferences come from the defaults suite \(name, privacy: .public)")
            return defaults
        case .refused(let name):
            // Falling back would write a lane's forced settings into the
            // owner's preferences, which the override exists to prevent.
            Log.backends.fault("Refusing to start: \(LocalvoxtralDefaultsSuite.environmentKey, privacy: .public)=\(name, privacy: .public) is not a usable defaults suite")
            fatalError("\(LocalvoxtralDefaultsSuite.environmentKey)=\(name) is not a usable defaults suite")
        }
    }()
}
