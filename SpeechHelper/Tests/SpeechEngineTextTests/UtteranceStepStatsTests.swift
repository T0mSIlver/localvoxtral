import XCTest

@testable import SpeechEngineText

final class UtteranceStepStatsTests: XCTestCase {
    /// 80 ms of audio at a constant level: 0.1 is -20 dBFS (speech), 0.001 is -60 (a pause).
    private func step(_ level: Float) -> [Float] { [Float](repeating: level, count: 1_280) }

    /// A slow step is said when it happens, once, so a dictation cancelled mid-stall
    /// still leaves it in the log.
    func testTheFirstSlowStepIsReportedOnceAsItHappens() {
        var stats = UtteranceStepStats()
        XCTAssertNil(stats.record(milliseconds: 60, samples: step(0.1), producedText: true))
        XCTAssertEqual(
            stats.record(milliseconds: 3_120, samples: [Float](repeating: 0.1, count: 32_000), producedText: false),
            "speechd diag: a step took 3120 ms for 2000 ms of audio; the GPU is not keeping up"
        )
        XCTAssertNil(stats.record(milliseconds: 4_000, samples: step(0.1), producedText: false))
    }

    /// The summary tells a slow helper from a model that produced no text: the slowest
    /// step, and the longest run of audio without text with its loudest step.
    func testTheSummaryNamesTheSlowestStepAndTheLongestRunWithoutText() {
        var stats = UtteranceStepStats()
        _ = stats.record(milliseconds: 55, samples: step(0.1), producedText: true)
        for _ in 0..<3 { _ = stats.record(milliseconds: 60, samples: step(0.001), producedText: false) }
        _ = stats.record(milliseconds: 90, samples: step(0.1), producedText: true)
        for _ in 0..<5 { _ = stats.record(milliseconds: 58, samples: step(0.1), producedText: false) }

        XCTAssertEqual(
            stats.finish(ending: "close", decodedTokens: 10),
            "speechd diag: utterance ended by close: 10 steps, slowest 90 ms for 80 ms of audio, "
                + "longest audio without text 400 ms (loudest -20 dBFS), 10 tokens"
        )
    }

    /// No step, no line; and each utterance starts fresh.
    func testAnUtteranceWithoutStepsSaysNothingAndFinishResets() {
        var stats = UtteranceStepStats()
        XCTAssertNil(stats.finish(ending: "commit", decodedTokens: 0))
        _ = stats.record(milliseconds: 2_000, samples: step(0.1), producedText: false)
        XCTAssertNotNil(stats.finish(ending: "commit", decodedTokens: 1))
        XCTAssertNil(stats.finish(ending: "commit", decodedTokens: 0))
        XCTAssertNotNil(
            stats.record(milliseconds: 2_000, samples: step(0.1), producedText: false),
            "a new utterance reports its own slow step"
        )
    }
}
