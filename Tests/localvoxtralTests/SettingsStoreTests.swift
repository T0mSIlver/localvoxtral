import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class SettingsStoreTests: XCTestCase {

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
}
