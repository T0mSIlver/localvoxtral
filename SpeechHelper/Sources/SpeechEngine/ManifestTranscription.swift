import Foundation
import MLX
import SpeechEngineText

/// `--transcribe <manifest.json>`: one engine session per recording of an
/// agent-dictation manifest (`{"recordings": [{"id", "file"}]}`, files relative to
/// the manifest), fed in `--step-ms` steps as fast as the engine runs, as a
/// dictation's stop flushes it. Prints `TRANSCRIBE {"id","text"}` per recording,
/// so an eval can score an engine build without a running server.
public enum ManifestTranscription {
    private struct Manifest: Decodable {
        struct Recording: Decodable {
            let id: String
            let file: String
        }
        let recordings: [Recording]
    }

    private struct Line: Encodable {
        let id: String
        let text: String
        /// Set when the engine stopped the stream early; later audio went untranscribed.
        let stopped: String?
    }

    public static func run(_ options: SpeechdLaunchOptions) async throws {
        guard let manifestPath = options.transcribeManifest else { return }
        Memory.cacheLimit = options.cacheLimitMB * 1024 * 1024
        let engine = try await SpeechModelLoader.load(
            modelID: options.modelID,
            modelRevision: options.modelRevision,
            modelDirectory: options.modelDirectory,
            engine: options.engine
        )
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let step = options.stepMilliseconds * 16
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The first recording also pays the one-time kernel compilation, so the
        // summary times the rest; the first one's seconds print on their own.
        var audioSeconds = 0.0
        var firstSeconds = 0.0
        var start = Date()
        for (index, recording) in manifest.recordings.enumerated() {
            let path = manifestURL.deletingLastPathComponent().appendingPathComponent(recording.file).path
            let audio = try BenchmarkAudio.loadWAV(path: path)
            audioSeconds += Double(audio.count) / 16_000
            let session = engine.makeSession(
                transcriptionDelayMs: options.transcriptionDelayMs,
                utteranceLimit: options.utteranceLimit
            )
            var offset = 0
            while offset < audio.count {
                let end = min(offset + step, audio.count)
                _ = session.step(Array(audio[offset..<end]))
                offset = end
            }
            _ = session.finish()
            let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stopped = session.utteranceStop.map { String(describing: $0) }
            let json = try encoder.encode(Line(id: recording.id, text: text, stopped: stopped))
            print("TRANSCRIBE " + String(decoding: json, as: UTF8.self))
            Memory.clearCache()
            if index == 0 {
                firstSeconds = Date().timeIntervalSince(start)
                audioSeconds = 0
                start = Date()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(
            format: "TRANSCRIBE done n=%d first_s=%.1f rest_audio_s=%.1f rest_decode_s=%.1f rtf=%.3f peak_mb=%.0f",
            manifest.recordings.count, firstSeconds, audioSeconds, elapsed,
            audioSeconds > 0 ? elapsed / audioSeconds : 0,
            Double(Memory.snapshot().peakMemory) / 1_048_576
        ))
    }
}
