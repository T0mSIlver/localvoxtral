import Foundation

/// Nemotron ASR streams in fixed chunks of encoder frames, 80 ms each, and
/// its model card publishes word-error rates for a few chunk sizes. The chunk is
/// the engine's latency: no text comes out of a chunk until all of it is in.
/// This maps the helper's `--transcription-delay-ms` knob (Voxtral's native
/// unit) onto Nemotron 3.5's ladder, so one app-level setting drives both
/// engines. Nemotron Unified takes the rung as its latency; see
/// `NemotronUnifiedLayout`.
public enum NemotronChunkLadder {
    /// The rungs the model card measures, in milliseconds.
    public static let supportedMilliseconds = [80, 160, 320, 560, 1120]

    /// Used when the caller asks for no particular delay. The checkpoint's own
    /// default is the top rung (1120 ms, `default_att_context_size` [56, 13]),
    /// which is over a second of lag on live dictation; 320 ms is the highest
    /// rung that still feels live, and the model card's accuracy cost over the
    /// rungs above it is small.
    public static let defaultMilliseconds = 320

    /// The largest rung that fits inside `delayMilliseconds`, so the engine
    /// never holds text back longer than the caller asked. Below the bottom
    /// rung there is nothing to pick but the bottom rung.
    public static func chunkMilliseconds(forTranscriptionDelayMs delayMilliseconds: Int?) -> Int {
        guard let delayMilliseconds else { return defaultMilliseconds }
        return supportedMilliseconds.last { $0 <= delayMilliseconds }
            ?? supportedMilliseconds[0]
    }
}

/// Nemotron Unified streams buffered: each step re-encodes left context + chunk +
/// right context, in 80 ms encoder frames, so the layout sets both the latency
/// (chunk + right) and the GPU cost (frames re-encoded per chunk). These are
/// NVIDIA's recommended rows with its 5.6 s left context, except at 320 ms: a
/// 160 ms chunk with 160 ms right context halves the GPU per audio second (MacBook:
/// 34.7 vs 68.6 ms per 80 ms step) for +0.6 WER points (NeMo, 50 FLEURS clips in 10
/// languages: 12.67 vs 12.08 %).
public enum NemotronUnifiedLayout {
    public static let leftFrames = 70

    /// `[left, chunk, right]` encoder frames for a `NemotronChunkLadder` rung.
    public static func frames(forLatencyMilliseconds latency: Int) -> [Int] {
        switch latency {
        case ..<240: return [leftFrames, 1, 1]
        case ..<560: return [leftFrames, 2, 2]
        case ..<1120: return [leftFrames, 2, 5]
        default: return [leftFrames, 7, 7]
        }
    }
}
