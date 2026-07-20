import Foundation
import XCTest

@testable import localvoxtral

/// The out-of-box defaults a first-time user gets, and — just as important —
/// the ones an existing install must NOT be given behind the user's back.
@MainActor
final class SettingsStoreOutOfBoxDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    private static let onboardingKey = "settings.onboarding_completed"
    private static let legacyBackendModeKey = "settings.backend_mode"
    private static let polishingEnabledKey = "settings.llm_polishing_enabled"
    private static let modifierOnlyKey = "settings.modifier_only_hotkey_enabled"

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.SettingsStoreOutOfBoxDefaultsTests.\(UUID().uuidString)"
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

    func testFreshInstall_enablesTheModifierGesture() {
        let store = makeStore()

        XCTAssertTrue(store.modifierOnlyHotKeyEnabled)
    }

    func testFreshInstall_seedSurvivesOnceTheWizardIsDone() {
        // Completing the wizard persists onboarding as done, so this install
        // stops looking fresh. That is exactly when a fallback-based seed would
        // silently flip the gesture back off — only a WRITTEN seed survives.
        _ = makeStore()
        defaults.set(true, forKey: Self.onboardingKey)  // wizard completed

        let laterLaunch = makeStore()

        XCTAssertTrue(laterLaunch.modifierOnlyHotKeyEnabled)
    }

    func testFreshInstall_leavesPolishingToTheOnboardingWizard() {
        // The wizard enables polishing (consent defaults on) *together with*
        // downloading the model. Seeding it here would strand a user who
        // declines: that path leaves the key unwritten and relies on this
        // fallback, so a seeded `true` would survive as polishing-on with no
        // model on disk.
        let store = makeStore()

        XCTAssertFalse(store.llmPolishingEnabled)
        XCTAssertNil(defaults.object(forKey: Self.polishingEnabledKey))
    }

    func testFreshInstall_leavesTheSurroundingsFeaturesOptIn() {
        // Repo vocabulary and clipboard-as-context feed the user's surroundings
        // to the polisher; they stay a decision the user makes.
        let store = makeStore()

        XCTAssertFalse(store.repoVocabularyEnabled)
        XCTAssertFalse(store.polishClipboardContextEnabled)
        // The endpoint trade is its own opt-in on top of those: fresh installs
        // keep every context surface loopback-only.
        XCTAssertFalse(store.polishContextTrustedEndpointEnabled)
    }

    func testFreshInstall_neverOverwritesAChoiceTheUserAlreadyMade() {
        defaults.set(false, forKey: Self.modifierOnlyKey)

        let store = makeStore()

        XCTAssertFalse(store.modifierOnlyHotKeyEnabled)
    }

    // MARK: - Existing install (an update must change nothing)

    func testExistingInstall_thatCompletedOnboarding_keepsTheGestureOff() {
        defaults.set(true, forKey: Self.onboardingKey)

        let store = makeStore()

        XCTAssertFalse(store.modifierOnlyHotKeyEnabled)
        // Nothing was written on its behalf.
        XCTAssertNil(defaults.object(forKey: Self.modifierOnlyKey))
    }

    func testExistingInstall_interruptedWhileReRunningSetup_keepsTheGestureOff() {
        // "Re-run Setup…" resets the onboarding flag to false on a configured
        // install. If the app then dies before the wizard closes (crash or
        // force-quit — a graceful close completes onboarding), the next launch
        // sees the flag present-and-false. That must NOT read as a fresh
        // install: this user has been here for versions and never asked for the
        // gesture, and taking Right Command from them is exactly what the seed
        // promises never to do.
        defaults.set(false, forKey: Self.onboardingKey)
        defaults.set(BackendMode.managedLocal.rawValue, forKey: Self.legacyBackendModeKey)

        let store = makeStore()

        XCTAssertFalse(store.modifierOnlyHotKeyEnabled)
        XCTAssertNil(defaults.object(forKey: Self.modifierOnlyKey))
    }

    func testExistingInstall_detectedByLegacyBackendModeKey_keepsTheGestureOff() {
        // A pre-onboarding install: no onboarding flag, but configured settings.
        defaults.set(BackendMode.managedLocal.rawValue, forKey: Self.legacyBackendModeKey)

        let store = makeStore()

        XCTAssertFalse(store.modifierOnlyHotKeyEnabled)
    }
}
