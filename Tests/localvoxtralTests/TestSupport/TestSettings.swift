import XCTest
@testable import localvoxtral

extension XCTestCase {
    /// A `SettingsStore` over a throwaway defaults suite, removed at teardown,
    /// with no environment and no keychain.
    @MainActor
    func makeSettings(outputMode: DictationOutputMode? = nil) -> SettingsStore {
        let settings = SettingsStore(
            defaults: makeSettingsDefaults(),
            environment: [:],
            secretStore: InMemorySecretStore()
        )
        if let outputMode {
            settings.dictationOutputMode = outputMode
        }
        return settings
    }

    /// The same throwaway suite on its own, for a test that has to build two
    /// stores over one set of defaults (proving what survives a relaunch).
    @MainActor
    func makeSettingsDefaults() -> UserDefaults {
        let suiteName = "localvoxtral.\(type(of: self)).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// A store over defaults from `makeSettingsDefaults()`.
    @MainActor
    func makeSettings(defaults: UserDefaults) -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
    }
}
