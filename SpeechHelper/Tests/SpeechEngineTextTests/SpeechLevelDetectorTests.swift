import XCTest

@testable import SpeechEngineText

final class SpeechLevelDetectorTests: XCTestCase {
    private let frame = GateAudio.frame

    /// Whether each 80 ms frame of `audio` holds speech.
    private func speechFrames(_ audio: [Float], detector: inout SpeechLevelDetector) -> [Bool] {
        GateAudio.batches(audio).map { detector.process($0) != nil }
    }

    func testAVoiceOverRoomNoiseIsSpeechAndTheRoomIsNot() {
        var detector = SpeechLevelDetector()
        let audio = GateAudio.quiet(frames: 25) + GateAudio.speech(frames: 5) + GateAudio.quiet(frames: 25, seed: 3)

        let speech = speechFrames(audio, detector: &detector)

        XCTAssertEqual(speech.firstIndex(of: true), 25)
        XCTAssertEqual(speech.lastIndex(of: true), 29)
    }

    func testSpeechEndsWhereItsLastLoudSubFrameEnds() {
        var detector = SpeechLevelDetector()
        _ = detector.process(GateAudio.quiet(frames: 10))
        // 50 ms of voice at the start of an 80 ms batch.
        let batch = GateAudio.speech(samples: 800) + GateAudio.quiet(frames: 1).prefix(480)

        XCTAssertEqual(detector.process(batch), 800)
    }

    func testAKeyClickIsNotSpeech() {
        var detector = SpeechLevelDetector()
        _ = detector.process(GateAudio.quiet(frames: 10))
        // 20 ms, shorter than the 30 ms run speech needs.
        let click = GateAudio.speech(samples: 320) + GateAudio.quiet(frames: 1).prefix(960)

        XCTAssertNil(detector.process(click))
    }

    /// A fan that starts mid-dictation must not hold the gate open for the rest of
    /// it: the floor climbs 2 dB a second until the new room is the floor.
    func testASteadyLouderRoomStopsReadingAsSpeech() {
        var detector = SpeechLevelDetector()
        _ = detector.process(GateAudio.quiet(frames: 25))
        // 20 dB louder than the room before it.
        let fan = GateAudio.noise(15 * 16_000, amplitude: 0.01, seed: 7)

        let speech = speechFrames(fan, detector: &detector)

        XCTAssertTrue(speech[0], "at first it stands out")
        XCTAssertFalse(speech.suffix(50).contains(true), "after 11 s it is the room")
    }

    func testTheAnswerDoesNotDependOnHowTheAudioIsCut() {
        let audio = GateAudio.quiet(frames: 12) + GateAudio.speech(frames: 3) + GateAudio.quiet(frames: 12, seed: 5)
        var whole = SpeechLevelDetector()
        var pieces = SpeechLevelDetector()
        let expected = whole.process(audio)

        var offset = 0
        var last: Int?
        for batch in GateAudio.batches(audio, of: 1_111) {
            if let end = pieces.process(batch) { last = offset + end }
            offset += batch.count
        }

        XCTAssertEqual(last, expected)
        XCTAssertEqual(expected, 15 * frame)
    }
}
