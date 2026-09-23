import Foundation
import MLXAudioSTT
import SpeechEngineText

/// MLX-bound adapters between the upstream streaming engines and the server's
/// `SpeechASREngine` / `SpeechASRStreamingSession` contract. The contract types
/// themselves live in `SpeechEngineText`, so the tier-0 lane tests them without
/// Metal. Every type here is confined to the server's serial inference queue.

// MARK: - Voxtral (the default engine)

final class VoxtralASREngine: SpeechASREngine, @unchecked Sendable {
    private let model: VoxtralRealtimeModel

    init(model: VoxtralRealtimeModel) {
        self.model = model
    }

    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit
    ) -> SpeechASRStreamingSession {
        // The decoder emits one token per audio frame, so the token cap is the
        // limit expressed in this model's frame rate.
        let maxDecodedTokens = utteranceLimit.maxDecodedTokens(
            frameRate: model.config.audioEncodingArgs.frameRate
        )
        return VoxtralASRSession(
            session: model.makeStreamSession(
                temperature: 0.0,
                maxTokens: maxDecodedTokens,
                transcriptionDelayMs: transcriptionDelayMs
            ),
            maxDecodedTokens: maxDecodedTokens
        )
    }
}

final class VoxtralASRSession: SpeechASRStreamingSession, @unchecked Sendable {
    private let session: VoxtralRealtimeStreamSession
    private let maxDecodedTokens: Int

    init(session: VoxtralRealtimeStreamSession, maxDecodedTokens: Int) {
        self.session = session
        self.maxDecodedTokens = maxDecodedTokens
    }

    func step(_ samples: [Float]) -> SpeechStreamDelta {
        let delta = session.step(samples)
        return SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }

    func finish() -> SpeechStreamDelta {
        let delta = session.finish()
        return SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }

    var text: String { session.text }

    var decodedTokenCount: Int { session.tokens.count }

    var utteranceStop: UtteranceStop? {
        // `session.tokens` hands out a copy of the whole array — never touch it
        // while the session is still decoding.
        guard session.isFinished else { return nil }
        return UtteranceStop.classify(
            isFinished: true,
            decodedTokenCount: session.tokens.count,
            maxDecodedTokens: maxDecodedTokens
        )
    }
}

// MARK: - Nemotron (the low-memory engine)

final class NemotronASREngine: SpeechASREngine, @unchecked Sendable {
    private let model: NemotronASRModel

    init(model: NemotronASRModel) {
        self.model = model
    }

    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit
    ) -> SpeechASRStreamingSession {
        NemotronASRSession(
            session: model.makeStreamSession(
                language: nil,
                chunkMs: NemotronChunkLadder.chunkMilliseconds(
                    forTranscriptionDelayMs: transcriptionDelayMs
                )
            ),
            utteranceLimit: utteranceLimit
        )
    }
}

final class NemotronASRSession: SpeechASRStreamingSession, @unchecked Sendable {
    private let session: NemotronASRStreamSession
    /// The engine has no token budget to cap, so the limit is enforced on the audio
    /// this session accepts — see `UtteranceAudioCap`.
    private var cap: UtteranceAudioCap

    init(session: NemotronASRStreamSession, utteranceLimit: UtteranceLimit) {
        self.session = session
        self.cap = UtteranceAudioCap(limit: utteranceLimit)
    }

    func step(_ samples: [Float]) -> SpeechStreamDelta {
        let accepted = cap.accept(samples.count)
        guard accepted > 0 else { return SpeechStreamDelta(text: "", tokenIds: []) }
        return delta(session.step(
            accepted == samples.count ? samples : Array(samples.prefix(accepted))
        ))
    }

    func finish() -> SpeechStreamDelta {
        delta(session.finish())
    }

    var text: String { session.text }

    var decodedTokenCount: Int { session.tokens.count }

    var utteranceStop: UtteranceStop? { cap.stop }

    private func delta(_ delta: NemotronASRStreamSession.Delta) -> SpeechStreamDelta {
        SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }
}
