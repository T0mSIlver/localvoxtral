import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// A client that sends dictated text or context follows a redirect only within
/// the origin it was sent to: the destination gate approves the configured URL,
/// and a 307 resends the body to wherever the server points.
final class SameOriginHTTPTests: XCTestCase {
    /// Counts requests as they arrive, before the reply goes out.
    private final class Hits: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func record() -> Int {
            count.withLock { $0 += 1 }
            return 200
        }
    }

    /// `configured` answers 307 to `elsewhere`, a different port and so a
    /// different origin.
    private func redirectPair() throws -> (configured: FakeOpencodePromptRelay, elsewhere: FakeOpencodePromptRelay, hits: Hits) {
        let hits = Hits()
        let elsewhere = try FakeOpencodePromptRelay(status: { _ in hits.record() })
        let target = "http://127.0.0.1:\(elsewhere.port)/v1/chat/completions"
        let configured = try FakeOpencodePromptRelay(status: { _ in 307 }, location: { _ in target })
        addTeardownBlock {
            configured.stop()
            elsewhere.stop()
        }
        return (configured, elsewhere, hits)
    }

    func testFirstDraftRedirectCannotCarryCaptureToAnotherOrigin() async throws {
        let (configured, _, hits) = try redirectPair()
        let drafter = QuickCaptureFirstDrafter(
            endpoint: URL(string: "http://127.0.0.1:\(configured.port)/v1/chat/completions")!,
            apiKey: "", model: "m"
        )

        _ = await drafter.firstDraft(capture: "dictated text", projectName: "p", context: QuickCaptureContext())

        let reached = await configured.waitForCalls(1)
        XCTAssertTrue(reached, "the configured endpoint got the request")
        XCTAssertEqual(hits.value, 0, "the redirect target got nothing")
    }

    func testBatchTranscriptionRedirectCannotCarryAudioToAnotherOrigin() async throws {
        let (configured, _, hits) = try redirectPair()

        _ = try? await MistralBatchTranscriptionClient().transcribe(
            wav: Data(repeating: 1, count: 64), language: nil, contextBias: ["Term"], apiKey: "k",
            endpoint: URL(string: "http://127.0.0.1:\(configured.port)/v1/audio/transcriptions")!
        )

        let reached = await configured.waitForCalls(1)
        XCTAssertTrue(reached, "the configured endpoint got the request")
        XCTAssertEqual(hits.value, 0, "the redirect target got nothing")
    }

    func testRedirectWithinTheOriginIsFollowed() async throws {
        let server = try FakeOpencodePromptRelay(
            status: { $0.path == "/old" ? 307 : 200 },
            location: { $0.path == "/old" ? "/new" : nil }
        )
        addTeardownBlock { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/old")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await SameOriginHTTP.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let reached = await server.waitForCalls(2)
        XCTAssertTrue(reached)
        XCTAssertEqual(server.calls.map(\.path), ["/old", "/new"])
    }
}
