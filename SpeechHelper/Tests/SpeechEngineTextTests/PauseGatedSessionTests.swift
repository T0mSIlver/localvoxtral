import XCTest

@testable import SpeechEngineText

final class PauseGatedSessionTests: XCTestCase {
    private static let frame = GateAudio.frame
    private static let lagFrames = 9
    private static let pad = 32
    private static let word = 1_000

    /// Stands in for Voxtral: one token per 80 ms frame it has heard, read 9 frames
    /// later, a word when the frame was loud and a pad otherwise.
    private final class FakeEngineSession: SpeechASRStreamingSession, @unchecked Sendable {
        private(set) var stepSizes: [Int] = []
        private(set) var heard: [Float] = []
        private(set) var tokens: [Int] = []
        private(set) var finished = false

        func step(_ samples: [Float]) -> SpeechStreamDelta {
            XCTAssertFalse(finished, "audio after the flush")
            stepSizes.append(samples.count)
            heard += samples
            var new: [Int] = []
            let frame = PauseGatedSessionTests.frame
            while (tokens.count + new.count + PauseGatedSessionTests.lagFrames) * frame <= heard.count {
                let start = (tokens.count + new.count) * frame
                let loud = heard[start..<(start + frame)].contains { abs($0) > 0.05 }
                new.append(loud ? PauseGatedSessionTests.word : PauseGatedSessionTests.pad)
            }
            tokens += new
            return SpeechStreamDelta(text: "", tokenIds: new)
        }

        func finish() -> SpeechStreamDelta {
            finished = true
            return SpeechStreamDelta(text: "", tokenIds: [])
        }

        var text: String { "" }
        var decodedTokenCount: Int { tokens.count }
        var utteranceStop: UtteranceStop? { nil }
        var words: Int { tokens.count { $0 == PauseGatedSessionTests.word } }
    }

    /// A phrase, a 5 s pause, a phrase, and a second of room noise before the stop.
    private let dictation = GateAudio.quiet(frames: 12)
        + GateAudio.speech(frames: 25)
        + GateAudio.quiet(frames: 62, seed: 3)
        + GateAudio.speech(frames: 12, seed: 4)
        + GateAudio.quiet(frames: 12, seed: 5)

    private func run(_ mode: PauseGate.Mode?) -> (engine: FakeEngineSession, stats: PauseGate.Stats?) {
        let engine = FakeEngineSession()
        let session: SpeechASRStreamingSession = mode.map {
            PauseGatedSession(
                session: engine,
                gate: PauseGate(configuration: .init(
                    mode: $0, newestTokenLagSamples: Self.lagFrames * Self.frame)),
                padTokenId: Self.pad
            )
        } ?? engine
        for batch in GateAudio.batches(dictation) { session.step(batch) }
        session.finish()
        XCTAssertTrue(engine.finished)
        return (engine, session.pauseGateStats)
    }

    func testHoldGivesTheModelTheSameAudioInFewerSteps() {
        let plain = run(nil).engine
        let (held, stats) = run(.hold)

        XCTAssertEqual(held.heard, plain.heard)
        XCTAssertEqual(held.tokens, plain.tokens)
        XCTAssertEqual(plain.stepSizes.count, 123)
        // The 12 frames before the first word go in 2 steps. Of the pause's 62, 11 are
        // stepped one by one until the gate closes, 48 in 8 steps, and the last 3 with
        // the frame speech returns in.
        XCTAssertEqual(held.stepSizes.count, 70)
        XCTAssertEqual(held.stepSizes.max(), 6 * Self.frame)
        XCTAssertEqual(stats?.droppedSamples, 0)
    }

    func testDropSkipsTheMiddleOfThePauseAndKeepsEveryWord() {
        let plain = run(nil).engine
        let (dropped, stats) = run(.drop)

        XCTAssertEqual(dropped.words, plain.words)
        XCTAssertEqual(dropped.words, 37)
        // Before the first word: 12 quiet frames, 6 kept. The pause: 62 frames, 11 heard
        // until the gate closed and 6 kept before the speech. The end: 12 frames, 11
        // heard until it closed, and the one after dropped at the stop.
        XCTAssertEqual(stats?.droppedSamples, (6 + 45 + 1) * Self.frame)
        XCTAssertEqual(dropped.heard.count, dictation.count - 52 * Self.frame)
        XCTAssertEqual(stats?.closes, 2)
    }
}
