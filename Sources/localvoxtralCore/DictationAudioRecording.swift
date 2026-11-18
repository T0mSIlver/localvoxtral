import Foundation
import Synchronization

/// One dictation's microphone audio, kept whole for the opt-in audio store.
///
/// The capture callback appends from the audio thread; the session begins a
/// recording at start and takes it at stop. Unlike `AudioChunkBuffer`, which
/// the send loop drains, nothing here is ever consumed mid-session, so a
/// reconnect gap stays in the recording.
package final class DictationAudioRecording: Sendable {
    /// 16 kHz mono PCM16, as `MicrophoneCaptureService` delivers it.
    package static let sampleRate = 16_000
    /// Longer dictations are not kept: past this the recording stops growing
    /// and `finish` returns nil. 20 minutes is 38 MB of PCM.
    package static let maxSeconds = 20 * 60
    package static let defaultMaxBytes = AudioChunkBuffer.bytesPerSecond * maxSeconds

    private struct State {
        var isRecording = false
        var overflowed = false
        var pcm = Data()
    }

    private let state = Mutex(State())
    private let maxBytes: Int

    package init(maxBytes: Int = DictationAudioRecording.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    /// Starts a new recording, dropping anything a previous session left.
    /// `enabled` false leaves the recording off until the next `begin`.
    package func begin(enabled: Bool) {
        state.withLock { $0 = State(isRecording: enabled) }
    }

    package func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { state in
            guard state.isRecording, !state.overflowed else { return }
            guard state.pcm.count + chunk.count <= maxBytes else {
                state.overflowed = true
                state.pcm = Data()
                return
            }
            state.pcm.append(chunk)
        }
    }

    /// The last `byteCount` bytes recorded so far (all of them when fewer),
    /// starting on a sample; nil when the recording is off, empty or too
    /// long. The recording goes on.
    package func tail(byteCount: Int) -> Data? {
        state.withLock { state in
            guard state.isRecording, !state.overflowed, !state.pcm.isEmpty else { return nil }
            let count = min(max(byteCount, 0), state.pcm.count) & ~1
            guard count > 0 else { return nil }
            return Data(state.pcm.suffix(count))
        }
    }

    /// The session's audio, or nil when it was off, empty or too long. Ends
    /// the recording either way.
    package func finish() -> Data? {
        state.withLock { state in
            defer { state = State() }
            guard state.isRecording, !state.overflowed, !state.pcm.isEmpty else { return nil }
            return state.pcm
        }
    }

    /// A RIFF/WAVE file around mono PCM16 at `sampleRate`: 16 kHz, the
    /// format the eval harness and speechd read, unless a full-quality
    /// recording names its own.
    package static func wav(fromPCM16 pcm: Data, sampleRate: Int = DictationAudioRecording.sampleRate) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)  // block align
        append16(16)  // bits per sample
        append("data")
        append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// Mono PCM16 at the rate the input device ran at, as a full-quality
/// recording keeps it.
package struct FullQualityAudio: Sendable, Equatable {
    package let pcm16: Data
    package let sampleRate: Int

    package init(pcm16: Data, sampleRate: Int) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
    }

    package var seconds: Double { Double(pcm16.count) / Double(sampleRate * 2) }
}

/// One dictation's microphone audio at full quality: the input device's own
/// sample rate, mono, taken from the capture buffer before it is resampled
/// to 16 kHz for recognition. Only the audio store reads it, and only when
/// "Keep audio at full quality" is on.
///
/// Fed from the capture queue beside `DictationAudioRecording`, begun at
/// session start and taken at stop. It holds one rate: a chunk at another
/// one (the device changed rate, or the session moved to another input)
/// drops the recording, since a WAV names a single rate.
package final class FullQualityAudioRecording: Sendable {
    /// What `finish` hands back.
    package enum Outcome: Sendable, Equatable {
        case kept(FullQualityAudio)
        /// Off for this session, or nothing arrived.
        case empty
        /// Longer than `DictationAudioRecording.maxSeconds`.
        case tooLong
        /// The input changed rate mid-dictation.
        case sampleRateChanged

        package var audio: FullQualityAudio? {
            if case .kept(let audio) = self { return audio }
            return nil
        }
    }

    private struct State {
        var isRecording = false
        var sampleRate: Int?
        var dropped: Outcome?
        var pcm = Data()
    }

    private let state = Mutex(State())
    private let maxSeconds: Int

    /// The cap is in seconds, the same as the 16 kHz recording's, so the two
    /// keep or drop the same dictations whatever the device's rate.
    package init(maxSeconds: Int = DictationAudioRecording.maxSeconds) {
        self.maxSeconds = maxSeconds
    }

    /// Starts a new recording, dropping anything a previous session left.
    /// `enabled` false leaves it off until the next `begin`.
    package func begin(enabled: Bool) {
        state.withLock { $0 = State(isRecording: enabled) }
    }

    package var isRecording: Bool { state.withLock { $0.isRecording } }

    package func append(_ chunk: Data, sampleRate: Int) {
        guard !chunk.isEmpty, sampleRate > 0 else { return }
        state.withLock { state in
            guard state.isRecording, state.dropped == nil else { return }
            if let rate = state.sampleRate, rate != sampleRate {
                state.dropped = .sampleRateChanged
                state.pcm = Data()
                return
            }
            state.sampleRate = sampleRate
            guard state.pcm.count + chunk.count <= sampleRate * 2 * maxSeconds else {
                state.dropped = .tooLong
                state.pcm = Data()
                return
            }
            state.pcm.append(chunk)
        }
    }

    /// The session's audio, or why there is none. Ends the recording either
    /// way.
    package func finish() -> Outcome {
        state.withLock { state in
            defer { state = State() }
            if let dropped = state.dropped { return dropped }
            guard state.isRecording, let rate = state.sampleRate, !state.pcm.isEmpty else { return .empty }
            return .kept(FullQualityAudio(pcm16: state.pcm, sampleRate: rate))
        }
    }
}
