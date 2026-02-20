import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class SettingsStoreTests: XCTestCase {

    // MARK: - resolvedWebSocketURL

    func testResolvedURL_wsPassthrough() {
        let store = SettingsStore()
        store.openAIEndpointURL = "ws://127.0.0.1:8000/v1/realtime"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://127.0.0.1:8000/v1/realtime")
    }

    func testResolvedURL_wssPassthrough() {
        let store = SettingsStore()
        store.openAIEndpointURL = "wss://example.com/realtime"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_httpToWs() {
        let store = SettingsStore()
        store.openAIEndpointURL = "http://localhost:8000/v1/realtime"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://localhost:8000/v1/realtime")
    }

    func testResolvedURL_httpsToWss() {
        let store = SettingsStore()
        store.openAIEndpointURL = "https://example.com/realtime"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "wss://example.com/realtime")
    }

    func testResolvedURL_bareHost() {
        let store = SettingsStore()
        store.openAIEndpointURL = "myhost:9000/path"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://myhost:9000/path")
    }

    func testResolvedURL_empty() {
        let store = SettingsStore()
        store.openAIEndpointURL = ""
        store.realtimeProvider = .openAICompatible
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_whitespaceOnly() {
        let store = SettingsStore()
        store.openAIEndpointURL = "   \n  "
        store.realtimeProvider = .openAICompatible
        XCTAssertNil(store.resolvedWebSocketURL)
    }

    func testResolvedURL_trimming() {
        let store = SettingsStore()
        store.openAIEndpointURL = "  ws://example.com  "
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://example.com")
    }

    func testResolvedURL_mlxProviderUsesMlxEndpoint() {
        let store = SettingsStore()
        store.mlxAudioEndpointURL = "ws://mlx-host:5000/transcribe"
        store.openAIEndpointURL = "ws://openai-host:8000/realtime"
        store.realtimeProvider = .mlxAudio
        XCTAssertEqual(store.resolvedWebSocketURL?.absoluteString, "ws://mlx-host:5000/transcribe")
    }

    // MARK: - effectiveModelName

    func testEffectiveModel_plainName() {
        let store = SettingsStore()
        store.openAIModelName = "my-model"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_whitespace_trimmed() {
        let store = SettingsStore()
        store.openAIModelName = "  my-model  "
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.effectiveModelName, "my-model")
    }

    func testEffectiveModel_multiline_takesLastNonEmptyLine() {
        let store = SettingsStore()
        store.openAIModelName = "junk-line\nactual-model"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.effectiveModelName, "actual-model")
    }

    func testEffectiveModel_spacesInLine_takesLastToken() {
        let store = SettingsStore()
        store.openAIModelName = "some prefix model-name"
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(store.effectiveModelName, "model-name")
    }

    func testEffectiveModel_empty_defaultsToProvider() {
        let store = SettingsStore()
        store.openAIModelName = ""
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.openAICompatible.defaultModelName
        )
    }

    func testEffectiveModel_whitespaceOnly_defaultsToProvider() {
        let store = SettingsStore()
        store.openAIModelName = "   \n  "
        store.realtimeProvider = .openAICompatible
        XCTAssertEqual(
            store.effectiveModelName,
            SettingsStore.RealtimeProvider.openAICompatible.defaultModelName
        )
    }
}
