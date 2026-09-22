import Foundation

/// Nemotron 3.5 ASR streams in fixed chunks of encoder frames, 80 ms each, and
/// its model card publishes word-error rates for five chunk sizes. The chunk is
/// the engine's latency: no text comes out of a chunk until all of it is in.
/// This maps the helper's `--transcription-delay-ms` knob (Voxtral's native
/// unit) onto that ladder, so one app-level setting drives both engines.
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
