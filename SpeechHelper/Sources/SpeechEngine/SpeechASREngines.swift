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
    private let maxSamples: Int
    private var acceptedSamples = 0
    private var reachedLimit = false

    /// Nemotron is RNN-T: it emits a variable number of tokens per frame and never
    /// ends a stream on its own, so a token cap is not a duration and there is no
    /// end-of-stream to report. The limit is therefore enforced here, on the audio
    /// the session accepts, which is what `UtteranceLimit` means in the first place.
    init(session: NemotronASRStreamSession, utteranceLimit: UtteranceLimit) {
        self.session = session
        self.maxSamples = utteranceLimit.seconds * NemotronASRSession.sampleRate
    }

    private static let sampleRate = 16_000

    func step(_ samples: [Float]) -> SpeechStreamDelta {
        guard !reachedLimit else { return SpeechStreamDelta(text: "", tokenIds: []) }
        let room = maxSamples - acceptedSamples
        if samples.count >= room {
            reachedLimit = true
            let accepted = Array(samples.prefix(room))
            acceptedSamples += accepted.count
            guard !accepted.isEmpty else { return SpeechStreamDelta(text: "", tokenIds: []) }
            return delta(session.step(accepted))
        }
        acceptedSamples += samples.count
        return delta(session.step(samples))
    }

    func finish() -> SpeechStreamDelta {
        delta(session.finish())
    }

    var text: String { session.text }

    var decodedTokenCount: Int { session.tokens.count }

    var utteranceStop: UtteranceStop? { reachedLimit ? .lengthLimit : nil }

    private func delta(_ delta: NemotronASRStreamSession.Delta) -> SpeechStreamDelta {
        SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }
}
