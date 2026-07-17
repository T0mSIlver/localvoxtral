import Foundation
import MLX
import MLXAudioSTT
import SpeechEngineText

/// Packaged-helper benchmark for the streaming front-end recomputation path.
public enum StreamingSpeechBenchmark {
    private static let sampleRate = 16_000
    private static let appendSamples = 1_600

    public static func run(_ options: SpeechdLaunchOptions) async throws {
        guard let benchmark = options.benchmark else { return }

        Memory.cacheLimit = options.cacheLimitMB * 1024 * 1024
        let model = try await SpeechModelLoader.load(
            modelID: options.modelID,
            modelRevision: options.modelRevision,
            modelDirectory: options.modelDirectory
        )
        let audio = try BenchmarkAudio.make(
            seconds: benchmark.seconds,
            wavPath: benchmark.wavPath
        )
        let session = model.makeStreamSession(
            temperature: 0.0,
            transcriptionDelayMs: options.transcriptionDelayMs
        )
        var batcher = StepBatcher(
            cadenceMilliseconds: benchmark.cadenceMilliseconds,
            sampleRate: sampleRate
        )
        var records: [StepRecord] = []
        let marks = [5, 15, 30, 60].filter { $0 <= benchmark.seconds }
        var nextMarkIndex = 0
        var appendedSamples = 0
        var steppedSamples = 0
        var offset = 0

        while offset < audio.count {
            let end = min(offset + appendSamples, audio.count)
            let chunk = Array(audio[offset..<end])
            appendedSamples += chunk.count
            for batch in batcher.append(chunk) {
                steppedSamples += batch.count
                records.append(measureStep(session: session, samples: batch, at: steppedSamples))
            }
            offset = end

            while nextMarkIndex < marks.count,
                  appendedSamples >= marks[nextMarkIndex] * sampleRate
            {
                printMark(
                    marks[nextMarkIndex],
                    cadenceMilliseconds: benchmark.cadenceMilliseconds,
                    records: records
                )
                nextMarkIndex += 1
            }
        }

        let remainder = batcher.flushRemainder()
        if !remainder.isEmpty {
            steppedSamples += remainder.count
            records.append(measureStep(session: session, samples: remainder, at: steppedSamples))
        }

        // A nonstandard duration/cadence can put its final remainder exactly at a mark. Reprint
        // only marks not already reported; normal 60 s runs reach every mark in the loop above.
        while nextMarkIndex < marks.count {
            printMark(
                marks[nextMarkIndex],
                cadenceMilliseconds: benchmark.cadenceMilliseconds,
                records: records
            )
            nextMarkIndex += 1
        }
    }

    private struct StepRecord {
        let audioSamples: Int
        let latencyMilliseconds: Double
        let memory: Memory.Snapshot
    }

    private static func measureStep(
        session: VoxtralRealtimeStreamSession,
        samples: [Float],
        at audioSamples: Int
    ) -> StepRecord {
        let duration = ContinuousClock().measure {
            session.step(samples)
        }
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return StepRecord(
            audioSamples: audioSamples,
            latencyMilliseconds: milliseconds,
            memory: Memory.snapshot()
        )
    }

    private static func printMark(
        _ markSeconds: Int,
        cadenceMilliseconds: Int,
        records: [StepRecord]
    ) {
        let markSamples = markSeconds * sampleRate
        guard let current = records.last(where: { $0.audioSamples <= markSamples }) ?? records.last else {
            return
        }
        let trailingStart = max(0, current.audioSamples - sampleRate)
        let trailing = records.filter {
            $0.audioSamples > trailingStart && $0.audioSamples <= current.audioSamples
        }
        let mean = trailing.map(\.latencyMilliseconds).reduce(0, +)
            / Double(max(1, trailing.count))
        let activeValues = trailing.map { $0.memory.activeMemory }
        let swing = (activeValues.max() ?? current.memory.activeMemory)
            - (activeValues.min() ?? current.memory.activeMemory)
        let bytesPerMB = 1024.0 * 1024.0

        print(
            String(
                format:
                    "BENCH mark=%ds cadence_ms=%d steps=%d step_ms=%.3f mean_ms=%.3f "
                    + "active_mb=%.1f cache_mb=%.1f peak_mb=%.1f swing_mb=%.1f",
                markSeconds,
                cadenceMilliseconds,
                records.filter { $0.audioSamples <= markSamples }.count,
                current.latencyMilliseconds,
                mean,
                Double(current.memory.activeMemory) / bytesPerMB,
                Double(current.memory.cacheMemory) / bytesPerMB,
                Double(current.memory.peakMemory) / bytesPerMB,
                Double(swing) / bytesPerMB
            )
        )
    }
}

private enum BenchmarkAudio {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidWAV(String)

        var description: String {
            switch self {
            case .invalidWAV(let message): return "invalid benchmark WAV: \(message)"
            }
        }
    }

    static func make(seconds: Int, wavPath: String?) throws -> [Float] {
        let targetCount = seconds * 16_000
        let source = try wavPath.map(loadWAV) ?? synthesizeSpeechBandNoise(count: targetCount)
        guard !source.isEmpty else { throw Error.invalidWAV("audio data is empty") }
        if source.count == targetCount { return source }

        var looped: [Float] = []
        looped.reserveCapacity(targetCount)
        while looped.count < targetCount {
            looped.append(contentsOf: source.prefix(targetCount - looped.count))
        }
        return looped
    }

    private static func loadWAV(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw Error.invalidWAV("not a RIFF/WAVE file")
        }

        var format: (code: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var pcm: Data?
        var index = 12
        while index + 8 <= data.count {
            let chunkID = String(data: data[index..<(index + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32(data, at: index + 4))
            let start = index + 8
            let end = start + size
            guard end <= data.count else { throw Error.invalidWAV("truncated chunk") }
            if chunkID == "fmt ", size >= 16 {
                format = (
                    readUInt16(data, at: start),
                    readUInt16(data, at: start + 2),
                    readUInt32(data, at: start + 4),
                    readUInt16(data, at: start + 14)
                )
            } else if chunkID == "data" {
                pcm = data.subdata(in: start..<end)
            }
            index = end + (size & 1)
        }

        guard let format, let pcm else {
            throw Error.invalidWAV("missing fmt or data chunk")
        }
        guard format.channels == 1, format.rate == 16_000 else {
            throw Error.invalidWAV("expected mono 16000 Hz audio")
        }
        guard format.code == 1, format.bits == 16 else {
            throw Error.invalidWAV("expected 16-bit integer PCM")
        }

        var samples: [Float] = []
        samples.reserveCapacity(pcm.count / 2)
        var sampleIndex = 0
        while sampleIndex + 1 < pcm.count {
            let bits = UInt16(pcm[sampleIndex]) | (UInt16(pcm[sampleIndex + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            sampleIndex += 2
        }
        return samples
    }

    private static func synthesizeSpeechBandNoise(count: Int) -> [Float] {
        var state: UInt32 = 0x5EED_1234
        var lowPass: Float = 0
        var slow: Float = 0
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            let white = Float(state >> 8) / Float(1 << 24) * 2 - 1
            lowPass += 0.35 * (white - lowPass)
            slow += 0.01 * (lowPass - slow)
            return (lowPass - slow) * 0.08
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
