import Foundation
import XCTest
@testable import localvoxtral

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
}
