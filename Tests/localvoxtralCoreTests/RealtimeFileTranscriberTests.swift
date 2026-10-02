import Foundation
import Synchronization
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
    // MARK: - Past a vLLM server's context limit (#1148)

    /// 100 tokens: 8 s of audio fit, and a cut falls between 4.8 s and 6.8 s.
    private let budget = RealtimeContextBudget(maxModelLen: 100)

    /// `seconds` of audio at `level`, with silence over `quiet` seconds.
    private func memo(seconds: Int, level: Int16 = 1_000, quiet: Range<Double>? = nil) -> Data {
        let rate = AudioChunkBuffer.bytesPerSecond / 2
        var samples = [Int16](repeating: level, count: seconds * rate)
        if let quiet {
            for index in Int(quiet.lowerBound * Double(rate)) ..< Int(quiet.upperBound * Double(rate)) {
                samples[index] = 0
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    func testAMemoLongerThanTheContextLimitComesBackWhole() async throws {
        let pcm = memo(seconds: 20)
        let limit = budget.capacityBytes
        let clients = MadeClients()
        // vLLM past max_model_len: nothing more is transcribed. Each session
        // answers with the bytes it transcribed.
        let transcriber = RealtimeFileTranscriber(makeClient: {
            let client = FakeRealtimeClient()
            client.setOnConnect { client.emit(.connected) }
            client.setOnCommit { final in
                guard final else { return }
                client.emit(.finalTranscript("\(min(client.sentAudioBytes, limit))"))
                client.emit(.transcriptionFinalized)
            }
            clients.list.withLock { $0.append(client) }
            return client
        })
        let text = try await transcriber.transcribe(pcm16: pcm, configuration: configuration, contextBudget: budget)
        let transcribed = text.split(separator: " ").compactMap { Int($0) }
        let sent = clients.list.withLock { $0.map(\.sentAudioBytes) }
        XCTAssertEqual(transcribed.reduce(0, +), pcm.count, "sessions: \(sent)")
        XCTAssertTrue(sent.allSatisfy { $0 <= budget.forceBytes }, "a session ran past the margin: \(sent)")
        XCTAssertEqual(clients.list.withLock { $0.map(\.disconnectCount) }, Array(repeating: 1, count: sent.count))
    }

    func testTheMemoIsCutInItsQuietestStretch() {
        let pcm = memo(seconds: 20, quiet: 6.0 ..< 7.0)
        let segments = RealtimeFileTranscriber.segments(ofPCM16: pcm, budget: budget)
        let cut = Double(segments[0].upperBound) / Double(AudioChunkBuffer.bytesPerSecond)
        XCTAssertGreaterThanOrEqual(cut, 6.0 + RealtimeContextBudget.pauseQuietSeconds / 2)
        XCTAssertLessThanOrEqual(cut, 7.0 - RealtimeContextBudget.pauseQuietSeconds / 2)
        XCTAssertEqual(segments.first?.lowerBound, 0)
        XCTAssertEqual(segments.last?.upperBound, pcm.count)
        for (left, right) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(left.upperBound, right.lowerBound, "no audio lost or doubled at a seam")
        }
    }

    func testAMemoWithinTheLimitIsOneSession() {
        let pcm = memo(seconds: 6)
        XCTAssertEqual(RealtimeFileTranscriber.segments(ofPCM16: pcm, budget: budget), [0 ..< pcm.count])
        XCTAssertEqual(RealtimeFileTranscriber.segments(ofPCM16: memo(seconds: 20), budget: nil).count, 1)
    }
}

private final class MadeClients: Sendable {
    let list = Mutex<[FakeRealtimeClient]>([])
}
