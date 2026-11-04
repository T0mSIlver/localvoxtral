import Foundation

/// Nemotron ASR streams in fixed chunks of encoder frames, 80 ms each, and
/// its model card publishes word-error rates for a few chunk sizes. The chunk is
/// the engine's latency: no text comes out of a chunk until all of it is in.
/// This maps the helper's `--transcription-delay-ms` knob (Voxtral's native
/// unit) onto Nemotron 3.5's ladder, so one app-level setting drives both
/// engines. Nemotron Unified takes the chosen value as its latency (chunk plus
/// right context) and snaps it to the nearest of its own table (160, 240, 320,
/// 560, 1120, 2080 ms); the default 320 ms is one of them.
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
