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

    func testDefaultLimitIsAnHourAndPhrasesItselfInOneShortSentence() {
        // The default guards a session left running; it is no longer the point where
        // decoding falls behind live speech (Blaizzy/mlx-audio-swift #263-#265, #314).
        XCTAssertEqual(UtteranceLimit.defaultSeconds, 3_600)
        XCTAssertEqual(
            UtteranceLimit().reachedMessage,
            "60-minute limit reached; start again."
        )
        XCTAssertLessThanOrEqual(
            UtteranceLimit().reachedMessage.count, UtteranceLimit.maxMessageCharacters
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
            "10-minute limit reached; start again."
        )
        XCTAssertEqual(
            UtteranceLimit(seconds: 90).reachedMessage,
            "90-second limit reached; start again."
        )
        // The popover shows one short sentence (AGENTS.md), and one that fits the status
        // row's single line: it wraps, so a long sentence grows the whole menu
        // (owner review, 2026-09-17). The widest limit this can phrase is checked too.
        let messages = [
            UtteranceLimit().reachedMessage,
            UtteranceLimit(seconds: 59).reachedMessage,
            UtteranceLimit.endOfStreamMessage,
        ]
        for message in messages {
            XCTAssertFalse(message.contains("\n"))
            XCTAssertEqual(message.filter { $0 == "." }.count, 1, message)
            XCTAssertLessThanOrEqual(
                message.count, UtteranceLimit.maxMessageCharacters,
                "too long for the popover's status line: \(message)"
            )
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

    func testReporterClassifiesTheSessionOnlyWhenAReportIsDue() {
        var reporter = UtteranceStopReporter()
        var reads = 0
        func classify(isFinished: Bool) -> UtteranceStop? {
            reads += 1
            return UtteranceStop.classify(
                isFinished: isFinished, decodedTokenCount: 101, maxDecodedTokens: 100
            )
        }

        XCTAssertNil(reporter.report(classify(isFinished: false)))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(reporter.report(classify(isFinished: true)), .lengthLimit)
        XCTAssertNil(reporter.report(classify(isFinished: true)))
        XCTAssertEqual(reads, 2, "steps after a reported stop must not copy the token array")
    }

    func testReporterReportsAStopOncePerSession() {
        var reporter = UtteranceStopReporter()

        XCTAssertNil(reporter.report(
            UtteranceStop.classify(isFinished: false, decodedTokenCount: 10, maxDecodedTokens: 100)
        ))
        XCTAssertEqual(
            reporter.report(
                UtteranceStop.classify(isFinished: true, decodedTokenCount: 101, maxDecodedTokens: 100)
            ),
            .lengthLimit
        )
        // Audio keeps arriving after the stop; every later step must stay quiet.
        XCTAssertNil(reporter.report(
            UtteranceStop.classify(isFinished: true, decodedTokenCount: 101, maxDecodedTokens: 100)
        ))

        reporter.reset()
        XCTAssertEqual(
            reporter.report(
                UtteranceStop.classify(isFinished: true, decodedTokenCount: 40, maxDecodedTokens: 100)
            ),
            .endOfStream
        )
    }
}
