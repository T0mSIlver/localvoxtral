@preconcurrency import AVFoundation
import XCTest

@testable import localvoxtral

/// The full-quality copy of each capture buffer (`makeFullQualityConverter`):
/// mono PCM16 at the device's own rate, frame for frame, where the
/// transcription converter resamples to 16 kHz. Synthetic formats, no audio
/// hardware.
final class MicrophoneFullQualityConverterTests: XCTestCase {
    /// A mono 48 kHz device: every frame comes through at 48 kHz, each sample
    /// the input's own value in 16 bits.
    func testAMonoBufferComesThroughFrameForFrameAtTheDevicesRate() throws {
        let input = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let samples = (0..<480).map { Float($0 % 100) / 200 - 0.25 }
        let buffer = try floatBuffer(input, channels: [samples])
        let converter = try XCTUnwrap(MicrophoneCaptureService.makeFullQualityConverter(from: input))

        let pcm = try XCTUnwrap(
            MicrophoneCaptureService.convertToPCM16Mono(
                buffer: buffer, converter: converter.converter, outputFormat: converter.outputFormat))

        XCTAssertEqual(converter.sampleRate, 48_000)
        let values = int16s(pcm)
        XCTAssertEqual(values.count, samples.count, "a resampler ran: the frame count changed")
        for (value, sample) in zip(values, samples) {
            XCTAssertEqual(Double(value), Double(sample) * 32_767, accuracy: 2)
        }
    }

    /// A stereo device at 44.1 kHz: one channel out, at 44.1 kHz, with the
    /// same downmix as the 16 kHz path (#1627), so a mic on the second input
    /// is not silent.
    func testAStereoBufferIsMixedDownAtItsOwnRate() throws {
        let input = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let silent = [Float](repeating: 0, count: 441)
        let tone = (0..<441).map { sin(Float($0) * 2 * .pi * 440 / 44_100) * 0.5 }
        let buffer = try floatBuffer(input, channels: [silent, tone])
        let converter = try XCTUnwrap(MicrophoneCaptureService.makeFullQualityConverter(from: input))

        let pcm = try XCTUnwrap(
            MicrophoneCaptureService.convertToPCM16Mono(
                buffer: buffer, converter: converter.converter, outputFormat: converter.outputFormat))

        XCTAssertEqual(converter.sampleRate, 44_100)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        let values = int16s(pcm)
        XCTAssertEqual(values.count, 441)
        XCTAssertGreaterThan(values.map { abs(Int($0)) }.max() ?? 0, 3_000, "the second input's tone was dropped")
    }

    private func floatBuffer(_ format: AVAudioFormat, channels: [[Float]]) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(channels[0].count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (channel, samples) in channels.enumerated() {
            for (index, sample) in samples.enumerated() { data[channel][index] = sample }
        }
        return buffer
    }

    private func int16s(_ pcm: Data) -> [Int16] {
        pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
