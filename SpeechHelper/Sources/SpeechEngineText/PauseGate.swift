/// Keeps the model from stepping every 80 ms through a pause (LVX-126).
///
/// Voxtral costs the same for a silent frame as for a spoken one, and about a third
/// of a dictation is pauses. The gate is open while somebody speaks: every batch of
/// audio goes to the model as it arrives. It closes once the detector has heard no
/// speech and the decoder has read `padTokens` pad tokens in a row that all stand
/// after the last speech, so the model has finished writing the phrase. Closed, the
/// audio collects in a buffer of `holdSamples`, and speech opens the gate and feeds
/// the buffer first. What a full buffer does is the mode:
///
/// - `hold` feeds it as one step. The model hears the same audio in fewer, larger
///   steps, which cost less than the 80 ms ones they replace.
/// - `drop` discards the oldest audio. The model never hears the middle of a long
///   pause: cheaper, and no longer the same input.
///
/// A token the model writes on quiet audio (it heard what the detector did not)
/// opens the gate too.
public struct PauseGate: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        case hold
        case drop
    }

    public struct Configuration: Sendable, Equatable {
        public var mode: Mode
        /// Pad tokens in a row, all standing after the last speech, that close the gate.
        public var padTokens = 3
        /// Audio kept while closed: what the model hears before the next speech, and
        /// the longest step `hold` makes. 480 ms.
        public var holdSamples = 7_680
        /// From the end of the audio the engine has taken back to the start of the
        /// frame its newest token stands on. A pad counts only when that frame starts
        /// after the last speech.
        public var newestTokenLagSamples: Int
        public var samplesPerToken = 1_280

        public init(mode: Mode, newestTokenLagSamples: Int) {
            self.mode = mode
            self.newestTokenLagSamples = newestTokenLagSamples
        }
    }

    /// What one utterance's gate did, for the helper log.
    public struct Stats: Sendable, Equatable {
        public var closes = 0
        public var droppedSamples = 0
        /// Audio that reached the model in a step larger than it arrived in.
        public var heldSamples = 0
    }

    public let configuration: Configuration
    public private(set) var isOpen = false
    public private(set) var stats = Stats()
    /// Audio since the last speech the detector heard.
    private var silentSamples = Int.max / 2
    private var padRun = 0
    private var held: [Float] = []

    /// A new utterance starts closed: nobody has spoken, so nothing is being written.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Takes a batch of audio and where the last speech in it ended (the detector's
    /// answer, nil for none). Returns the audio the model steps now, or nil when the
    /// gate keeps it.
    public mutating func admit(_ samples: [Float], lastSpeechEnd: Int?) -> [Float]? {
        if let lastSpeechEnd {
            silentSamples = samples.count - lastSpeechEnd
            padRun = 0
        } else {
            silentSamples += samples.count
        }
        if isOpen { return samples }
        held.append(contentsOf: samples)
        if lastSpeechEnd != nil {
            isOpen = true
            return releaseHeld(beyond: samples.count)
        }
        guard held.count >= configuration.holdSamples else { return nil }
        switch configuration.mode {
        case .hold:
            return releaseHeld(beyond: samples.count)
        case .drop:
            let excess = held.count - configuration.holdSamples
            held.removeFirst(excess)
            stats.droppedSamples += excess
            return nil
        }
    }

    /// The tokens the model decoded from the audio `admit` last returned, oldest first.
    public mutating func observe(tokensArePads: [Bool]) {
        for (index, isPad) in tokensArePads.enumerated() {
            let newer = tokensArePads.count - 1 - index
            let standsAfterSpeech = silentSamples
                >= configuration.newestTokenLagSamples + newer * configuration.samplesPerToken
            padRun = isPad && standsAfterSpeech ? padRun + 1 : 0
            // The model wrote on audio the detector called quiet: it hears speech.
            if !isPad, !isOpen { isOpen = true }
        }
        if isOpen, padRun >= configuration.padTokens {
            isOpen = false
            padRun = 0
            stats.closes += 1
        }
    }

    /// The utterance stops. Returns the audio still to step before the engine's
    /// flush: what `hold` kept, so the model has heard everything. `drop` discards
    /// what it kept: the gate was closed, so that audio is the end of a pause.
    public mutating func stop() -> [Float]? {
        guard !held.isEmpty else { return nil }
        defer { held.removeAll() }
        switch configuration.mode {
        case .hold:
            stats.heldSamples += held.count
            return held
        case .drop:
            stats.droppedSamples += held.count
            return nil
        }
    }

    private mutating func releaseHeld(beyond arrived: Int) -> [Float] {
        defer { held.removeAll(keepingCapacity: true) }
        if held.count > arrived { stats.heldSamples += held.count }
        return held
    }
}

extension PauseGate.Configuration {
    /// Voxtral through mlx-audio-swift's stream session. Token k stands on audio frame
    /// k and needs the frames up to k + delay. The session reads it once frame
    /// k + delay + 2 is in: it holds one frame back as its partial-token guard, and
    /// reads each prediction at the start of the next step. So after a step, the
    /// newest token's frame starts delay + 3 frames behind the audio.
    public static func voxtral(mode: PauseGate.Mode, delayMs: Int) -> PauseGate.Configuration {
        PauseGate.Configuration(
            mode: mode,
            newestTokenLagSamples: (SilentTailStop.delayTokens(delayMs: delayMs) + 3)
                * SilentTailStop.samplesPerToken
        )
    }
}
