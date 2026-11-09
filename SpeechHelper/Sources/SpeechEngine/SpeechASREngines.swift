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
        terms _: SessionTerms
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
            maxDecodedTokens: maxDecodedTokens,
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
    /// can fire at, then one token at a time. A stop that never sees the silence
    /// decodes what `finish()` would: the pad plus one token of zeros, which stands in
    /// for `finish()`'s trailing zeros and reaches its last position. With no audio, or
    /// a session already ended, `finish()` runs as before.
    func finish() -> SpeechStreamDelta {
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
        // The pad, plus the token of zeros that reaches `finish()`'s last position.
        let padTokens = SilentTailStop.rightPadTokens(delayMs: delayMs) + 1
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
        utteranceLimit: UtteranceLimit,
        terms _: SessionTerms
    ) -> SpeechASRStreamingSession {
        let rung = NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: transcriptionDelayMs)
        let session: NemotronASRStreamSession
        if model.isBuffered {
            let frames = NemotronUnifiedLayout.frames(forLatencyMilliseconds: rung)
            // Neither throw can happen: `isBuffered` is checked above, and
            // NemotronUnifiedLayout's frames are valid by construction.
            session = try! model.makeStreamSession(
                language: nil,
                bufferedContext: NemotronASRBufferedContext(left: frames[0], chunk: frames[1], right: frames[2])
            )
        } else {
            session = model.makeStreamSession(language: nil, chunkMs: rung)
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
                    generationParameters: STTGenerateParameters()
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
