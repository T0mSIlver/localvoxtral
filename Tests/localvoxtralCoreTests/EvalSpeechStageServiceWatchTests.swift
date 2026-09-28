import Foundation
import XCTest
import localvoxtralCore
import localvoxtralTestSupport

/// A live eval must stop, naming the STT service, once that service stops
/// answering, instead of letting every remaining utterance wait out its
/// timeout (#821: two hours of silence on the Mac).
final class EvalSpeechStageServiceWatchTests: XCTestCase {
    private let endpoint = URL(string: "ws://127.0.0.1:8000/v1/realtime")!

    func testThirdStallInARowStopsTheEvalNamingTheService() async throws {
        var watch = EvalSpeechStage.ServiceWatch(endpoint: endpoint)
        let stall = EvalSpeechStage.Failure("realtime socket error: refused", serviceStalled: true)

        try watch.record(stall)
        try watch.record(stall)
        XCTAssertThrowsError(try watch.record(stall)) { error in
            let failure = error as? EvalSpeechStage.Failure
            XCTAssertEqual(failure?.serviceStalled, true)
            XCTAssertTrue(
                failure?.description.hasPrefix(
                    "STT service at ws://127.0.0.1:8000/v1/realtime stopped answering: 3 utterances"
                ) == true,
                String(describing: failure)
            )
        }
    }

    func testAnswerResetsTheCountAndOtherErrorsLeaveIt() async throws {
        var watch = EvalSpeechStage.ServiceWatch(endpoint: endpoint)
        let stall = EvalSpeechStage.Failure("no final transcript within 90s", serviceStalled: true)

        try watch.record(stall)
        try watch.record(stall)
        watch.recordAnswer()
        try watch.record(stall)
        try watch.record(EvalSpeechStage.Failure("empty final transcript"))
        try watch.record(CocoaError(.fileReadNoSuchFile))
        XCTAssertEqual(watch.consecutiveStalls, 1)
    }

    /// The whole path through `transcribe`, with a client that connects and
    /// never answers: what the production client does against a dead port on
    /// macOS, where it waits for connectivity (#953). The timeout runs on a
    /// manual clock.
    func testDeadServiceStopsTheEvalAfterThreeUtterances() async throws {
        let deadEndpoint = URL(string: "ws://127.0.0.1:1/v1/realtime")!
        var watch = EvalSpeechStage.ServiceWatch(endpoint: deadEndpoint)
        let clock = ManualSessionClock()
        let timeout: TimeInterval = 30

        var stopped: EvalSpeechStage.Failure?
        for utterance in 1...3 {
            let client = FakeRealtimeClient()
            client.setOnConnect { client.emit(.connected) }
            let result = Task {
                try await EvalSpeechStage.transcribe(
                    pcm: Data(count: 32_000),
                    client: client,
                    endpoint: .init(url: deadEndpoint, apiKey: "", model: "voxtral"),
                    timeout: timeout,
                    clock: clock.clock
                )
            }
            await clock.waitForSleepers(1)
            clock.advance(by: timeout)
            do {
                _ = try await result.value
                XCTFail("a dead service returned a transcript")
            } catch {
                do {
                    try watch.record(error)
                } catch let failure as EvalSpeechStage.Failure {
                    XCTAssertEqual(utterance, 3, "the watch stopped the eval early")
                    stopped = failure
                }
            }
        }
        let failure = try XCTUnwrap(stopped, "the watch never stopped the eval")
        XCTAssertTrue(
            failure.description.contains("STT service at \(deadEndpoint) stopped answering"),
            failure.description
        )
    }

    /// A service that answers the final commit with an empty
    /// `transcription.done` answered: the utterance fails at once, says the
    /// transcript was empty, and the watch does not count it (#961).
    func testEmptyFinalFailsAtOnceWithoutCountingAsAStall() async throws {
        guard let outcome = await transcribeAnsweredWithEmptyFinal(allowsEmptyTranscript: false)
        else { return }
        guard case .failure(let error) = outcome else {
            return XCTFail("an empty final returned a transcript: \(outcome)")
        }
        let failure = error as? EvalSpeechStage.Failure
        XCTAssertEqual(failure?.serviceStalled, false, String(describing: error))
        XCTAssertTrue(
            failure?.description.hasPrefix("empty final transcript from ") == true,
            String(describing: error)
        )
        var watch = EvalSpeechStage.ServiceWatch(endpoint: endpoint)
        try watch.record(error)
        XCTAssertEqual(watch.consecutiveStalls, 0)
    }

    func testEmptyFinalIsAnEmptyTranscriptWhenTheEvalAllowsIt() async throws {
        guard let outcome = await transcribeAnsweredWithEmptyFinal(allowsEmptyTranscript: true)
        else { return }
        XCTAssertEqual(try outcome.get(), "")
    }

    /// One utterance whose final commit gets what `RealtimeAPIWebSocketClient`
    /// raises for a `transcription.done` with no text. The clock moves only
    /// through the one-second grace, never to the 30 s timeout; nil when
    /// `transcribe` was still waiting after that.
    private func transcribeAnsweredWithEmptyFinal(
        allowsEmptyTranscript: Bool
    ) async -> Result<String, any Error>? {
        let clock = ManualSessionClock()
        let client = FakeRealtimeClient()
        client.setOnConnect { client.emit(.connected) }
        client.setOnCommit { final in
            guard final else { return }
            client.emit(.finalTranscript(""))
            client.emit(.transcriptionFinalized)
        }
        let endpoint = endpoint
        let utterance = Task {
            try await EvalSpeechStage.transcribe(
                pcm: Data(count: 32_000),
                client: client,
                endpoint: .init(url: endpoint, apiKey: "", model: "voxtral"),
                timeout: 30,
                allowsEmptyTranscript: allowsEmptyTranscript,
                clock: clock.clock
            )
        }
        await clock.waitForSleepers(1)
        clock.advance(by: 1)

        let finished = BoundedWait()
        Task {
            _ = await utterance.result
            finished.resolve()
        }
        guard await finished.value(failAfter: 10) else {
            utterance.cancel()
            XCTFail("transcribe was still waiting one second after the empty final")
            return nil
        }
        return await utterance.result
    }
}
