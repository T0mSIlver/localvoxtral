import Foundation

/// Keeps a Nemotron Unified utterance's audio until its stream emits a token, so an
/// utterance that ends with none can be decoded again offline.
///
/// Greedy RNN-T starts every utterance from the blank state and re-scores each frame
/// against it until it emits once. With the `auto` prompt at speechd's 70/2/2 layout,
/// that first emission can lose to blank on every frame of clear speech, and the whole
/// utterance comes back empty: NeMo itself decodes 0 tokens on eval case
/// i-en-posix-pipe that way (its best token stays 0.46 log-units under blank), while
/// `en` or the full-context offline pass decode it (LVX-113). The offline pass sees
/// the whole utterance at once, so it is the second decode.
///
/// Audio is kept only while the stream has emitted nothing, up to `maxSamples`; the
/// first token drops it. A quiet utterance (no 80 ms window at or above
/// `audibleRMS`) gets no second decode, so a stop on silence stays as cheap as before.
public struct EmptyStreamRedecode: Sendable {
    /// The model's offline pass runs full context up to 60 s.
    public static let defaultMaxSamples = 60 * 16_000
    /// -34 dBFS: far above a quiet room on a laptop mic (about -60 dBFS), far below
    /// speech (the two eval cases peak at -15 and -17 dBFS).
    public static let defaultAudibleRMS: Float = 0.02
    /// 80 ms at 16 kHz, one encoder frame.
    public static let windowSamples = 1_280

    private let maxSamples: Int
    private let audibleRMS: Float
    private var samples: [Float] = []
    private var abandoned = false
    private var audible = false
    private var windowSquares: Float = 0
    private var windowCount = 0

    public init(
        maxSamples: Int = EmptyStreamRedecode.defaultMaxSamples,
        audibleRMS: Float = EmptyStreamRedecode.defaultAudibleRMS
    ) {
        self.maxSamples = maxSamples
        self.audibleRMS = audibleRMS
    }

    /// Records the samples a step fed the stream, and how many tokens the stream has
    /// emitted after that step.
    public mutating func record(_ new: [Float], decodedTokens: Int) {
        guard !abandoned else { return }
        guard decodedTokens == 0, samples.count + new.count <= maxSamples else {
            abandon()
            return
        }
        samples.append(contentsOf: new)
        guard !audible else { return }
        for sample in new {
            windowSquares += sample * sample
            windowCount += 1
            if windowCount == Self.windowSamples {
                if (windowSquares / Float(windowCount)).squareRoot() >= audibleRMS {
                    audible = true
                    return
                }
                windowSquares = 0
                windowCount = 0
            }
        }
    }

    /// The utterance to decode again once the stream has finished, or nil: the stream
    /// emitted a token, the audio ran past `maxSamples`, or none of it was audible.
    public mutating func audioToRedecode(decodedTokens: Int) -> [Float]? {
        defer { abandon() }
        guard !abandoned, decodedTokens == 0 else { return nil }
        if !audible, windowCount > 0,
           (windowSquares / Float(windowCount)).squareRoot() >= audibleRMS {
            audible = true
        }
        return audible ? samples : nil
    }

    private mutating func abandon() {
        abandoned = true
        samples = []
    }
}
