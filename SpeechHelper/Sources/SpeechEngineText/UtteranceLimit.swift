import Foundation

/// How long one utterance (one engine stream session) may run before the engine stops
/// decoding, and how the helper reports that stop.
///
/// The engine's stream session caps the number of decoded tokens and, on reaching it,
/// marks itself finished and returns nothing from every later step. It decodes one token
/// per audio frame (padding included), so the cap is a duration. Left at the engine's
/// default of 4,096 tokens it cut dictation off after about 5.5 minutes with no signal to
/// the app (#314). The helper now sizes the cap from an explicit duration and reports the
/// stop instead of going quiet.
public struct UtteranceLimit: Equatable, Sendable {
    /// Default maximum utterance length: the longest session that stays close to real time.
    /// Measured with `speechd-bench 1200` on an M-series MacBook Pro at the production
    /// 100 ms cadence (2026-09-16, #314): the mean step took 63 ms at 1 minute, 96 ms at
    /// 8 minutes, 107 ms at 10 minutes and plateaued around 100-115 ms once the decoder's
    /// 8,192-token attention window filled near 11 minutes. Past about 9 minutes each
    /// 100 ms of audio takes longer than 100 ms to decode, so live text starts lagging the
    /// speaker. Memory grew from 2.7 GB to 4.6 GB over 20 minutes.
    public static let defaultSeconds = 600

    /// Tokens decoded past the real audio when `finish()` seals the stream: the engine
    /// appends `(delay tokens + 1) + 10` tokens of zero padding, and the delay tops out at
    /// 2,400 ms (30 tokens at 80 ms). Headroom so a session ending right at the limit still
    /// transcribes its last words.
    public static let finishPaddingTokens = 64

    public let seconds: Int

    public init(seconds: Int = UtteranceLimit.defaultSeconds) {
        self.seconds = seconds
    }

    /// The engine's `maxTokens` for this limit at the model's decoder frame rate
    /// (tokens per second of audio; 12.5 for Voxtral Realtime).
    public func maxDecodedTokens(frameRate: Float) -> Int {
        let audioTokens = (Double(seconds) * Double(frameRate)).rounded(.up)
        return Int(audioTokens) + Self.finishPaddingTokens
    }

    /// One short sentence for the app's status line (the popover shows one line only).
    public var reachedMessage: String {
        let minutes = seconds / 60
        let length = seconds % 60 == 0 && minutes > 0 ? "\(minutes)-minute" : "\(seconds)-second"
        return "Dictation reached the \(length) limit. Stop and start again to continue."
    }
}

/// Why an engine session stopped producing text before the client asked it to finish.
public enum UtteranceStop: Equatable, Sendable {
    /// The decoded-token cap was hit: later audio is not transcribed.
    case lengthLimit
    /// The model emitted end-of-stream on its own.
    case endOfStream

    /// Classify a session after a streaming step. Returns nil while the session is still
    /// decoding. The engine appends the token that crosses the cap before stopping, so a
    /// capped session holds more than `maxDecodedTokens` tokens; an end-of-stream stop
    /// strips its EOS token and holds at most that many.
    public static func classify(
        isFinished: Bool,
        decodedTokenCount: Int,
        maxDecodedTokens: Int
    ) -> UtteranceStop? {
        guard isFinished else { return nil }
        return decodedTokenCount > maxDecodedTokens ? .lengthLimit : .endOfStream
    }
}

/// Per-connection latch so an early stop is reported once per engine session, not on every
/// audio append that follows it.
public struct UtteranceStopReporter: Equatable, Sendable {
    private var reported = false

    public init() {}

    /// Returns the stop to report, or nil when there is nothing new to report.
    public mutating func check(
        isFinished: Bool,
        decodedTokenCount: Int,
        maxDecodedTokens: Int
    ) -> UtteranceStop? {
        guard !reported,
              let stop = UtteranceStop.classify(
                isFinished: isFinished,
                decodedTokenCount: decodedTokenCount,
                maxDecodedTokens: maxDecodedTokens
              )
        else { return nil }
        reported = true
        return stop
    }

    /// Call when the engine session is dropped (final commit, clear, disconnect).
    public mutating func reset() {
        reported = false
    }
}
