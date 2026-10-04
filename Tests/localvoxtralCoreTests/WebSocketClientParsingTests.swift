import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import localvoxtralCore

final class WebSocketClientParsingTests: XCTestCase {

    private func makeClient() -> RealtimeAPIWebSocketClient {
        RealtimeAPIWebSocketClient()
    }

    // MARK: - findString

    func testFindString_directKeyMatch() {
        let client = makeClient()
        let dict: [String: Any] = ["text": "hello world"]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertEqual(result, "hello world")
    }

    func testFindString_emptyStringSkipped() {
        let client = makeClient()
        let dict: [String: Any] = ["text": ""]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertNil(result)
    }

    func testFindString_keyNotPresent() {
        let client = makeClient()
        let dict: [String: Any] = ["name": "value"]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertNil(result)
    }

    func testFindString_multipleKeysInPriorityList() {
        let client = makeClient()
        let dict: [String: Any] = ["transcript": "found it"]
        let result = client.findString(in: dict, matching: ["text", "transcript", "delta"])
        XCTAssertEqual(result, "found it")
    }

    func testFindString_nestedDict() {
        let client = makeClient()
        let dict: [String: Any] = [
            "response": [
                "output": [
                    "text": "nested value"
                ] as [String: Any]
            ] as [String: Any]
        ]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertEqual(result, "nested value")
    }

    func testFindString_arrayOfDicts() {
        let client = makeClient()
        let dict: [String: Any] = [
            "items": [
                ["id": 1] as [String: Any],
                ["text": "array value"] as [String: Any],
            ] as [Any]
        ]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertEqual(result, "array value")
    }

    func testFindString_emptyDict() {
        let client = makeClient()
        let dict: [String: Any] = [:]
        let result = client.findString(in: dict, matching: ["text"])
        XCTAssertNil(result)
    }

    func testFindString_nonContainerRoot() {
        let client = makeClient()
        let value: Any = "just a string"
        let result = client.findString(in: value, matching: ["text"])
        XCTAssertNil(result)
    }

    func testFindString_keyPriorityUsesInputOrderWhenMultipleKeysPresent() {
        let client = makeClient()
        let dict: [String: Any] = [
            "delta": "prefer me for partials",
            "text": "fallback text",
            "transcript": "fallback transcript",
        ]

        let result = client.findString(in: dict, matching: ["delta", "text", "transcript"])
        XCTAssertEqual(result, "prefer me for partials")
    }

    // MARK: - HTTP-level upgrade rejections

    /// An OpenAI-compatible server that refuses the upgrade with 401, 403 or
    /// 429 surfaces as a bare -1011, which reads as a wrong path; the status
    /// on the task's response names the real cause.
    func testARejectedUpgradeIsClassifiedByItsHTTPStatus() {
        let raw = "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1011]"
        let expected: [(Int?, RealtimeConnectionFailureKind)] = [
            (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (nil, .endpointRejected),
        ]
        for (status, kind) in expected {
            let message = RealtimeAPIWebSocketClient.terminalErrorMessage(errorMessage: raw, httpStatusCode: status)
            XCTAssertEqual(
                RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message), kind,
                "HTTP \(status.map(String.init) ?? "none"): \(message ?? "nil")"
            )
        }
        XCTAssertNil(RealtimeAPIWebSocketClient.terminalErrorMessage(errorMessage: nil, httpStatusCode: 401))
    }
}
