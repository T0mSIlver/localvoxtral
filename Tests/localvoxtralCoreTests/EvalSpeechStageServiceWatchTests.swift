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

    /// The whole path with the real client: nothing listens on the port, as
    /// after the reaper stopped speechd mid-run.
    func testDeadServiceStopsTheEvalAfterThreeUtterances() async throws {
        let port = try unusedLoopbackPort()
        let deadEndpoint = URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
        var watch = EvalSpeechStage.ServiceWatch(endpoint: deadEndpoint)
        let pcm = Data(count: 32_000)

        var stopped: EvalSpeechStage.Failure?
        for _ in 0..<watch.limit {
            do {
                _ = try await EvalSpeechStage.transcribe(
                    pcm: pcm,
                    client: RealtimeAPIWebSocketClient(),
                    endpoint: .init(url: deadEndpoint, apiKey: "", model: "voxtral"),
                    timeout: 30
                )
                XCTFail("a dead service returned a transcript")
            } catch {
                do {
                    try watch.record(error)
                } catch let failure as EvalSpeechStage.Failure {
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
