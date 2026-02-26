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

    // MARK: - resolvedWebSocketURL

    func testResolvedURL_wsPassthrough() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "ws://127.0.0.1:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://127.0.0.1:8000/v1/realtime")
    }

    func testResolvedURL_wssPassthrough() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "wss://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_httpToWs() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "http://localhost:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://localhost:8000/v1/realtime")
    }

    func testResolvedURL_httpsToWss() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "https://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_bareHost() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "myhost:9000/path"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://myhost:9000/path")
    }

    func testResolvedURL_empty() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = ""
        store.realtimeProvider = .realtimeAPI
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_whitespaceOnly() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "   \n  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_trimming() {
        let store = makeStore()
        store.realtimeAPIEndpointURL = "  ws://example.com  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://example.com")
    }

    func testResolvedURL_mlxProviderUsesMlxEndpoint() {
        let store = makeStore()
        store.mlxAudioEndpointURL = "ws://mlx-host:5000/transcribe"
        store.realtimeAPIEndpointURL = "ws://openai-host:8000/realtime"
        store.realtimeProvider = .mlxAudio
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://mlx-host:5000/transcribe")
    }

    // MARK: - effectiveModelName

    func testEffectiveModel_plainName() {
        let store = makeStore()
        store.realtimeAPIModelName = "my-model"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_whitespace_trimmed() {
        let store = makeStore()
        store.realtimeAPIModelName = "  my-model  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_multiline_takesLastNonEmptyLine() {
        let store = makeStore()
        store.realtimeAPIModelName = "junk-line\nactual-model"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "actual-model")
    }

    func testEffectiveModel_spacesInLine_takesLastToken() {
        let store = makeStore()
        store.realtimeAPIModelName = "some prefix model-name"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "model-name")
    }

    func testEffectiveModel_empty_defaultsToProvider() {
        let store = makeStore()
        store.realtimeAPIModelName = ""
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    func testEffectiveModel_whitespaceOnly_defaultsToProvider() {
        let store = makeStore()
        store.realtimeAPIModelName = "   \n  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    // MARK: - dictationOutputMode

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

}
