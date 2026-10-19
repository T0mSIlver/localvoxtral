import Foundation
import XCTest

@testable import localvoxtral

/// Anthropic API polishing (#1895): the request the mode builds, the key an
/// External URL setup already held, the dictation picker that never offers
/// it, and the repair guide that only Anthropic requests carry.
@MainActor
final class AnthropicAPIModeTests: XCTestCase {
    func testAnthropicModeBuildsAMessagesRequestWithTheDefaultModel() throws {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .anthropicAPI
        settings.anthropicAPIKey = "  sk-ant-test  "

        let configuration = try XCTUnwrap(settings.llmPolishingConfiguration)
        XCTAssertEqual(configuration.requestShape, .anthropic)
        XCTAssertEqual(configuration.requestURL.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(configuration.apiKey, "sk-ant-test")
        XCTAssertEqual(configuration.model, "claude-haiku-5-5")
    }

    func testAnthropicModeWithoutAKeySendsNothing() {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .anthropicAPI

        XCTAssertNil(settings.llmPolishingConfiguration)
    }

    func testSwitchingToAnthropicCarriesTheExternalAnthropicKeyAndModel() throws {
        let (engines, settings) = makeEngines()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = "https://api.anthropic.com"
        settings.llmPolishingAPIKey = "sk-ant-external"
        settings.llmPolishingModel = "claude-sonnet-5-5"

        engines.applyPolishingBackendModeChange(.anthropicAPI)

        let configuration = try XCTUnwrap(settings.llmPolishingConfiguration)
        XCTAssertEqual(configuration.apiKey, "sk-ant-external")
        XCTAssertEqual(configuration.model, "claude-sonnet-5-5")
    }

    func testSwitchingToAnthropicKeepsAKeyTypedForTheMode() {
        let (engines, settings) = makeEngines()
        settings.llmPolishingEndpointURL = "https://api.anthropic.com"
        settings.llmPolishingAPIKey = "sk-ant-external"
        settings.anthropicAPIKey = "sk-ant-own"

        engines.applyPolishingBackendModeChange(.anthropicAPI)

        XCTAssertEqual(settings.anthropicAPIKey, "sk-ant-own")
    }

    func testSwitchingToAnthropicIgnoresAnotherServersKey() {
        let (engines, settings) = makeEngines()
        settings.llmPolishingEndpointURL = "https://openrouter.ai/api"
        settings.llmPolishingAPIKey = "sk-or-key"

        engines.applyPolishingBackendModeChange(.anthropicAPI)

        XCTAssertEqual(settings.anthropicAPIKey, "")
    }

    func testAStoredAnthropicDictationModeReadsAsUnset() {
        let suiteName = "localvoxtral.AnthropicAPIModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("anthropic_api", forKey: "settings.dictation_backend_mode")
        defaults.set("anthropic_api", forKey: "settings.polishing_backend_mode")

        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())

        XCTAssertNotEqual(settings.dictationBackendMode, .anthropicAPI)
        XCTAssertEqual(settings.polishingBackendMode, .anthropicAPI)
        XCTAssertFalse(BackendMode.dictationModes.contains(.anthropicAPI))
    }

    func testOnlyAnAnthropicRequestCarriesTheRepairGuide() {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        let store = MockAppConfigStore()
        func systemPrompt() -> String {
            StopCommitCoordinator.promptTemplates(
                profile: .agent, settings: settings, appConfigStore: store, projectNames: []
            ).systemContent
        }

        settings.polishingBackendMode = .mistralAPI
        settings.mistralAPIKey = "mk"
        XCTAssertFalse(systemPrompt().contains(PolishRepairGuide.systemSection))

        settings.polishingBackendMode = .anthropicAPI
        settings.anthropicAPIKey = "sk-ant"
        XCTAssertTrue(systemPrompt().contains(PolishRepairGuide.systemSection))
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.AnthropicAPIModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.onboardingCompleted = true
        return settings
    }

    private func makeEngines() -> (EnginesModel, SettingsStore) {
        let settings = makeSettings()
        let engines = EnginesModel(
            settings: settings,
            backendManager: OnboardingTestBackendManager(),
            localNetworkPermissionPreflight: RecordingLocalNetworkPermissionPreflight()
        )
        return (engines, settings)
    }
}
