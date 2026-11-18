/// An engine session behind a `PauseGate`: the server feeds it audio as it arrives,
/// and the gate decides when the model steps (LVX-126).
public final class PauseGatedSession: SpeechASRStreamingSession, @unchecked Sendable {
    private let session: SpeechASRStreamingSession
    private let padTokenId: Int
    private var gate: PauseGate
    private var detector = SpeechLevelDetector()

    public init(session: SpeechASRStreamingSession, gate: PauseGate, padTokenId: Int) {
        self.session = session
        self.gate = gate
        self.padTokenId = padTokenId
    }

    public func step(_ samples: [Float]) -> SpeechStreamDelta {
        let lastSpeechEnd = detector.process(samples)
        guard let audio = gate.admit(samples, lastSpeechEnd: lastSpeechEnd) else {
            return SpeechStreamDelta(text: "", tokenIds: [])
        }
        let delta = session.step(audio)
        gate.observe(tokensArePads: delta.tokenIds.map { $0 == padTokenId })
        return delta
    }

    public func finish() -> SpeechStreamDelta {
        guard let rest = gate.stop() else { return session.finish() }
        let stepped = session.step(rest)
        let flushed = session.finish()
        return SpeechStreamDelta(
            text: stepped.text + flushed.text, tokenIds: stepped.tokenIds + flushed.tokenIds
        )
    }

    public var text: String { session.text }
    public var decodedTokenCount: Int { session.decodedTokenCount }
    public var utteranceStop: UtteranceStop? { session.utteranceStop }
    public var pauseGateStats: PauseGate.Stats? { gate.stats }
}
