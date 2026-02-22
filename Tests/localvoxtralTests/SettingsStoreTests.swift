import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class SettingsStoreTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let settingsKeys = [
        "settings.realtime_provider",
        "settings.realtime_api_endpoint_url",
        "settings.mlx_audio_endpoint_url",
        "settings.api_key",
        "settings.realtime_api_model_name",
        "settings.mlx_audio_model_name",
        "settings.commit_interval_seconds",
        "settings.mlx_audio_transcription_delay_ms",
        "settings.auto_copy_enabled",
        "settings.selected_input_device_uid",
        "settings.dictation_shortcut_enabled",
        "settings.dictation_shortcut_key_code",
        "settings.dictation_shortcut_carbon_modifiers",
    ]

    override func setUp() async throws {
        try await super.setUp()
        clearSettingsDefaults()
    }

    override func tearDown() async throws {
        clearSettingsDefaults()
        try await super.tearDown()
    }

    // MARK: - resolvedWebSocketURL

    func testResolvedURL_wsPassthrough() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "ws://127.0.0.1:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://127.0.0.1:8000/v1/realtime")
    }

    func testResolvedURL_wssPassthrough() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "wss://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_httpToWs() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "http://localhost:8000/v1/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://localhost:8000/v1/realtime")
    }

    func testResolvedURL_httpsToWss() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "https://example.com/realtime"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_bareHost() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "myhost:9000/path"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://myhost:9000/path")
    }

    func testResolvedURL_empty() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = ""
        store.realtimeProvider = .realtimeAPI
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_whitespaceOnly() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "   \n  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_trimming() {
        let store = SettingsStore()
        store.realtimeAPIEndpointURL = "  ws://example.com  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://example.com")
    }

    func testResolvedURL_mlxProviderUsesMlxEndpoint() {
        let store = SettingsStore()
        store.mlxAudioEndpointURL = "ws://mlx-host:5000/transcribe"
        store.realtimeAPIEndpointURL = "ws://openai-host:8000/realtime"
        store.realtimeProvider = .mlxAudio
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://mlx-host:5000/transcribe")
    }

    // MARK: - effectiveModelName

    func testEffectiveModel_plainName() {
        let store = SettingsStore()
        store.realtimeAPIModelName = "my-model"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_whitespace_trimmed() {
        let store = SettingsStore()
        store.realtimeAPIModelName = "  my-model  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_multiline_takesLastNonEmptyLine() {
        let store = SettingsStore()
        store.realtimeAPIModelName = "junk-line\nactual-model"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "actual-model")
    }

    func testEffectiveModel_spacesInLine_takesLastToken() {
        let store = SettingsStore()
        store.realtimeAPIModelName = "some prefix model-name"
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(store.effectiveModelName, "model-name")
    }

    func testEffectiveModel_empty_defaultsToProvider() {
        let store = SettingsStore()
        store.realtimeAPIModelName = ""
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    func testEffectiveModel_whitespaceOnly_defaultsToProvider() {
        let store = SettingsStore()
        store.realtimeAPIModelName = "   \n  "
        store.realtimeProvider = .realtimeAPI
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName
        )
    }

    // MARK: - dictationShortcut

    func testDictationShortcut_defaultsToEnabledCmdOptionSpace() {
        let store = SettingsStore()
        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, SettingsStore.defaultDictationShortcut)
    }

    func testDictationShortcut_customPersistsAcrossReload() {
        let store = SettingsStore()
        let customShortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
        )

        store.setDictationShortcut(customShortcut)
        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, customShortcut)

        let reloadedStore = SettingsStore()
        XCTAssertTrue(reloadedStore.dictationShortcutEnabled)
        XCTAssertEqual(reloadedStore.dictationShortcut, customShortcut)
    }

    func testDictationShortcut_clearDisablesAndPersists() {
        let store = SettingsStore()

        store.setDictationShortcut(nil)
        XCTAssertFalse(store.dictationShortcutEnabled)
        XCTAssertNil(store.dictationShortcut)

        let reloadedStore = SettingsStore()
        XCTAssertFalse(reloadedStore.dictationShortcutEnabled)
        XCTAssertNil(reloadedStore.dictationShortcut)
    }

    func testDictationShortcut_resetRestoresDefault() {
        let store = SettingsStore()
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

        let store = SettingsStore()

        XCTAssertTrue(store.dictationShortcutEnabled)
        XCTAssertEqual(store.dictationShortcut, SettingsStore.defaultDictationShortcut)
    }

    private func clearSettingsDefaults() {
        for key in settingsKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
