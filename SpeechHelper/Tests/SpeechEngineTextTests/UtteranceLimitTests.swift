import XCTest

@testable import SpeechEngineText

final class UtteranceLimitTests: XCTestCase {
    /// Voxtral Realtime decodes 12.5 tokens per second of audio (one per 80 ms frame).
    private let voxtralFrameRate: Float = 12.5
    /// The engine's own default, which silently ended dictation near 5.5 minutes (#314).
    private let engineDefaultMaxTokens = 4_096

    func testDefaultLimitOutlastsTheEngineDefaultCap() {
        let limit = UtteranceLimit()
        let tokens = limit.maxDecodedTokens(frameRate: voxtralFrameRate)

        XCTAssertGreaterThan(tokens, engineDefaultMaxTokens)
        // The limit must cover its advertised duration of real audio plus finish padding.
        XCTAssertGreaterThanOrEqual(
            tokens,
            Int(Double(limit.seconds) * 12.5) + UtteranceLimit.finishPaddingTokens
        )
    }

    func testMaxDecodedTokensScalesWithDurationAndKeepsFinishPadding() {
        XCTAssertEqual(
            UtteranceLimit(seconds: 60).maxDecodedTokens(frameRate: voxtralFrameRate),
            750 + UtteranceLimit.finishPaddingTokens
        )
        // Fractional token counts round up so the last frame is never cut.
        XCTAssertEqual(
            UtteranceLimit(seconds: 1).maxDecodedTokens(frameRate: voxtralFrameRate),
            13 + UtteranceLimit.finishPaddingTokens
        )
    }

    func testFinishPaddingCoversTheLongestTranscriptionDelay() {
        // finish() appends (delay tokens + 1) + 10 padding tokens; the delay tops out at
        // 2,400 ms = 30 tokens at 80 ms per token.
        let longestFinishPad = (2_400 / 80 + 1) + 10
        XCTAssertGreaterThanOrEqual(UtteranceLimit.finishPaddingTokens, longestFinishPad)
    }

    func testReachedMessageIsOneShortSentencePerLimit() {
        XCTAssertEqual(
            UtteranceLimit(seconds: 600).reachedMessage,
            "Dictation reached its 10-minute limit; start again to continue."
        )
        XCTAssertEqual(
            UtteranceLimit(seconds: 90).reachedMessage,
            "Dictation reached its 90-second limit; start again to continue."
        )
        // The popover shows one short sentence (AGENTS.md).
        for message in [UtteranceLimit().reachedMessage, UtteranceLimit.endOfStreamMessage] {
            XCTAssertFalse(message.contains("\n"))
            XCTAssertEqual(message.filter { $0 == "." }.count, 1, message)
        }
    }

    func testClassifyDistinguishesCapFromEndOfStream() {
        XCTAssertNil(
            UtteranceStop.classify(isFinished: false, decodedTokenCount: 5_000, maxDecodedTokens: 100)
        )
        // The engine appends the crossing token before stopping: count == max + 1.
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 101, maxDecodedTokens: 100),
            .lengthLimit
        )
        // EOS sampled exactly as the count crosses the cap: both conditions fire and the
        // EOS pop leaves count == max. Report the limit, the actionable reason.
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 100, maxDecodedTokens: 100),
            .lengthLimit
        )
        // A plain EOS stop below the cap pops its EOS: count <= max - 1.
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 99, maxDecodedTokens: 100),
            .endOfStream
        )
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 12, maxDecodedTokens: 100),
            .endOfStream
        )
    }

    func testReporterReadsTheTokenCountOnlyWhenAReportIsDue() {
        var reporter = UtteranceStopReporter()
        var reads = 0
        func count() -> Int { reads += 1; return 101 }

        XCTAssertNil(reporter.check(isFinished: false, decodedTokenCount: count(), maxDecodedTokens: 100))
        XCTAssertEqual(reads, 0, "a live session must not copy the token array")
        XCTAssertEqual(
            reporter.check(isFinished: true, decodedTokenCount: count(), maxDecodedTokens: 100),
            .lengthLimit
        )
        XCTAssertNil(reporter.check(isFinished: true, decodedTokenCount: count(), maxDecodedTokens: 100))
        XCTAssertEqual(reads, 1, "steps after a reported stop must not copy the token array")
    }

    func testReporterReportsAStopOncePerSession() {
        var reporter = UtteranceStopReporter()

        XCTAssertNil(reporter.check(isFinished: false, decodedTokenCount: 10, maxDecodedTokens: 100))
        XCTAssertEqual(
            reporter.check(isFinished: true, decodedTokenCount: 101, maxDecodedTokens: 100),
            .lengthLimit
        )
        // Audio keeps arriving after the stop; every later step must stay quiet.
        XCTAssertNil(reporter.check(isFinished: true, decodedTokenCount: 101, maxDecodedTokens: 100))

        reporter.reset()
        XCTAssertEqual(
            reporter.check(isFinished: true, decodedTokenCount: 40, maxDecodedTokens: 100),
            .endOfStream
        )
    }
}
