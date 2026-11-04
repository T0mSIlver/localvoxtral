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
    private let termBoost: VoxtralRealtimeTermBoostConfig

    init(model: VoxtralRealtimeModel, termBoost: TermBoostSettings? = nil) {
        self.model = model
        self.termBoost = termBoost.map {
            VoxtralRealtimeTermBoostConfig(
                firstTokenBoost: $0.firstTokenBoost,
                continuationBoost: $0.continuationBoost,
                margin: $0.margin
            )
        } ?? VoxtralRealtimeTermBoostConfig()
    }

    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit,
        terms: SessionTerms,
        language _: String?
    ) -> SpeechASRStreamingSession {
        // The decoder emits one token per audio frame, so the token cap is the
        // limit expressed in this model's frame rate.
        let maxDecodedTokens = utteranceLimit.maxDecodedTokens(
            frameRate: model.config.audioEncodingArgs.frameRate
        )
        let session = model.makeStreamSession(
            temperature: 0.0,
            maxTokens: maxDecodedTokens,
            transcriptionDelayMs: transcriptionDelayMs
        )
        if !terms.terms.isEmpty {
            session.setBoostTerms(terms.terms, config: termBoost)
        }
        return VoxtralASRSession(session: session, maxDecodedTokens: maxDecodedTokens)
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

    var boostedTokenCount: Int? { session.boostedTokenCount }

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
    private let termBoost: NemotronASRTermBoostConfig

    init(model: NemotronASRModel, termBoost: TermBoostSettings?) {
        self.model = model
        self.termBoost = termBoost.map {
            NemotronASRTermBoostConfig(
                firstTokenBoost: $0.firstTokenBoost,
                continuationBoost: $0.continuationBoost,
                margin: $0.margin
            )
        } ?? NemotronASRTermBoostConfig()
    }

    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit,
        terms: SessionTerms,
        language: String?
    ) -> SpeechASRStreamingSession {
        // Nil keeps the checkpoint's default prompt (`auto` for Unified).
        let promptKey = NemotronPromptLanguage.key(for: language, in: model.promptDictionary)
        let promptIndex = model.promptDictionary[promptKey ?? model.defaultLanguage]
        FileHandle.standardError.write(Data(
            "speechd: nemotron session language \(promptKey ?? model.defaultLanguage) prompt \(promptIndex.map(String.init) ?? "none")\n".utf8))
        let session: NemotronASRStreamSession
        if model.isBuffered {
            let frames = NemotronUnifiedLayout.frames(forTranscriptionDelayMs: transcriptionDelayMs)
            session = model.makeStreamSession(
                language: promptKey,
                bufferedContext: NemotronASRBufferedContext(left: frames[0], chunk: frames[1], right: frames[2])
            )
        } else {
            let rung = NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: transcriptionDelayMs)
            session = model.makeStreamSession(language: promptKey, chunkMs: rung)
        }
        if !terms.terms.isEmpty {
            session.setBoostTerms(terms.terms, config: termBoost)
        }
        return NemotronASRSession(session: session, utteranceLimit: utteranceLimit)
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

    var boostedTokenCount: Int? { session.boostedTokenCount }

    var utteranceStop: UtteranceStop? { cap.stop }

    private func delta(_ delta: NemotronASRStreamSession.Delta) -> SpeechStreamDelta {
        SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }
}
