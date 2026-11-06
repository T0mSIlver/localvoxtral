import XCTest

@testable import SpeechEngineText

final class EmptyStreamRedecodeTests: XCTestCase {
    /// 80 ms of a 440 Hz tone at -20 dBFS RMS: speech level.
    private func speech(_ windows: Int = 1) -> [Float] {
        let amplitude = Float(0.1 * 2.0.squareRoot())
        return (0..<(windows * EmptyStreamRedecode.windowSamples)).map {
            amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000))
        }
    }

    /// 80 ms at -60 dBFS: a quiet room.
    private func roomTone(_ windows: Int = 1) -> [Float] {
        (0..<(windows * EmptyStreamRedecode.windowSamples)).map { $0 % 2 == 0 ? 0.001 : -0.001 }
    }

    func testAnAudibleUtteranceWithNoTokenIsDecodedAgainWhole() {
        var redecode = EmptyStreamRedecode()
        let steps = [roomTone(3), speech(20), roomTone(4)]
        for step in steps { redecode.record(step, decodedTokens: 0) }
        XCTAssertEqual(redecode.audioToRedecode(decodedTokens: 0), steps.flatMap { $0 })
    }

    func testTheFirstTokenDropsTheAudio() {
        var redecode = EmptyStreamRedecode()
        redecode.record(speech(5), decodedTokens: 0)
        redecode.record(speech(5), decodedTokens: 1)
        XCTAssertNil(redecode.audioToRedecode(decodedTokens: 1))
    }

    func testATokenFromTheFinalFlushAloneSkipsTheSecondDecode() {
        var redecode = EmptyStreamRedecode()
        redecode.record(speech(5), decodedTokens: 0)
        XCTAssertNil(redecode.audioToRedecode(decodedTokens: 2))
    }

    func testAQuietUtteranceIsNotDecodedAgain() {
        var redecode = EmptyStreamRedecode()
        redecode.record(roomTone(50), decodedTokens: 0)
        XCTAssertNil(redecode.audioToRedecode(decodedTokens: 0))
    }

    func testSpeechInAStepShorterThanAWindowCounts() {
        var redecode = EmptyStreamRedecode()
        let short = Array(speech().prefix(400))
        redecode.record(short, decodedTokens: 0)
        XCTAssertEqual(redecode.audioToRedecode(decodedTokens: 0), short)
    }

    func testAnUtterancePastTheCapIsNotKept() {
        var redecode = EmptyStreamRedecode(maxSamples: 4 * EmptyStreamRedecode.windowSamples)
        redecode.record(speech(3), decodedTokens: 0)
        redecode.record(speech(2), decodedTokens: 0)
        redecode.record(speech(1), decodedTokens: 0)
        XCTAssertNil(redecode.audioToRedecode(decodedTokens: 0))
    }

    func testItAnswersOnce() {
        var redecode = EmptyStreamRedecode()
        redecode.record(speech(5), decodedTokens: 0)
        XCTAssertNotNil(redecode.audioToRedecode(decodedTokens: 0))
        XCTAssertNil(redecode.audioToRedecode(decodedTokens: 0))
    }
}
