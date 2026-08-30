@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization
import XCTest

@testable import localvoxtral

/// Regression tests for multi-channel input devices (pro audio interfaces).
///
/// A 16-input Universal Audio Thunderbolt broke capture twice over
/// (field bug, 2026-08-29):
///
/// 1. Its native format — 16ch interleaved Float32, a channel count with no
///    standard layout — makes `AVAudioFormat(streamDescription:)` return nil,
///    so `startCapture` threw `invalidInputFormat` before opening a device
///    that works fine in every browser.
/// 2. Once wrapped (discrete layout), `AVAudioConverter` has no downmix
///    matrix from a discrete multi-channel layout to mono and silently
///    converts every frame to ZEROS — the mic "worked" and dictation heard
///    nothing.
///
/// These tests drive the same two seams the capture path uses
/// (`makeDeviceFormat`, `makeTranscriptionConverter`) with a synthetic
/// 16-channel format, so they run Metal-free and without audio hardware.
final class MicrophoneMultiChannelFormatTests: XCTestCase {

    /// 16ch interleaved Float32 @ 48kHz — byte-for-byte what the interface
    /// reports through kAudioUnitProperty_StreamFormat.
    private func sixteenChannelASBD() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 64,
            mFramesPerPacket: 1,
            mBytesPerFrame: 64,
            mChannelsPerFrame: 16,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func monoTranscriptionFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func testMakeDeviceFormatWrapsSixteenChannelDevice() {
        var asbd = sixteenChannelASBD()

        let format = MicrophoneCaptureService.makeDeviceFormat(&asbd)

        XCTAssertNotNil(
            format,
            "16ch device format must wrap (discrete layout fallback); nil here is the "
                + "\"Microphone input format is invalid\" field failure")
        XCTAssertEqual(format?.channelCount, 16)
        XCTAssertEqual(format?.sampleRate, 48000)
    }

    func testMakeDeviceFormatKeepsStereoUntouched() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let format = MicrophoneCaptureService.makeDeviceFormat(&asbd)

        XCTAssertNotNil(format)
        XCTAssertEqual(format?.channelCount, 2)
    }

    /// The silence bug: convert a 440Hz tone that lives ONLY on channel 0 of
    /// the 16-channel device (where a microphone lives on such interfaces)
    /// and assert the mono output still carries signal. Without the channel
    /// map the converter "succeeds" while writing zeros for every frame.
    func testSixteenChannelToMonoConversionPreservesFirstChannelSignal() throws {
        var asbd = sixteenChannelASBD()
        let inputFormat = try XCTUnwrap(MicrophoneCaptureService.makeDeviceFormat(&asbd))
        let outputFormat = monoTranscriptionFormat()
        let converter = try XCTUnwrap(
            MicrophoneCaptureService.makeTranscriptionConverter(
                from: inputFormat, to: outputFormat))

        let frames: AVAudioFrameCount = 4800
        let inputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        inputBuffer.frameLength = frames
        let samples = try XCTUnwrap(inputBuffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            // Interleaved: channel 0 of each 16-sample frame carries the tone.
            samples[frame * 16] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48000)
        }

        let outputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4000))
        let didFeedInput = Mutex(false)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            let alreadyFed = didFeedInput.withLock { fed in
                let was = fed
                fed = true
                return was
            }
            if alreadyFed {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return inputBuffer
        }

        XCTAssertNil(conversionError)
        XCTAssertGreaterThan(outputBuffer.frameLength, 0)
        let output = try XCTUnwrap(outputBuffer.floatChannelData)[0]
        var sumOfSquares: Float = 0
        for frame in 0..<Int(outputBuffer.frameLength) {
            sumOfSquares += output[frame] * output[frame]
        }
        let rms = (sumOfSquares / Float(outputBuffer.frameLength)).squareRoot()
        // Input RMS is ~0.354; anything close to full level proves the tone
        // survived. The pre-fix converter produced rms == 0 exactly.
        XCTAssertGreaterThan(
            rms, 0.1,
            "mono output is (near-)silent: the multi-channel downmix dropped the "
                + "microphone channel — dictation hears nothing")
    }

    /// Stereo inputs keep the standard downmix (no channel map): a tone on
    /// the LEFT channel must still reach the mono output.
    func testStereoToMonoConversionStillDownmixes() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2,
                interleaved: false))
        let outputFormat = monoTranscriptionFormat()
        let converter = try XCTUnwrap(
            MicrophoneCaptureService.makeTranscriptionConverter(
                from: inputFormat, to: outputFormat))

        let frames: AVAudioFrameCount = 4800
        let inputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        inputBuffer.frameLength = frames
        let left = try XCTUnwrap(inputBuffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            left[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48000)
        }

        let outputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4000))
        let didFeedInput = Mutex(false)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            let alreadyFed = didFeedInput.withLock { fed in
                let was = fed
                fed = true
                return was
            }
            if alreadyFed {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return inputBuffer
        }

        XCTAssertNil(conversionError)
        let output = try XCTUnwrap(outputBuffer.floatChannelData)[0]
        var sumOfSquares: Float = 0
        for frame in 0..<Int(outputBuffer.frameLength) {
            sumOfSquares += output[frame] * output[frame]
        }
        let rms = (sumOfSquares / Float(max(outputBuffer.frameLength, 1))).squareRoot()
        XCTAssertGreaterThan(rms, 0.05)
    }
}
