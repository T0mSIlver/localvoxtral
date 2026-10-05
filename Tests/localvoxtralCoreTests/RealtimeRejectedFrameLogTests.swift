import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if DEBUG
/// A frame the client cannot read is logged to Backends whether or not debug
/// logging is on, by kind and size only, never by content (#1691).
final class RealtimeRejectedFrameLogTests: XCTestCase {
    private let urlSession = URLSession(configuration: .ephemeral)

    override func tearDown() {
        urlSession.invalidateAndCancel()
        super.tearDown()
    }

    private func makeConnectedClient() -> (RealtimeAPIWebSocketClient, LockedBox<[String]>, LockedBox<[RealtimeEvent]>) {
        let client = RealtimeAPIWebSocketClient()
        let lines = LockedBox<[String]>([])
        let events = LockedBox<[RealtimeEvent]>([])
        client.debugObserveRejectedFrameLog { line in lines.mutate { $0.append(line) } }
        client.setEventHandler { event, _ in events.mutate { $0.append(event) } }
        let task = urlSession.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/v1/realtime")!)
        client.debugPrimeConnectedStateForTesting(task: task, hasReceivedSessionCreated: true)
        addTeardownBlock {
            client.debugObserveRejectedFrameLog(nil)
            client.disconnect()
        }
        return (client, lines, events)
    }

    func testEachRejectedFrameLogsItsKindAndSizeButNotItsContents() {
        let (client, lines, events) = makeConnectedClient()
        let secret = "secret-words"

        client.debugHandleMessageForTesting(.string("{\"type\": \(secret)"))
        client.debugHandleMessageForTesting(.string("[\"\(secret)\"]"))
        client.debugHandleMessageForTesting(.data(Data([0xFF, 0xFE, 0x73, 0x65])))
        client.debugHandleFrameForTesting(json: ["type": "transcription.done", "text": "kept"])

        let generation = client.connectionGeneration.description
        XCTAssertEqual(lines.value, [
            "realtime connection \(generation) rejected a text frame that is not JSON, 21 bytes",
            "realtime connection \(generation) rejected a JSON frame that is not an object, 16 bytes",
            "realtime connection \(generation) rejected a binary frame that is not UTF-8, 4 bytes",
        ])
        XCTAssertFalse(lines.value.contains { $0.contains(secret) })
        let finals = events.value.compactMap { event -> String? in
            guard case .finalTranscript(let text) = event else { return nil }
            return text
        }
        XCTAssertEqual(finals, ["kept"], "a valid frame after the rejected ones still transcribes")
    }

    func testAServerSendingOnlyGarbageCannotFloodTheLog() {
        let (client, lines, _) = makeConnectedClient()

        for _ in 0 ..< 50 {
            client.debugHandleMessageForTesting(.string("not json"))
        }

        let limit = BaseRealtimeWebSocketClient.rejectedFrameLogLimit
        XCTAssertEqual(lines.value.count, limit + 1)
        XCTAssertEqual(
            lines.value.last,
            "realtime connection \(client.connectionGeneration.description) rejected more than \(limit) frames; the rest go unlogged"
        )
    }
}
#endif
