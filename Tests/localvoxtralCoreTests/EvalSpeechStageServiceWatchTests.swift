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
}
