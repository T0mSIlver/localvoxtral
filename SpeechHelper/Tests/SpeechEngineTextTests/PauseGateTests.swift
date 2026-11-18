import XCTest

@testable import SpeechEngineText

/// 16 kHz test audio: a room's hiss, and a voice-loud sound over it.
enum GateAudio {
    static let frame = 1_280

    /// Deterministic noise in [-amplitude, amplitude].
    static func noise(_ count: Int, amplitude: Float, seed: UInt32 = 1) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    static func quiet(frames: Int, seed: UInt32 = 1) -> [Float] {
        noise(frames * frame, amplitude: 0.001, seed: seed)
    }

    static func speech(frames: Int, seed: UInt32 = 2) -> [Float] {
        speech(samples: frames * frame, seed: seed)
    }

    /// Ends on a zero sample, so the detector's pre-emphasis sees no step from the
    /// voice into the room noise after it.
    static func speech(samples: Int, seed: UInt32 = 2) -> [Float] {
        var voice = noise(samples, amplitude: 0.2, seed: seed)
        voice[samples - 1] = 0
        return voice
    }

    static func batches(_ samples: [Float], of size: Int = frame) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map {
            Array(samples[$0..<min($0 + size, samples.count)])
        }
    }
}

final class PauseGateTests: XCTestCase {
    private let frame = GateAudio.frame
    /// Voxtral at its 480 ms delay: the newest token stands 9 frames behind the audio.
    private let lagFrames = 9

    private func gate(_ mode: PauseGate.Mode) -> PauseGate {
        PauseGate(configuration: .init(mode: mode, newestTokenLagSamples: lagFrames * frame))
    }

    private func frames(_ count: Int) -> [Float] { [Float](repeating: 0, count: count * frame) }

    /// Opens the gate with one frame of speech, then feeds quiet frames, each decoding
    /// one pad, until it closes. Returns how many quiet frames that took.
    private func quietFramesUntilClosed(_ gate: inout PauseGate, limit: Int = 100) -> Int {
        _ = gate.admit(frames(1), lastSpeechEnd: frame)
        gate.observe(tokensArePads: [false])
        for quiet in 1...limit {
            XCTAssertNotNil(gate.admit(frames(1), lastSpeechEnd: nil), "an open gate feeds every batch")
            gate.observe(tokensArePads: [true])
            if !gate.isOpen { return quiet }
        }
        return limit
    }

    func testAnUtteranceStartsClosedAndSpeechFeedsTheHeldAudioFirst() {
        var gate = gate(.drop)
        let before = (0..<3).map { GateAudio.quiet(frames: 1, seed: UInt32($0 + 1)) }
        for batch in before { XCTAssertNil(gate.admit(batch, lastSpeechEnd: nil)) }
        let onset = GateAudio.speech(frames: 1)

        XCTAssertEqual(gate.admit(onset, lastSpeechEnd: 400), before.flatMap { $0 } + onset)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.stats.droppedSamples, 0)
    }

    /// The model writes a word some frames after it hears it. Pads read before the
    /// frame they stand on is past the speech say nothing about the phrase being done.
    func testTheGateClosesAfterThreePadsThatStandAfterTheSpeech() {
        var gate = gate(.drop)
        // The first pad that counts is read once 9 quiet frames are in; the third, at 11.
        XCTAssertEqual(quietFramesUntilClosed(&gate), lagFrames + 2)
        XCTAssertEqual(gate.stats.closes, 1)
    }

    func testAWordWrittenDuringThePauseStartsThePadCountAgain() {
        var gate = gate(.drop)
        _ = gate.admit(frames(1), lastSpeechEnd: frame)
        for _ in 0..<(lagFrames + 1) {
            _ = gate.admit(frames(1), lastSpeechEnd: nil)
            gate.observe(tokensArePads: [true])
        }
        // Two pads counted; the phrase's last word comes out late.
        _ = gate.admit(frames(1), lastSpeechEnd: nil)
        gate.observe(tokensArePads: [false])
        for _ in 0..<2 {
            _ = gate.admit(frames(1), lastSpeechEnd: nil)
            gate.observe(tokensArePads: [true])
            XCTAssertTrue(gate.isOpen)
        }
        _ = gate.admit(frames(1), lastSpeechEnd: nil)
        gate.observe(tokensArePads: [true])
        XCTAssertFalse(gate.isOpen)
    }

    /// One step can decode several tokens. Only those whose frame starts after the
    /// speech count: of four pads read 10 frames after it, the last two.
    func testPadsOfOneLargeStepCountOnlyWhereTheyStandAfterTheSpeech() {
        var gate = gate(.drop)
        _ = gate.admit(frames(1), lastSpeechEnd: frame)
        _ = gate.admit(frames(lagFrames + 1), lastSpeechEnd: nil)
        gate.observe(tokensArePads: [true, true, true, true])
        XCTAssertTrue(gate.isOpen)
        _ = gate.admit(frames(1), lastSpeechEnd: nil)
        gate.observe(tokensArePads: [true])
        XCTAssertFalse(gate.isOpen)
    }

    func testDropKeepsTheLastHalfSecondOfAPauseAndFeedsItWhenSpeechReturns() {
        var gate = gate(.drop)
        _ = quietFramesUntilClosed(&gate)
        let pause = (0..<50).map { GateAudio.quiet(frames: 1, seed: UInt32($0 + 10)) }
        for batch in pause { XCTAssertNil(gate.admit(batch, lastSpeechEnd: nil)) }
        let onset = GateAudio.speech(frames: 1)

        let fed = gate.admit(onset, lastSpeechEnd: frame)

        XCTAssertEqual(fed, pause.suffix(6).flatMap { $0 } + onset, "the last 480 ms, then the speech")
        XCTAssertEqual(gate.stats.droppedSamples, 44 * frame)
        XCTAssertEqual(gate.stats.heldSamples, 7 * frame)
    }

    func testHoldFeedsAPauseInHalfSecondStepsAndLosesNothing() {
        var gate = gate(.hold)
        _ = quietFramesUntilClosed(&gate)
        let pause = (0..<20).map { GateAudio.quiet(frames: 1, seed: UInt32($0 + 10)) }
        var steps: [[Float]] = []
        for batch in pause {
            guard let step = gate.admit(batch, lastSpeechEnd: nil) else { continue }
            steps.append(step)
            gate.observe(tokensArePads: [Bool](repeating: true, count: step.count / frame))
        }
        if let rest = gate.stop() { steps.append(rest) }

        XCTAssertEqual(steps.map(\.count), [6 * frame, 6 * frame, 6 * frame, 2 * frame])
        XCTAssertEqual(steps.flatMap { $0 }, pause.flatMap { $0 })
        XCTAssertEqual(gate.stats.droppedSamples, 0)
    }

    /// The detector can miss quiet speech. In `hold` the model still hears it, and a
    /// word it writes puts the gate back to a step per batch.
    func testATokenWrittenOnHeldAudioOpensTheGate() {
        var gate = gate(.hold)
        _ = quietFramesUntilClosed(&gate)
        var step: [Float]?
        for _ in 0..<6 { step = gate.admit(frames(1), lastSpeechEnd: nil) }
        XCTAssertEqual(step?.count, 6 * frame)

        gate.observe(tokensArePads: [true, true, true, true, true, false])

        XCTAssertTrue(gate.isOpen)
        XCTAssertNotNil(gate.admit(frames(1), lastSpeechEnd: nil))
    }

    func testAStopInsideAPauseDropsWhatDropKept() {
        var gate = gate(.drop)
        _ = quietFramesUntilClosed(&gate)
        for _ in 0..<4 { _ = gate.admit(frames(1), lastSpeechEnd: nil) }

        XCTAssertNil(gate.stop())
        XCTAssertEqual(gate.stats.droppedSamples, 4 * frame)
    }
}
