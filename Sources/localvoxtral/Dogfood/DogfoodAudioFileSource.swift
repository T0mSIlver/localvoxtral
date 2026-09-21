#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization

/// Feeds a dictation from a WAV file in place of the microphone.
///
/// ## Why it exists
///
/// An end-to-end check of the packaged app needs the same words spoken on
/// every run, on a machine with nobody at it. A loudspeaker into the built-in
/// microphone measures the room; a virtual audio device needs an install and a
/// microphone grant the CI runner's session does not hold. A file needs
/// neither, and everything downstream of the capture callback — chunk
/// buffering, the realtime socket, merging, insertion, polish — is the
/// production path unchanged.
///
/// What it does NOT cover is `MicrophoneCaptureService` itself: AUHAL setup,
/// device selection, format conversion and the health monitor's recovery are
/// all bypassed. Those keep their own suites.
///
/// ## Why the file is named at launch and not over the control socket
///
/// `DogfoodControlSocket` promises that no command carries anything to pretend
/// with, and audio that turns into keystrokes in the focused app is exactly
/// that. So the path comes from the environment of whoever launched the app,
/// who already chose the binary, and the socket keeps its grammar: it can start
/// and stop a dictation, never say what the dictation hears.
///
/// ## Format
///
/// Mono 16-bit PCM at 16 kHz, the realtime client's wire format and the format
/// `scripts/record-agent-eval.sh` writes. Anything else is refused rather than
/// resampled, so a run never scores a conversion this file made up.
final class DogfoodAudioFileSource: Sendable {
    static let environmentKey = "LOCALVOXTRAL_DOGFOOD_AUDIO_FILE"

    typealias ChunkHandler = MicrophoneCaptureService.ChunkHandler
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let sampleRate = 16_000
    static let chunkDuration: Duration = .milliseconds(100)
    /// 100 ms of mono 16-bit samples.
    static let chunkByteCount = sampleRate / 10 * 2

    enum LoadError: Error, Equatable, LocalizedError {
        case unreadable
        case notWAV
        case truncatedChunk
        case missingFormat
        case unsupportedFormat
        case noSamples

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The dogfood audio file could not be read."
            case .notWAV: return "The dogfood audio file is not a RIFF/WAVE file."
            case .truncatedChunk: return "The dogfood audio file has a truncated WAV chunk."
            case .missingFormat: return "The dogfood audio file has no WAV fmt chunk."
            case .unsupportedFormat:
                return "The dogfood audio file must be mono 16-bit PCM at 16000 Hz."
            case .noSamples: return "The dogfood audio file holds no samples."
            }
        }
    }

    /// The file a launch asked for, or nil when it asked for none.
    ///
    /// A relative path is refused: the app's working directory under
    /// LaunchServices is `/`, so it could only ever name the wrong file.
    static func fileURL(fromEnvironment environment: [String: String]) -> URL? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else {
            Log.dictation.error(
                "\(environmentKey, privacy: .public) is not an absolute path; using the microphone")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private struct State {
        var generation = 0
        var task: Task<Void, Never>?
    }

    private let pcm: Data
    private let sleep: Sleep
    private let state = Mutex(State())

    init(pcm: Data, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.pcm = pcm
        self.sleep = sleep
    }

    convenience init(
        contentsOf url: URL,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) throws {
        guard let wav = try? Data(contentsOf: url) else { throw LoadError.unreadable }
        self.init(pcm: try Self.pcm16(fromWAV: wav), sleep: sleep)
    }

    /// Delivers the file in `chunkDuration` pieces at real-time pace, then
    /// silence until `stop()`. A microphone never stops delivering either, and
    /// the stop path flushes whatever audio is buffered when the caller ends
    /// the dictation, so the session sees the shape it sees in production.
    func start(chunkHandler: @escaping ChunkHandler) {
        let pcm = pcm
        let sleep = sleep
        state.withLock { state in
            state.task?.cancel()
            state.generation += 1
            let generation = state.generation
            state.task = Task.detached { [weak self] in
                var offset = 0
                var loggedDrain = false
                let silence = Data(count: Self.chunkByteCount)
                while !Task.isCancelled {
                    let chunk: Data
                    if offset < pcm.count {
                        let end = min(offset + Self.chunkByteCount, pcm.count)
                        chunk = pcm.subdata(in: offset..<end)
                        offset = end
                    } else {
                        if !loggedDrain {
                            loggedDrain = true
                            Log.dictation.notice("dogfood audio file drained; sending silence")
                        }
                        chunk = silence
                    }
                    guard let self, self.deliver(chunk, generation: generation, to: chunkHandler)
                    else { return }
                    do { try await sleep(Self.chunkDuration) } catch { return }
                }
            }
        }
        Log.dictation.notice(
            "dogfood audio file started bytes=\(pcm.count, privacy: .public)")
    }

    /// Once this returns, the handler passed to `start` is never called again.
    /// `stopDictation` flushes the chunk buffer right after stopping capture,
    /// and a chunk landing after that flush would leak into the next session.
    func stop() {
        state.withLock { state in
            state.generation += 1
            state.task?.cancel()
            state.task = nil
        }
    }

    /// Calls the handler under the lock `stop()` takes, which is what makes
    /// `stop()`'s guarantee hold against a delivery already in progress.
    private func deliver(_ chunk: Data, generation: Int, to handler: ChunkHandler) -> Bool {
        state.withLock { state in
            guard state.generation == generation else { return false }
            handler(chunk)
            return true
        }
    }

    static func pcm16(fromWAV wav: Data) throws -> Data {
        guard wav.count >= 12,
              String(data: wav[0..<4], encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE"
        else { throw LoadError.notWAV }

        var format: (code: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var pcm: Data?
        var index = 12
        while index + 8 <= wav.count {
            let chunkID = String(data: wav[index..<(index + 4)], encoding: .ascii) ?? ""
            let size = Int(readLEUInt32(wav, at: index + 4))
            let start = index + 8
            let end = start + size
            guard end <= wav.count else { throw LoadError.truncatedChunk }
            if chunkID == "fmt ", size >= 16 {
                format = (
                    readLEUInt16(wav, at: start),
                    readLEUInt16(wav, at: start + 2),
                    readLEUInt32(wav, at: start + 4),
                    readLEUInt16(wav, at: start + 14)
                )
            } else if chunkID == "data" {
                pcm = wav.subdata(in: start..<end)
            }
            index = end + (size % 2)
        }

        guard let format else { throw LoadError.missingFormat }
        guard format.code == 1, format.channels == 1,
              format.rate == UInt32(sampleRate), format.bits == 16
        else { throw LoadError.unsupportedFormat }
        guard let pcm, pcm.count >= 2 else { throw LoadError.noSamples }
        // A trailing odd byte is half a sample; drop it rather than refuse a
        // file some recorder padded.
        return pcm.count.isMultiple(of: 2) ? pcm : Data(pcm.dropLast())
    }

    private static func readLEUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readLEUInt16(data, at: offset)) | UInt32(readLEUInt16(data, at: offset + 2)) << 16
    }
}

#endif
