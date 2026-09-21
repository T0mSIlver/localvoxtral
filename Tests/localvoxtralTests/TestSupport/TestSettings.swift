import XCTest
@testable import localvoxtral

extension XCTestCase {
    /// A `SettingsStore` over a throwaway defaults suite, removed at teardown,
    /// with no environment and no keychain.
    @MainActor
    func makeSettings(outputMode: DictationOutputMode? = nil) -> SettingsStore {
        let suiteName = "localvoxtral.\(type(of: self)).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        if let outputMode {
            settings.dictationOutputMode = outputMode
        }
        return settings
    }
}
