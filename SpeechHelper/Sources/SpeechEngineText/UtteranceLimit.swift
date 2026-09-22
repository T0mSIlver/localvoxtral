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
    /// Default maximum utterance length: a guard against a session nobody meant to leave
    /// running, not a performance ceiling.
    ///
    /// It used to be a ceiling. Against the engine pinned before Blaizzy/mlx-audio-swift
    /// #263-#265, decoding fell behind live speech past about 9 minutes — each 100 ms of
    /// audio took 105 ms at 10 minutes and 147 ms at 60 minutes, and memory climbed about
    /// 23 MB per minute — so the default was 10 minutes. Those three changes bound the
    /// streaming buffers, and `speechd-bench 10800` on the same MacBook Pro at the
    /// production 100 ms cadence holds a mean step of 65-81 ms and active memory flat at
    /// 4.2 GB from 11 minutes through 3 hours. An hour sits well inside that and still
    /// stops a session left running by accident.
    public static let defaultSeconds = 3_600

    /// Tokens decoded past the real audio when `finish()` seals the stream: the engine
    /// appends `(delay tokens + 1) + 10` tokens of zero padding, and the delay tops out at
    /// 2,400 ms (30 tokens at 80 ms). Headroom so a session ending right at the limit still
    /// transcribes its last words. The cost: a session that runs past the limit is cut
    /// about 5 seconds (64 tokens at 80 ms) after it, plus the transcription delay. That is
    /// noise at the default, but dominates a test-sized limit of a few seconds.
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

    /// Longest status message this type may produce. The popover's status row wraps
    /// (`lineLimit(nil)`) inside a 280 pt column, so a longer sentence takes a second line
    /// and grows the whole menu; every other status the app sets is one line.
    public static let maxMessageCharacters = 44

    /// One short sentence for the app's status line (the popover shows one sentence only).
    public var reachedMessage: String {
        let minutes = seconds / 60
        let length = seconds % 60 == 0 && minutes > 0 ? "\(minutes)-minute" : "\(seconds)-second"
        return "\(length) limit reached; start again."
    }

    /// One short sentence for a model end-of-stream before the client finished.
    public static let endOfStreamMessage = "Dictation stopped early; start again."
}

/// Why an engine session stopped producing text before the client asked it to finish.
public enum UtteranceStop: Equatable, Sendable {
    /// The decoded-token cap was hit: later audio is not transcribed.
    case lengthLimit
    /// The model emitted end-of-stream on its own.
    case endOfStream

    /// Classify a session after a streaming step. Returns nil while the session is still
    /// decoding.
    ///
    /// The engine appends each sampled token, stops when the token is EOS or the count
    /// exceeds the cap, and then pops a trailing EOS. So a plain cap stop holds
    /// `max + 1` tokens; an EOS sampled exactly as the count crosses the cap fires both
    /// conditions and holds `max`; an EOS stop below the cap holds at most `max - 1`.
    /// The simultaneous case reports the limit, the actionable reason.
    public static func classify(
        isFinished: Bool,
        decodedTokenCount: Int,
        maxDecodedTokens: Int
    ) -> UtteranceStop? {
        guard isFinished else { return nil }
        return decodedTokenCount >= maxDecodedTokens ? .lengthLimit : .endOfStream
    }
}

/// Per-connection latch so an early stop is reported once per engine session, not on every
/// audio append that follows it.
public struct UtteranceStopReporter: Equatable, Sendable {
    private var reported = false

    public init() {}

    /// Returns the stop to report, or nil when there is nothing new to report. Each
    /// streaming engine classifies its own stop (Voxtral's decoder hits a token cap;
    /// Nemotron's RNN-T never ends a stream, so its session caps the audio it accepts),
    /// hence an already-classified argument.
    ///
    /// The stop is evaluated only while a report is still possible: classifying a Voxtral
    /// session copies its whole token array, and every step after a stop would otherwise
    /// pay for it.
    public mutating func report(_ stop: @autoclosure () -> UtteranceStop?) -> UtteranceStop? {
        guard !reported, let stop = stop() else { return nil }
        reported = true
        return stop
    }

    /// Call when the engine session is dropped (final commit, clear, disconnect).
    public mutating func reset() {
        reported = false
    }
}
