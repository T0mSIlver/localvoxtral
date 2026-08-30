@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization
import XCTest

@testable import localvoxtral

/// Follow-up to the multi-channel work in #240, which hardcoded the FIRST
/// input channel. A microphone sits on one preamp of a multi-input interface,
/// and not necessarily the first, so the channel is now a user choice — and
/// the AUHAL narrows its own input bus to that one channel where it can,
/// instead of rendering all 16 and discarding 15.
///
/// These drive the pure seams (`resolvedCaptureChannel`, `narrowedClientFormat`,
/// `makeTranscriptionConverter`) with synthetic formats, so they need no audio
/// hardware. The AUHAL property calls themselves need a real multi-channel
/// device and are hand-verified (see the PR).
final class MicrophoneInputChannelTests: XCTestCase {

    private func multiChannelASBD(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func monoTranscriptionFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    // MARK: - Channel clamping

    func testChannelWithinRangeIsKept() {
        XCTAssertEqual(MicrophoneCaptureService.resolvedCaptureChannel(5, channelCount: 16), 5)
    }

    /// The selection persists across launches while devices come and go: an
    /// index left over from a 16-in interface must not address channel 9 of a
    /// stereo device.
    func testChannelPastDeviceChannelCountFallsBackToFirst() {
        XCTAssertEqual(MicrophoneCaptureService.resolvedCaptureChannel(9, channelCount: 2), 0)
        XCTAssertEqual(MicrophoneCaptureService.resolvedCaptureChannel(0, channelCount: 0), 0)
        XCTAssertEqual(MicrophoneCaptureService.resolvedCaptureChannel(-1, channelCount: 16), 0)
    }

    // MARK: - AUHAL client format

    func testNarrowedClientFormatIsSingleChannelAtDeviceRate() throws {
        let narrowed = try XCTUnwrap(
            MicrophoneCaptureService.narrowedClientFormat(
                from: multiChannelASBD(channels: 16), channel: 3))

        XCTAssertEqual(narrowed.mChannelsPerFrame, 1)
        XCTAssertEqual(narrowed.mSampleRate, 48000)
        // One float32 sample per frame — this is what stops the AUHAL from
        // copying 16 channels into every render buffer.
        XCTAssertEqual(narrowed.mBytesPerFrame, 4)
        XCTAssertEqual(narrowed.mBytesPerPacket, 4)
        XCTAssertEqual(narrowed.mBitsPerChannel, 32)
    }

    /// Mono and stereo devices must keep the device format and the standard
    /// downmix; narrowing them would be a behaviour change for every ordinary
    /// microphone.
    func testNarrowedClientFormatDeclinesMonoAndStereo() {
        XCTAssertNil(
            MicrophoneCaptureService.narrowedClientFormat(
                from: multiChannelASBD(channels: 1), channel: 0))
        XCTAssertNil(
            MicrophoneCaptureService.narrowedClientFormat(
                from: multiChannelASBD(channels: 2), channel: 0))
    }

    func testNarrowedClientFormatDeclinesOutOfRangeChannel() {
        XCTAssertNil(
            MicrophoneCaptureService.narrowedClientFormat(
                from: multiChannelASBD(channels: 16), channel: 16))
    }

    // MARK: - Converter fallback

    /// When the AUHAL declines the narrowing, the converter must still pull the
    /// SELECTED channel, not channel 0. Tone lives only on channel 7.
    func testConverterFallbackPullsTheSelectedChannel() throws {
        var asbd = multiChannelASBD(channels: 16)
        let inputFormat = try XCTUnwrap(MicrophoneCaptureService.makeDeviceFormat(&asbd))
        let outputFormat = monoTranscriptionFormat()
        let converter = try XCTUnwrap(
            MicrophoneCaptureService.makeTranscriptionConverter(
                from: inputFormat, to: outputFormat, channel: 7))

        let rms = try monoRMS(converter: converter, inputFormat: inputFormat, tonedChannel: 7)
        XCTAssertGreaterThan(
            rms, 0.1,
            "the converter dropped the selected channel: dictation would hear silence")
    }

    /// The complement: asking for channel 7 must NOT pick up a tone sitting on
    /// channel 0, or the selection is decorative.
    func testConverterFallbackIgnoresUnselectedChannels() throws {
        var asbd = multiChannelASBD(channels: 16)
        let inputFormat = try XCTUnwrap(MicrophoneCaptureService.makeDeviceFormat(&asbd))
        let outputFormat = monoTranscriptionFormat()
        let converter = try XCTUnwrap(
            MicrophoneCaptureService.makeTranscriptionConverter(
                from: inputFormat, to: outputFormat, channel: 7))

        let rms = try monoRMS(converter: converter, inputFormat: inputFormat, tonedChannel: 0)
        XCTAssertLessThan(rms, 0.01, "channel 0 leaked into a capture that selected channel 7")
    }

    /// An out-of-range stored channel must not produce a silent converter; it
    /// clamps to the first channel like the rest of the path.
    func testConverterClampsOutOfRangeChannel() throws {
        var asbd = multiChannelASBD(channels: 16)
        let inputFormat = try XCTUnwrap(MicrophoneCaptureService.makeDeviceFormat(&asbd))
        let outputFormat = monoTranscriptionFormat()
        let converter = try XCTUnwrap(
            MicrophoneCaptureService.makeTranscriptionConverter(
                from: inputFormat, to: outputFormat, channel: 99))

        let rms = try monoRMS(converter: converter, inputFormat: inputFormat, tonedChannel: 0)
        XCTAssertGreaterThan(rms, 0.1)
    }

    // MARK: - Helper

    /// Feeds a 440Hz tone placed on exactly one channel of an interleaved
    /// multi-channel buffer and returns the RMS of the mono output.
    private func monoRMS(
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        tonedChannel: Int
    ) throws -> Float {
        let frames: AVAudioFrameCount = 4800
        let stride = Int(inputFormat.channelCount)
        let inputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        inputBuffer.frameLength = frames
        let samples = try XCTUnwrap(inputBuffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            samples[frame * stride + tonedChannel] =
                0.5 * sin(2 * .pi * 440 * Float(frame) / 48000)
        }

        let outputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4000))
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
        return (sumOfSquares / Float(outputBuffer.frameLength)).squareRoot()
    }
}
