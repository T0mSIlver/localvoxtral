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
        return VoxtralASRSession(
            session: session, maxDecodedTokens: maxDecodedTokens,
            delayMs: transcriptionDelayMs ?? model.config.transcriptionDelayMs,
            leftPadTokens: model.config.nLeftPadTokens,
            padTokenId: model.config.streamingPadTokenId
        )
    }
}

final class VoxtralASRSession: SpeechASRStreamingSession, @unchecked Sendable {
    private let session: VoxtralRealtimeStreamSession
    private let maxDecodedTokens: Int
    private let delayMs: Int
    private let leftPadTokens: Int
    private let padTokenId: Int
    private var samplesTaken = 0

    /// Pad tokens in a row, past the transcription delay, that end a stop's flush
    /// (LVX-110). On 260 term-recall stops the text never went on after one; two
    /// leave a token of margin.
    static let silentTailTokens = 2

    init(
        session: VoxtralRealtimeStreamSession,
        maxDecodedTokens: Int,
        delayMs: Int,
        leftPadTokens: Int,
        padTokenId: Int
    ) {
        self.session = session
        self.maxDecodedTokens = maxDecodedTokens
        self.delayMs = delayMs
        self.leftPadTokens = leftPadTokens
        self.padTokenId = padTokenId
    }

    func step(_ samples: [Float]) -> SpeechStreamDelta {
        samplesTaken += samples.count
        let delta = session.step(samples)
        return SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
    }

    /// Feeds the offline right pad's zeros through `step` and stops once the tail
    /// decodes as silence (`SilentTailStop`), instead of `session.finish()`, which
    /// decodes the whole pad. The first batch reaches the earliest position the stop
    /// can fire at, then one token at a time. A stop that never sees the silence ends
    /// with the pad, its last positions undecoded. With no audio, or a session
    /// already ended, `finish()` runs as before.
    func appSideFinish() -> SpeechStreamDelta {
        guard samplesTaken > 0, !session.isFinished else {
            let delta = session.finish()
            return SpeechStreamDelta(text: delta.text, tokenIds: delta.tokenIds)
        }
        let spt = SilentTailStop.samplesPerToken
        var stop = SilentTailStop(
            realSamples: samplesTaken, delayMs: delayMs, leftPadTokens: leftPadTokens,
            padTokens: Self.silentTailTokens, padTokenId: padTokenId
        )
        let promptLength = 1 + leftPadTokens + SilentTailStop.delayTokens(delayMs: delayMs)
        let alignment = SilentTailStop.alignmentSamples(after: samplesTaken)
        // After `z` pad tokens, `step` has read the positions below
        // `alignedRegion + z - 1`; the front end holds back up to one token more.
        let alignedRegion = leftPadTokens + (samplesTaken + alignment) / spt
        let padTokens = SilentTailStop.rightPadTokens(delayMs: delayMs)
        var fed = min(padTokens, max(1, stop.fromPosition + stop.padTokens + 2 - alignedRegion))
        var chunk = alignment + fed * spt
        var observed = session.tokens.count
        var text = ""
        var ids: [Int] = []
        flush: while true {
            let delta = session.step([Float](repeating: 0, count: chunk))
            text += delta.text
            ids += delta.tokenIds
            let tokens = session.tokens
            for index in observed..<tokens.count
            where stop.observe(token: tokens[index], position: promptLength + index) {
                break flush
            }
            observed = tokens.count
            guard !session.isFinished, fed < padTokens else { break }
            fed += 1
            chunk = spt
        }
        // As `finish()` does: the flush leaves a cold working set behind.
        Memory.clearCache()
        return SpeechStreamDelta(text: text, tokenIds: ids)
    }

    func finish() -> SpeechStreamDelta {
        let before = session.tokens.count
        let start = ContinuousClock.now
        let delta = appSideFinish()
        let elapsed = ContinuousClock.now - start
        // MEASUREMENT ONLY (LVX-110). Token classes only (P pad, T anything else), never text.
        let pattern = session.tokens.dropFirst(before).map { $0 == padTokenId ? "P" : "T" }.joined()
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        FileHandle.standardError.write(Data(
            "BENCH flush silent_tail=app\(Self.silentTailTokens) ms=\(String(format: "%.1f", ms)) tokens=\(pattern.count) eos=\(session.isFinished ? 1 : 0) pattern=\(pattern)\n".utf8))
        return delta
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
