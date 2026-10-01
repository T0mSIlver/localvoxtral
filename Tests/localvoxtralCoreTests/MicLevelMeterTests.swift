import Foundation
import XCTest
@testable import localvoxtralCore

final class MicLevelMeterTests: XCTestCase {
    /// `seconds` of a sine at `amplitude` (0...1 of full scale), PCM16 mono.
    private func tone(amplitude: Double, seconds: Double) -> Data {
        let count = Int(seconds * Double(DictationAudioRecording.sampleRate))
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = amplitude * sin(Double(index) * 2 * .pi * 440 / Double(DictationAudioRecording.sampleRate))
            var sample = Int16(value * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func decibels(ofAmplitude amplitude: Double) -> Double {
        // A sine's RMS is its amplitude / √2.
        20 * log10(amplitude / 2.0.squareRoot())
    }

    func testLoudnessMapsTheDecibelRangeOntoTheBars() {
        XCTAssertEqual(MicLevelMeter.loudness(pcm16: Data(count: 640)), 0, "digital silence")
        XCTAssertEqual(MicLevelMeter.loudness(pcm16: tone(amplitude: 0.0005, seconds: 0.02)), 0, "below the floor")
        XCTAssertEqual(MicLevelMeter.loudness(pcm16: tone(amplitude: 0.9, seconds: 0.02)), 1, "above the ceiling")
        let amplitude = 0.02
        let expected = (decibels(ofAmplitude: amplitude) - MicLevelMeter.floorDB)
            / (MicLevelMeter.ceilingDB - MicLevelMeter.floorDB)
        XCTAssertEqual(MicLevelMeter.loudness(pcm16: tone(amplitude: amplitude, seconds: 0.02)), expected, accuracy: 0.01)
    }

    func testRisesFastAndFallsSlowlyInAudioTime() throws {
        let meter = MicLevelMeter()
        // 40 ms chunks, so every chunk posts.
        let speech = tone(amplitude: 0.9, seconds: 0.04)
        let silence = Data(count: 1_280)
        _ = meter.ingest(pcm16: speech)
        // 80 ms of speech: past two rise time constants, most of the way up.
        let risen = try XCTUnwrap(meter.ingest(pcm16: speech))
        XCTAssertGreaterThan(risen, 0.9)
        // 40 ms of silence: well under one fall time constant, still high.
        let falling = try XCTUnwrap(meter.ingest(pcm16: silence))
        XCTAssertGreaterThan(falling, 0.7)
        // Over a second of silence: rested.
        var rested = falling
        for _ in 0..<30 { rested = meter.ingest(pcm16: silence) ?? rested }
        XCTAssertLessThan(rested, 0.01)
    }

    func testPostsAtMostThirtyTimesASecondOfAudio() {
        let meter = MicLevelMeter()
        let posts = (0..<100).compactMap { _ in meter.ingest(pcm16: tone(amplitude: 0.1, seconds: 0.01)) }
        // One second of 10 ms chunks: the first chunk posts, then every
        // fourth (40 ms ≥ 1/30 s).
        XCTAssertEqual(posts.count, 25)
        XCTAssertNil(meter.ingest(pcm16: Data()), "an empty chunk moves nothing")
    }
}
