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

    /// The session's audio, or nil when it was off, empty or too long. Ends
    /// the recording either way.
    package func finish() -> Data? {
        state.withLock { state in
            defer { state = State() }
            guard state.isRecording, !state.overflowed, !state.pcm.isEmpty else { return nil }
            return state.pcm
        }
    }

    /// A RIFF/WAVE file around 16 kHz mono PCM16, the format the eval harness
    /// and speechd read.
    package static func wav(fromPCM16 pcm: Data) -> Data {
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
