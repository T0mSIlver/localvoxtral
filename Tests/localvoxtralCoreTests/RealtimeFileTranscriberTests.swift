import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// A recorded memo through a realtime socket (#925): all of the audio, then
/// one final commit, and the answer to that commit.
final class RealtimeFileTranscriberTests: XCTestCase {
    private let configuration = RealtimeSessionConfiguration(
        endpoint: URL(string: "ws://127.0.0.1:1/v1/realtime")!, apiKey: "", model: "m")

    /// 2.05 s of audio: 20 full chunks and a short one.
    private let pcm = Data(repeating: 1, count: 65_600)

    private func transcriber(_ client: FakeRealtimeClient, clock: SessionClock = .live) -> RealtimeFileTranscriber {
        RealtimeFileTranscriber(makeClient: { client }, clock: clock)
    }

    func testSendsEveryChunkThenOneFinalCommitAndReturnsTheFinalText() async throws {
        let client = FakeRealtimeClient()
        client.setOnConnect { client.emit(.connected) }
        client.setOnCommit { final in
            guard final else { return }
            client.emit(.partialTranscript("add a dark"))
            client.emit(.finalTranscript(" add a dark mode "))
            client.emit(.transcriptionFinalized)
        }
        let text = try await transcriber(client).transcribe(pcm16: pcm, configuration: configuration)
        XCTAssertEqual(text, "add a dark mode")
        XCTAssertEqual(client.sentAudioBytes, pcm.count)
        XCTAssertEqual(client.commits, [true])
        XCTAssertEqual(client.connectConfigurations.first?.model, "m")
        XCTAssertEqual(client.disconnectCount, 1, "the socket is closed after the answer")
    }

    func testAServerWithNoFinalTextGivesTheStreamedText() async throws {
        let client = FakeRealtimeClient()
        client.setOnConnect { client.emit(.connected) }
        client.setOnCommit { _ in
            client.emit(.partialTranscript("add a"))
            client.emit(.partialTranscript(" dark mode"))
            client.emit(.transcriptionFinalized)
        }
        let text = try await transcriber(client).transcribe(pcm16: pcm, configuration: configuration)
        XCTAssertEqual(text, "add a dark mode")
    }

    func testABackendErrorOrAnEarlyCloseFails() async {
        for (event, failure) in [
            (RealtimeEvent.error("model not loaded"), RealtimeFileTranscriber.Failure.backend("model not loaded")),
            (.transcriptionStopped("60-minute limit reached; start again."), .backend("60-minute limit reached; start again.")),
            (.disconnected, .disconnected),
        ] {
            let client = FakeRealtimeClient()
            client.setOnConnect { client.emit(.connected) }
            client.setOnCommit { _ in client.emit(event) }
            do {
                _ = try await transcriber(client).transcribe(pcm16: pcm, configuration: configuration)
                XCTFail("\(event) should fail")
            } catch {
                XCTAssertEqual(error as? RealtimeFileTranscriber.Failure, failure)
            }
        }
    }

    func testABackendThatNeverAnswersTimesOutAfterTheConnectAllowanceAndTheAudioLength() async {
        let client = FakeRealtimeClient()
        let clock = ManualSessionClock()
        let task = Task { [configuration, pcm] in
            try await RealtimeFileTranscriber(makeClient: { client }, clock: clock.clock)
                .transcribe(pcm16: pcm, configuration: configuration)
        }
        await clock.waitForSleepers(1)
        clock.advance(by: 31)
        XCTAssertEqual(clock.pendingSleepers, 1, "30 s to connect plus 2 s of audio")
        clock.advance(by: 1)
        do {
            _ = try await task.value
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? RealtimeFileTranscriber.Failure, .timedOut)
        }
        XCTAssertEqual(client.disconnectCount, 1)
    }
}
