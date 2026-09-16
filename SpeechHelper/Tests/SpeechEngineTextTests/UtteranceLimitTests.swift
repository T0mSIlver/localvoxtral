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
            UtteranceLimit(seconds: 1_200).reachedMessage,
            "Dictation reached the 20-minute limit. Stop and start again to continue."
        )
        XCTAssertEqual(
            UtteranceLimit(seconds: 90).reachedMessage,
            "Dictation reached the 90-second limit. Stop and start again to continue."
        )
        XCTAssertFalse(UtteranceLimit().reachedMessage.contains("\n"))
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
        // An EOS stop strips its EOS token, so the count never exceeds the cap.
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 100, maxDecodedTokens: 100),
            .endOfStream
        )
        XCTAssertEqual(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 12, maxDecodedTokens: 100),
            .endOfStream
        )
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
