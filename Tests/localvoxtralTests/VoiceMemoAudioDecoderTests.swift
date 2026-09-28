import AVFoundation
import Foundation
import XCTest
@testable import localvoxtral

/// Memo files as a phone saves them, into the 16 kHz mono PCM16 the engine
/// and the audio store take (#925).
final class VoiceMemoAudioDecoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memo-decoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 440 Hz tone, `seconds` long, written in the file's own format.
    private func writeTone(to url: URL, settings: [String: Any], sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    func testAStereoAACMemoBecomesSixteenKilohertzMonoOfTheSameLength() throws {
        let url = directory.appendingPathComponent("walk.m4a")
        try writeTone(to: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
        ], sampleRate: 44_100, channels: 2, seconds: 2)

        let pcm = try VoiceMemoAudioDecoder.pcm16(from: url)
        // AAC pads the start and end by a few thousand samples.
        XCTAssertEqual(Double(pcm.count) / 32_000, 2, accuracy: 0.1)
        let peak = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        XCTAssertGreaterThan(peak, 8_000, "the tone survives the downmix, not silence")
    }

    func testAFileThatIsNotAudioIsUnreadable() throws {
        let url = directory.appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: url)
        XCTAssertThrowsError(try VoiceMemoAudioDecoder.pcm16(from: url)) { error in
            XCTAssertTrue(error is VoiceMemoUnreadable)
        }
    }
}
