import Foundation
import MLX
import SpeechEngineText

/// One throwaway dictation before the helper serves. The first steps after a load
/// compile kernels and make the first reads of the weights, which costs the first
/// dictation after every helper start (`speechd-bench`'s `BENCH warmup` line); this
/// moves that cost before `ready`, so every dictation runs at full speed.
enum SpeechEngineWarmUp {
    /// Long enough to reach the decoder's prefill and several decode steps after it.
    static let seconds = 2

    /// Steps `seconds` of quiet noise through a session in `stepMilliseconds` batches,
    /// finishes it, drops it, and clears the MLX cache, as the server does after a
    /// dictation, so idle memory is back at the weight floor.
    static func run(
        engine: any SpeechASREngine,
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit,
        stepMilliseconds: Int
    ) -> Duration {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let session = engine.makeSession(
                transcriptionDelayMs: transcriptionDelayMs,
                utteranceLimit: utteranceLimit
            )
            let samples = quietNoise(count: seconds * 16_000)
            let step = max(1, stepMilliseconds * 16)
            var offset = 0
            while offset < samples.count {
                let end = min(offset + step, samples.count)
                session.step(Array(samples[offset..<end]))
                offset = end
            }
            session.finish()
        }
        Memory.clearCache()
        return clock.now - started
    }

    /// Deterministic noise around -50 dBFS: audio-like input without words.
    private static func quietNoise(count: Int) -> [Float] {
        var state: UInt32 = 0x2545_F491
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.006
        }
    }
}
