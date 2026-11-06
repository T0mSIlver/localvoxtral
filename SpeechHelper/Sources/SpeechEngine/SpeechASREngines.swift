import Foundation
import MLX
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
        utteranceLimit: UtteranceLimit,
        terms _: SessionTerms,
        language _: String?
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

    /// Unified only: its first full-context step compiles new kernels (LVX-111).
    func warmUpSamples(transcriptionDelayMs: Int?) -> Int {
        model.isBuffered
            ? NemotronUnifiedLayout.warmUpSamples(forTranscriptionDelayMs: transcriptionDelayMs) : 0
    }

    func makeSession(
        transcriptionDelayMs: Int?,
        utteranceLimit: UtteranceLimit,
        terms _: SessionTerms,
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
            // Neither throw can happen: `isBuffered` is checked above, and
            // NemotronUnifiedLayout's frames are valid by construction.
            session = try! model.makeStreamSession(
                language: promptKey,
                bufferedContext: NemotronASRBufferedContext(left: frames[0], chunk: frames[1], right: frames[2])
            )
        } else {
            let rung = NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: transcriptionDelayMs)
            session = model.makeStreamSession(language: promptKey, chunkMs: rung)
        }
        guard model.isBuffered else {
            return NemotronASRSession(session: session, utteranceLimit: utteranceLimit)
        }
        let model = model
        return NemotronASRSession(
            session: session, utteranceLimit: utteranceLimit,
            redecode: EmptyStreamRedecode(),
            offline: { samples in
                model.generate(
                    audio: MLXArray(samples),
                    generationParameters: STTGenerateParameters(language: promptKey)
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }
}

final class NemotronASRSession: SpeechASRStreamingSession, @unchecked Sendable {
    private let session: NemotronASRStreamSession
    /// The engine has no token budget to cap, so the limit is enforced on the audio
    /// this session accepts — see `UtteranceAudioCap`.
    private var cap: UtteranceAudioCap
    /// Unified only: a second, offline decode for an utterance whose stream emitted
    /// no token (see `EmptyStreamRedecode`).
    private var redecode: EmptyStreamRedecode?
    private let offline: (([Float]) -> String)?
    private var redecodedText = ""

    init(
        session: NemotronASRStreamSession,
        utteranceLimit: UtteranceLimit,
        redecode: EmptyStreamRedecode? = nil,
        offline: (([Float]) -> String)? = nil
    ) {
        self.session = session
        self.cap = UtteranceAudioCap(limit: utteranceLimit)
        self.redecode = redecode
        self.offline = offline
    }

    func step(_ samples: [Float]) -> SpeechStreamDelta {
        let accepted = cap.accept(samples.count)
        guard accepted > 0 else { return SpeechStreamDelta(text: "", tokenIds: []) }
        let fed = accepted == samples.count ? samples : Array(samples.prefix(accepted))
        let streamed = session.step(fed)
        redecode?.record(fed, decodedTokens: session.tokens.count)
        return delta(streamed)
    }

    func finish() -> SpeechStreamDelta {
        let streamed = session.finish()
        guard let offline,
              let audio = redecode?.audioToRedecode(decodedTokens: session.tokens.count)
        else { return delta(streamed) }
        let started = ContinuousClock.now
        redecodedText = offline(audio)
        let elapsed = ContinuousClock.now - started
        FileHandle.standardError.write(Data((
            "speechd: Unified streamed 0 tokens on \(audio.count / 16) ms of audible audio; "
                + "offline decode gave \(redecodedText.isEmpty ? "nothing" : "text") in \(elapsed)\n"
        ).utf8))
        return SpeechStreamDelta(text: redecodedText, tokenIds: [])
    }

    var text: String { session.text + redecodedText }

    var decodedTokenCount: Int { session.tokens.count }

    var utteranceStop: UtteranceStop? { cap.stop }

    private func delta(_ delta: NemotronASRStreamSession.Delta) -> SpeechStreamDelta {
        SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }
}
