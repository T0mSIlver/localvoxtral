import Foundation

extension SpeechASREngine {
    /// No warm-up by default: Voxtral and Nemotron 3.5 run one shape per step from the
    /// first one on.
    public func warmUpSamples(transcriptionDelayMs _: Int?) -> Int { 0 }
}

/// One throwaway session at load, before the helper answers `/health`, so the Metal
/// kernels a dictation needs are compiled before the first one starts.
///
/// Nemotron Unified re-encodes a growing buffer until its left context fills, then a
/// full left + chunk + right window from that step on. On a cold Metal cache the first
/// full window cost 4.8 s (the step at 6.00 s, 70/2/2 frames, MacBook M1 Pro), against
/// 75 ms warm (LVX-111), so the first dictation after an update stalled 6 s in.
public enum EngineWarmUp {
    /// Feeds `samples` of silence to a new session in steps of `stepSamples`, the
    /// server's minimum step, so each window has the shape a live step gives it, then
    /// finishes it. Returns the number of steps fed; 0 opens no session.
    @discardableResult
    public static func run(
        _ engine: SpeechASREngine,
        transcriptionDelayMs: Int?,
        stepSamples: Int,
        utteranceLimit: UtteranceLimit = UtteranceLimit()
    ) -> Int {
        let total = engine.warmUpSamples(transcriptionDelayMs: transcriptionDelayMs)
        guard total > 0, stepSamples > 0 else { return 0 }
        let session = engine.makeSession(
            transcriptionDelayMs: transcriptionDelayMs,
            utteranceLimit: utteranceLimit,
            terms: SessionTerms([])
        )
        let silence = [Float](repeating: 0, count: stepSamples)
        var fed = 0
        var steps = 0
        while fed < total {
            let count = min(stepSamples, total - fed)
            session.step(count == stepSamples ? silence : Array(silence.prefix(count)))
            fed += count
            steps += 1
        }
        session.finish()
        return steps
    }
}

extension NemotronUnifiedLayout {
    /// Audio that takes a session through two full-context steps: the left context, two
    /// chunks, the right context and one frame (6.16 s at the default 70/2/2).
    public static func warmUpSamples(forTranscriptionDelayMs delayMilliseconds: Int?) -> Int {
        let frames = frames(forTranscriptionDelayMs: delayMilliseconds)
        return (frames[0] + 2 * frames[1] + frames[2] + 1) * frameSamples
    }

    /// One encoder frame, 80 ms at 16 kHz.
    public static let frameSamples = 1_280
}
