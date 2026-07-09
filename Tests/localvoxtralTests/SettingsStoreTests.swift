import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.SettingsStoreTests.\(UUID().uuidString)"
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

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:])
    }

    // MARK: - Overlay Buffer session reachability

    func testOverlayBufferReachability_truthTable() {
        let store = makeStore()

        // Fresh install: shortcuts mode with the default overlay shortcut.
        XCTAssertTrue(store.isOverlayBufferSessionReachable)

        // Shortcuts mode with the overlay shortcut cleared: unreachable.
        store.modifierOnlyHotKeyEnabled = false
        store.setOverlayBufferShortcut(nil)
        XCTAssertFalse(store.isOverlayBufferSessionReachable)

        // The menu-bar output mode is NOT a trigger (field report 2026-07-06:
        // clearing the shortcut must disable polishing even with the menu-bar
        // mode on Overlay Buffer).
        store.dictationOutputMode = .overlayBuffer
        XCTAssertFalse(store.isOverlayBufferSessionReachable)

        // Each keyboard trigger alone restores reachability.
        store.setOverlayBufferShortcut(SettingsStore.defaultDictationShortcut)
        XCTAssertTrue(store.isOverlayBufferSessionReachable)
        store.setOverlayBufferShortcut(nil)

        store.modifierOnlyHotKeyEnabled = true
        XCTAssertTrue(store.isOverlayBufferSessionReachable)
    }

    // MARK: - resolvedWebSocketURL

    func testResolvedURL_wsPassthrough() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "ws://127.0.0.1:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://127.0.0.1:8000/v1/realtime")
    }

    func testResolvedURL_wssPassthrough() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "wss://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_httpToWs() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "http://localhost:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://localhost:8000/v1/realtime")
    }

    func testResolvedURL_httpsToWss() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "https://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_bareHost() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "myhost:9000/path"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://myhost:9000/path")
    }

    func testResolvedURL_empty() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = ""
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_whitespaceOnly() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "   \n  "
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_trimming() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "  ws://example.com  "
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://example.com")
    }

    // MARK: - realtimeProvider migration

    func testRealtimeProvider_legacyRawValueFallsBackToDefault() {
        // A user who previously selected the now-removed deprecated backend has
        // its raw value persisted in UserDefaults. Decoding must fall back to the
        // default provider instead of crashing or producing an invalid state.
        defaults.set("mlx_audio", forKey: "settings.realtime_provider")

        let store = makeStore()

        XCTAssertEqual(store.realtimeProvider, .realtimeAPI)
    }

    func testRealtimeProvider_unknownRawValueFallsBackToDefault() {
        defaults.set("some_future_provider", forKey: "settings.realtime_provider")

        let store = makeStore()

        XCTAssertEqual(store.realtimeProvider, .realtimeAPI)
    }

    func testRemovedCommitIntervalSettingIsCleanedUp() {
        defaults.set(0.5, forKey: "settings.commit_interval_seconds")

        _ = makeStore()

        XCTAssertNil(defaults.object(forKey: "settings.commit_interval_seconds"))
    }

    // MARK: - per-backend mode migration

    func testBackendModes_freshDefaults_defaultToManagedLocal() {
        let store = makeStore()

        XCTAssertEqual(store.dictationBackendMode, .managedLocal)
        XCTAssertEqual(store.polishingBackendMode, .managedLocal)
    }

    func testBackendModes_freshDefaults_persistManagedLocalImmediately() {
        // The migration heuristic must persist its resolved value on first
        // init so it only ever runs once (a second store on the same defaults
        // must not re-derive from endpoint/env state).
        _ = makeStore()

        XCTAssertEqual(
            defaults.string(forKey: "settings.dictation_backend_mode"),
            BackendMode.managedLocal.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: "settings.polishing_backend_mode"),
            BackendMode.managedLocal.rawValue
        )
        XCTAssertNil(defaults.string(forKey: "settings.backend_mode"))
    }

    func testBackendModes_persistedEndpointKey_migratesToExternalURL() {
        // An existing user who has already configured a realtime endpoint
        // keeps their working external setup.
        defaults.set(
            "ws://127.0.0.1:8000/v1/realtime",
            forKey: "settings.realtime_api_endpoint_url"
        )

        let store = makeStore()

        XCTAssertEqual(store.dictationBackendMode, .externalURL)
        XCTAssertEqual(store.polishingBackendMode, .externalURL)
    }

    func testBackendModes_realtimeEndpointEnv_migratesToExternalURL() {
        // The REALTIME_ENDPOINT env var is also evidence of a pre-existing
        // external setup (e.g. launched from a wrapper script).
        let store = SettingsStore(
            defaults: defaults,
            environment: ["REALTIME_ENDPOINT": "ws://example.com/realtime"]
        )

        XCTAssertEqual(store.dictationBackendMode, .externalURL)
        XCTAssertEqual(store.polishingBackendMode, .externalURL)
    }

    func testBackendModes_legacyStoredValueSeedsBothNewModes() {
        // An explicit stored preference beats the endpoint/env heuristic in
        // both directions. Here a persisted endpoint would normally select
        // external, but an explicit managed_local preference must win.
        defaults.set(
            "ws://127.0.0.1:8000/v1/realtime",
            forKey: "settings.realtime_api_endpoint_url"
        )
        defaults.set("managed_local", forKey: "settings.backend_mode")

        let store = makeStore()

        XCTAssertEqual(store.dictationBackendMode, .managedLocal)
        XCTAssertEqual(store.polishingBackendMode, .managedLocal)
        XCTAssertEqual(defaults.string(forKey: "settings.backend_mode"), "managed_local")
        XCTAssertEqual(defaults.string(forKey: "settings.dictation_backend_mode"), "managed_local")
        XCTAssertEqual(defaults.string(forKey: "settings.polishing_backend_mode"), "managed_local")
    }

    func testBackendModes_roundTripIndependentlyAcrossReload() {
        let store = makeStore()
        store.dictationBackendMode = .externalURL
        store.polishingBackendMode = .managedLocal

        XCTAssertEqual(
            defaults.string(forKey: "settings.dictation_backend_mode"),
            "external_url"
        )
        XCTAssertEqual(
            defaults.string(forKey: "settings.polishing_backend_mode"),
            "managed_local"
        )

        let reloadedStore = makeStore()
        XCTAssertEqual(reloadedStore.dictationBackendMode, .externalURL)
        XCTAssertEqual(reloadedStore.polishingBackendMode, .managedLocal)
    }

    // MARK: - per-backend mode-dependent resolution

    func testResolvedWebSocketURL_managedLocal_returnsManagedEndpoint() {
        // A fresh store is managed; the user-typed endpoint must be ignored.
        let store = makeStore()
        store.realtimeAPIEndpointURL = "ws://example.com/realtime"

        XCTAssertEqual(
            store.resolvedWebSocketURL?.absoluteString,
            ManagedBackendEndpoints.realtimeURLString
        )
    }

    func testEffectiveModelName_managedLocal_returnsManagedDefaultIgnoringOverride() {
        let store = makeStore()
        store.realtimeAPIModelName = "user-typed-override"

        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    func testTrimmedAPIKey_managedLocal_isEmpty() {
        // Managed local servers need no bearer token; trimmedAPIKey is only
        // the realtime connection bearer token.
        let store = makeStore()
        store.apiKey = "sk-managed-should-be-ignored"

        XCTAssertEqual(store.trimmedAPIKey, "")
    }

    func testTrimmedAPIKey_externalURL_returnsApiKey() {
        let store = makeStore()
        store.dictationBackendMode = .externalURL
        store.apiKey = "  sk-external  "

        XCTAssertEqual(store.trimmedAPIKey, "sk-external")
    }

    func testLLMPolishingConfiguration_managedLocal_returnsManagedEndpointAndEmptyKey() {
        let store = makeStore()
        store.llmPolishingEnabled = true
        // External-mode fields (endpoint, key, and the server-side model NAME)
        // must never leak into a managed configuration; managed mode has its
        // own HF-repo selection.
        store.llmPolishingEndpointURL = "https://api.openai.com/v1/chat/completions"
        store.llmPolishingAPIKey = "sk-ignored"
        store.llmPolishingModel = "gpt-4o-mini"

        let configuration = store.llmPolishingConfiguration
        XCTAssertEqual(
            configuration?.endpointURL.absoluteString,
            ManagedBackendEndpoints.polishingURLString
        )
        XCTAssertEqual(configuration?.apiKey, "")
        XCTAssertEqual(configuration?.model, SettingsStore.defaultLLMPolishingModel)
        XCTAssertNil(configuration?.samplingDefaults)
    }

    func testLLMPolishingConfiguration_managedLocal_usesManagedModelSelection() {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.managedLLMPolishingModel = "mlx-community/custom-polisher"

        let configuration = store.llmPolishingConfiguration
        XCTAssertEqual(configuration?.model, "mlx-community/custom-polisher")
        // A non-catalog repo carries no catalog sampling defaults.
        XCTAssertNil(configuration?.samplingDefaults)
    }

    func testLLMPolishingConfiguration_managedLocal_disabledReturnsNil() {
        let store = makeStore()
        store.llmPolishingEnabled = false

        XCTAssertNil(store.llmPolishingConfiguration)
    }

    func testLLMPolishingConfiguration_externalURL_usesConfiguredEndpoint() {
        let store = makeStore()
        store.polishingBackendMode = .externalURL
        store.llmPolishingEnabled = true
        store.llmPolishingEndpointURL = "https://api.openai.com/v1/chat/completions"
        store.llmPolishingAPIKey = "sk-test"
        store.llmPolishingModel = "gpt-4o-mini"

        let configuration = store.llmPolishingConfiguration
        XCTAssertEqual(
            configuration?.endpointURL.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(configuration?.apiKey, "sk-test")
        XCTAssertEqual(configuration?.model, "gpt-4o-mini")
        XCTAssertNil(configuration?.samplingDefaults)
    }

    func testBackendResolutionUsesIndependentDictationAndPolishingModes() {
        let combinations: [(BackendMode, BackendMode)] = [
            (.managedLocal, .managedLocal),
            (.managedLocal, .externalURL),
            (.externalURL, .managedLocal),
            (.externalURL, .externalURL),
        ]

        for (dictationMode, polishingMode) in combinations {
            let store = makeStore()
            store.dictationBackendMode = dictationMode
            store.polishingBackendMode = polishingMode
            store.realtimeAPIEndpointURL = "ws://external.example/v1/realtime"
            store.realtimeAPIModelName = "external-realtime-model"
            store.apiKey = "  sk-realtime  "
            store.llmPolishingEnabled = true
            store.llmPolishingEndpointURL = "https://polish.example/v1/chat/completions"
            store.llmPolishingAPIKey = "  sk-polish  "
            store.llmPolishingModel = "external-polish-model"

            let expectedRealtimeURL = dictationMode == .managedLocal
                ? ManagedBackendEndpoints.realtimeURLString
                : "ws://external.example/v1/realtime"
            XCTAssertEqual(
                store.resolvedWebSocketURL?.absoluteString,
                expectedRealtimeURL,
                "dictation=\(dictationMode.rawValue) polishing=\(polishingMode.rawValue)"
            )
            XCTAssertEqual(
                store.effectiveModelName,
                dictationMode == .managedLocal
                    ? SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
                    : "external-realtime-model"
            )
            XCTAssertEqual(
                store.trimmedAPIKey,
                dictationMode == .managedLocal ? "" : "sk-realtime"
            )

            let configuration = store.llmPolishingConfiguration
            XCTAssertEqual(
                configuration?.endpointURL.absoluteString,
                polishingMode == .managedLocal
                    ? ManagedBackendEndpoints.polishingURLString
                    : "https://polish.example/v1/chat/completions"
            )
            XCTAssertEqual(configuration?.apiKey, polishingMode == .managedLocal ? "" : "sk-polish")
            XCTAssertEqual(
                configuration?.model,
                polishingMode == .managedLocal
                    ? SettingsStore.defaultLLMPolishingModel
                    : "external-polish-model"
            )
        }
    }

    // MARK: - effectiveModelName

    func testEffectiveModel_plainName() {
        let store = makeStore()
        store.realtimeAPIModelName = "my-model"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_whitespace_trimmed() {
        let store = makeStore()
        store.realtimeAPIModelName = "  my-model  "
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_multiline_takesLastNonEmptyLine() {
        let store = makeStore()
        store.realtimeAPIModelName = "junk-line\nactual-model"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.effectiveModelName, "actual-model")
    }

    func testEffectiveModel_spacesInLine_takesLastToken() {
        let store = makeStore()
        store.realtimeAPIModelName = "some prefix model-name"
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(store.effectiveModelName, "model-name")
    }

    func testEffectiveModel_empty_defaultsToProvider() {
        let store = makeStore()
        store.realtimeAPIModelName = ""
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    func testEffectiveModel_whitespaceOnly_defaultsToProvider() {
        let store = makeStore()
        store.realtimeAPIModelName = "   \n  "
        store.realtimeProvider = .realtimeAPI
        store.dictationBackendMode = .externalURL
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    func testRealtimeProviderDefaultEndpointsMatchToolDefaults() {
        XCTAssertEqual(
            SettingsStore.RealtimeProvider.realtimeAPI.defaultEndpoint,
            "ws://127.0.0.1:8000/v1/realtime"
        )
    }

    // MARK: - dictationOutputMode

    // MARK: - agentPolishProfileEnabled

    func testAgentPolishProfileEnabled_defaultsToTrue() {
        let store = makeStore()
        XCTAssertTrue(store.agentPolishProfileEnabled)
    }

    func testAgentPolishProfileEnabled_persistsAcrossReload() {
        let store = makeStore()
        store.agentPolishProfileEnabled = false

        let reloadedStore = makeStore()
        XCTAssertFalse(reloadedStore.agentPolishProfileEnabled)
    }

    func testDictationOutputMode_defaultsToOverlayBuffer() {
        let store = makeStore()
        XCTAssertEqual(store.dictationOutputMode, .overlayBuffer)
    }

    func testDictationOutputMode_persistsAcrossReload() {
        let store = makeStore()
        store.dictationOutputMode = .liveAutoPaste

        let reloadedStore = makeStore()
        XCTAssertEqual(reloadedStore.dictationOutputMode, .liveAutoPaste)
    }

    func testDictationOutputMode_legacyAutoPasteFlagDoesNotChangeDefaultMode() {
        defaults.set(false, forKey: "settings.auto_paste_into_input_field_enabled")
        let store = makeStore()
        XCTAssertEqual(store.dictationOutputMode, .overlayBuffer)
    }

    // MARK: - dictationShortcutMode

    func testDictationShortcutMode_defaultsToToggle() {
        let store = makeStore()
        XCTAssertEqual(store.dictationShortcutMode, .toggle)
    }

    func testDictationShortcutMode_persistsAcrossReload() {
        let store = makeStore()
        store.dictationShortcutMode = .pushToTalk

        let reloadedStore = makeStore()
        XCTAssertEqual(reloadedStore.dictationShortcutMode, .pushToTalk)
    }

    func testDictationShortcutMode_invalidStoredValueFallsBackToToggle() {
        defaults.set("invalid_mode", forKey: "settings.dictation_shortcut_mode")

        let store = makeStore()

        XCTAssertEqual(store.dictationShortcutMode, .toggle)
    }

    // MARK: - dictationShortcut

    func testDictationShortcut_defaultsToEnabledOptionSpace() {
        let store = makeStore()
        let expectedDefault = DictationShortcut(
            keyCode: UInt32(kVK_Space),
            carbonModifierFlags: UInt32(optionKey)
        )
        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(SettingsStore.defaultDictationShortcut, expectedDefault)
        XCTAssertEqual(store.dictationShortcut, expectedDefault)
    }

    func testDictationShortcut_customPersistsAcrossReload() {
        let store = makeStore()
        let customShortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
        )

        store.setDictationShortcut(customShortcut)
        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, customShortcut)

        let reloadedStore = makeStore()
        XCTAssertTrue(reloadedStore.dictationShortcutEnabled)
        XCTAssertEqual(reloadedStore.dictationShortcut, customShortcut)
    }

    func testDictationShortcut_clearDisablesAndPersists() {
        let store = makeStore()

        store.setDictationShortcut(nil)
        XCTAssertFalse(store.dictationShortcutEnabled)
        XCTAssertNil(store.dictationShortcut)

        let reloadedStore = makeStore()
        XCTAssertFalse(reloadedStore.dictationShortcutEnabled)
        XCTAssertNil(reloadedStore.dictationShortcut)
    }

    func testDictationShortcut_resetRestoresDefault() {
        let store = makeStore()
        let customShortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
        )
        store.setDictationShortcut(customShortcut)

        store.resetDictationShortcutToDefault()

        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, SettingsStore.defaultDictationShortcut)
    }

    func testDictationShortcut_invalidStoredValueFallsBackToDefault() {
        defaults.set(true, forKey: "settings.dictation_shortcut_enabled")
        defaults.set(UInt32.max, forKey: "settings.dictation_shortcut_key_code")
        defaults.set(0, forKey: "settings.dictation_shortcut_carbon_modifiers")

        let store = makeStore()

        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, SettingsStore.defaultDictationShortcut)
    }

    // MARK: - dual shortcut migration

    func testLegacyDictationShortcutMigratesToOverlayBufferShortcut() {
        let legacyShortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
        )
        defaults.set(true, forKey: "settings.dictation_shortcut_enabled")
        defaults.set(legacyShortcut.keyCode, forKey: "settings.dictation_shortcut_key_code")
        defaults.set(
            legacyShortcut.carbonModifierFlags,
            forKey: "settings.dictation_shortcut_carbon_modifiers"
        )

        let store = makeStore()

        XCTAssertEqual(store.overlayBufferShortcut, legacyShortcut)
        XCTAssertNil(store.livePasteShortcut)
        XCTAssertEqual(
            (defaults.object(forKey: "settings.overlay_buffer_shortcut_key_code") as? NSNumber)?
                .uint32Value,
            legacyShortcut.keyCode
        )
        XCTAssertEqual(
            (
                defaults.object(forKey: "settings.overlay_buffer_shortcut_carbon_modifiers")
                    as? NSNumber
            )?.uint32Value,
            legacyShortcut.carbonModifierFlags
        )
        XCTAssertTrue(defaults.bool(forKey: "settings.overlay_buffer_shortcut_enabled"))
    }

    func testDisabledLegacyDictationShortcutMigratesToDisabledOverlayShortcut() {
        let legacyShortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_F),
            carbonModifierFlags: UInt32(controlKey | optionKey)
        )
        defaults.set(false, forKey: "settings.dictation_shortcut_enabled")
        defaults.set(legacyShortcut.keyCode, forKey: "settings.dictation_shortcut_key_code")
        defaults.set(
            legacyShortcut.carbonModifierFlags,
            forKey: "settings.dictation_shortcut_carbon_modifiers"
        )

        let store = makeStore()

        XCTAssertNil(store.overlayBufferShortcut)
        XCTAssertFalse(defaults.bool(forKey: "settings.overlay_buffer_shortcut_enabled"))
        XCTAssertNil(store.livePasteShortcut)
    }

    // MARK: - llmPolishingConfiguration

    func testLLMPolishingConfiguration_disabledReturnsNil() {
        let store = makeStore()
        store.llmPolishingEnabled = false
        store.llmPolishingEndpointURL = "https://api.openai.com/v1/chat/completions"

        XCTAssertNil(store.llmPolishingConfiguration)
    }

    func testLLMPolishingConfiguration_invalidEndpointReturnsNil() {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.llmPolishingEndpointURL = "not a url"
        store.polishingBackendMode = .externalURL

        XCTAssertNil(store.llmPolishingConfiguration)
    }

    func testLLMPolishingConfiguration_validEndpointBuildsConfiguration() {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.llmPolishingEndpointURL = "https://api.openai.com/v1/chat/completions"
        store.llmPolishingAPIKey = "  sk-test  "
        store.llmPolishingModel = "  gpt-4o-mini  "
        store.polishingBackendMode = .externalURL

        let configuration = store.llmPolishingConfiguration
        XCTAssertEqual(
            configuration?.endpointURL.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(configuration?.apiKey, "sk-test")
        XCTAssertEqual(configuration?.model, "gpt-4o-mini")
    }

    func testLLMPolishingEndpointDefaultsToMLXLMPort() {
        let store = makeStore()

        XCTAssertEqual(store.llmPolishingEndpointURL, "http://127.0.0.1:8080/v1/chat/completions")
    }

    // MARK: - replacementDictionaryEnabled

    func testReplacementDictionaryEnabled_defaultsToFalse() {
        let store = makeStore()

        XCTAssertFalse(store.replacementDictionaryEnabled)
    }

    func testReplacementDictionaryEnabled_persistsAcrossReload() {
        let store = makeStore()
        store.replacementDictionaryEnabled = true

        let reloadedStore = makeStore()
        XCTAssertTrue(reloadedStore.replacementDictionaryEnabled)
    }

    // MARK: - debugLogRealtimeDeltas (issue #13 instrumentation)

    func testDebugLogRealtimeDeltas_defaultsToFalse() {
        // The hidden instrumentation toggle must be off by default so no
        // dictated content is ever logged unless explicitly opted in.
        let store = makeStore()

        XCTAssertFalse(store.debugLogRealtimeDeltas)
    }

    func testDebugLogRealtimeDeltas_persistsAcrossReloadUnderDocumentedKey() {
        // The reporter enables capture via `defaults write com.localvoxtral.app
        // debug.log_realtime_deltas -bool true`. Verify the round-trips under
        // exactly that key and survives a store reload.
        defaults.set(true, forKey: "debug.log_realtime_deltas")

        let store = makeStore()
        XCTAssertTrue(store.debugLogRealtimeDeltas)

        // And a set through the property must persist under the same key.
        store.debugLogRealtimeDeltas = false
        XCTAssertEqual(defaults.bool(forKey: "debug.log_realtime_deltas"), false)

        let reloadedStore = makeStore()
        XCTAssertFalse(reloadedStore.debugLogRealtimeDeltas)
    }

}
