/// When a Voxtral stop may end its flush early (LVX-110).
///
/// The engine's `finish()` appends the offline right pad, `(delay + 1) + 10` tokens of
/// zeros, and decodes every one of them: 18 decoder steps at the 480 ms delay, though the
/// text is usually done long before. The adapter instead feeds those zeros through
/// `step` and stops once the decoder is past the last real audio token by the
/// transcription delay and has read `padTokens` streaming-pad tokens in a row.
///
/// Positions are the decoder's: the token read at position p saw audio rows below p, and
/// the model emits a row's text `delayTokens` later, so from `realRegion + delayTokens` on
/// every real row has had its delay. The arithmetic mirrors mlx-audio-swift's
/// `numAudioTokens` / `numDelayTokens`, which are internal there.
public struct SilentTailStop: Sendable {
    /// 16 kHz samples per decoder token (12.5 tokens a second).
    public static let samplesPerToken = 1_280
    private static let hopLength = 160
    private static let framesPerToken = 8

    /// The first decoder position whose token counts toward the stop.
    public let fromPosition: Int
    public let padTokens: Int
    public let padTokenId: Int
    private var silentRun = 0

    /// - Parameters:
    ///   - realSamples: the audio the session took before the stop.
    ///   - delayMs: the session's transcription delay.
    public init(
        realSamples: Int,
        delayMs: Int,
        leftPadTokens: Int,
        padTokens: Int,
        padTokenId: Int
    ) {
        let realRegion = leftPadTokens + Self.audioTokens(samples: realSamples)
        self.fromPosition = realRegion + Self.delayTokens(delayMs: delayMs)
        self.padTokens = max(1, padTokens)
        self.padTokenId = padTokenId
    }

    /// Feed each decoded token with its position, in order. True once the flush may stop.
    public mutating func observe(token: Int, position: Int) -> Bool {
        guard position >= fromPosition else { return false }
        silentRun = token == padTokenId ? silentRun + 1 : 0
        return silentRun >= padTokens
    }

    /// The offline right pad in tokens: `(delay + 1) + 10`.
    public static func rightPadTokens(delayMs: Int) -> Int {
        delayTokens(delayMs: delayMs) + 1 + 10
    }

    /// Zeros that bring `samples` to a whole token, as the offline pad does first.
    public static func alignmentSamples(after samples: Int) -> Int {
        (samplesPerToken - samples % samplesPerToken) % samplesPerToken
    }

    public static func delayTokens(delayMs: Int) -> Int {
        audioTokens(samples: Int(Double(delayMs) / 1000.0 * 16_000))
    }

    public static func audioTokens(samples: Int) -> Int {
        let frames = samples % hopLength != 0
            ? Int((Double(samples) / Double(hopLength) - 1.0).rounded(.up))
            : samples / hopLength
        return Int((Double(frames) / Double(framesPerToken)).rounded(.up))
    }
}
