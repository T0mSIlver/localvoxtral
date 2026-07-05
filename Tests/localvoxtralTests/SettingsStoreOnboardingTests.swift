import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class SettingsStoreOnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    private static let onboardingKey = "settings.onboarding_completed"
    private static let legacyBackendModeKey = "settings.backend_mode"
    private static let realtimeEndpointKey = "settings.realtime_api_endpoint_url"
    private static let dictationModeKey = "settings.dictation_backend_mode"
    private static let polishingModeKey = "settings.polishing_backend_mode"

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.SettingsStoreOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    private func makeStore(environment: [String: String] = [:]) -> SettingsStore {
        SettingsStore(defaults: defaults, environment: environment)
    }

    // MARK: - Fresh install

    func testFreshInstall_showsWizard_andPersistsFalse() {
        let store = makeStore()

        XCTAssertFalse(store.onboardingCompleted)
        // Resolution must run before the backend-mode migration writes the new
        // mode keys, and must persist immediately.
        XCTAssertEqual(defaults.object(forKey: Self.onboardingKey) as? Bool, false)
    }

    func testFreshInstall_resolutionRunsBeforeModeKeysArePersisted() {
        // A first store on fresh defaults must stay `false`; if resolution read
        // the mode keys *after* the migration persisted them, a second store
        // would (wrongly) see them and skip. Assert the first store is false and
        // the second honors the now-stored false.
        let first = makeStore()
        XCTAssertFalse(first.onboardingCompleted)

        let second = makeStore()
        XCTAssertFalse(second.onboardingCompleted)
    }

    // MARK: - Stored flag wins

    func testStoredTrue_isHonored() {
        defaults.set(true, forKey: Self.onboardingKey)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    func testStoredFalse_isHonoredEvenWithExistingInstallSignals() {
        // An explicit stored value beats the freshness heuristic in both
        // directions: a re-run (flag reset to false) must show the wizard even
        // on a configured install.
        defaults.set(false, forKey: Self.onboardingKey)
        defaults.set("external_url", forKey: Self.legacyBackendModeKey)

        XCTAssertFalse(makeStore().onboardingCompleted)
    }

    // MARK: - Existing-install signals skip the wizard

    func testLegacyBackendModeKeyPresent_skipsWizard() {
        defaults.set("managed_local", forKey: Self.legacyBackendModeKey)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    func testRealtimeEndpointKeyPresent_skipsWizard() {
        defaults.set("ws://127.0.0.1:8000/v1/realtime", forKey: Self.realtimeEndpointKey)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    func testRealtimeEndpointEnvPresent_skipsWizard() {
        let store = makeStore(environment: ["REALTIME_ENDPOINT": "ws://example.com/realtime"])

        XCTAssertTrue(store.onboardingCompleted)
    }

    func testDictationModeKeyPresent_skipsWizard() {
        defaults.set("managed_local", forKey: Self.dictationModeKey)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    func testPolishingModeKeyPresent_skipsWizard() {
        defaults.set("external_url", forKey: Self.polishingModeKey)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    // MARK: - Persistence round-trip

    func testResolvedValuePersistsAcrossReload() {
        // Fresh → false, then completing the wizard flips + persists true.
        let store = makeStore()
        XCTAssertFalse(store.onboardingCompleted)

        store.onboardingCompleted = true
        XCTAssertEqual(defaults.object(forKey: Self.onboardingKey) as? Bool, true)

        XCTAssertTrue(makeStore().onboardingCompleted)
    }
}
