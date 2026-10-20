import Foundation
import os

/// Mistral's realtime stream can stall mid-dictation and resume without the
/// speech sent during the stall (symptom D, #1648). When an Overlay Buffer
/// dictation's stream resumes after a stall that carried speech, the stalled
/// stretch of the recording goes to the batch model, and its words are
/// spliced into the overlay where the stream skipped them. The stop's second
/// pass, when on, still replaces the whole text.
extension DictationSessionController {
    func startStallBackfill(after stall: MistralStreamHealth.StallEnd) {
        guard sessionHasStallBackfill, acceptsRealtimeEvents else { return }
        let described = String(
            format: "%.1fs stall, %.1fs of audio (loudest %@)",
            stall.silentFor, stall.audioSeconds,
            MistralStreamHealth.describeLevel(stall.loudestDBFS))
        guard StallBackfill.isWorthBackfilling(stall) else {
            Log.backends.info("stall backfill skipped: \(described, privacy: .public) is below speech level")
            return
        }
        // The key and host the session dialed, as for the second pass.
        guard let configuration = sessionRealtimeConfiguration,
            !configuration.apiKey.isEmpty,
            let endpoint = MistralBatchTranscription.endpoint(
                forRealtimeEndpoint: configuration.endpoint)
        else {
            Log.backends.notice("stall backfill skipped: the session's endpoint has no batch route")
            return
        }
        guard let pcm = audio.sessionRecording.tail(byteCount: StallBackfill.windowBytes(for: stall))
        else {
            Log.backends.notice("stall backfill skipped: no audio kept")
            return
        }
        let mark = transcript.stallMark()
        let wav = DictationAudioRecording.wav(fromPCM16: pcm)
        let audioSeconds = Double(pcm.count) / Double(AudioChunkBuffer.bytesPerSecond)
        // The user's own terms only: the context sources pass their gates at
        // stop, with the screen and the join as they are then.
        let candidates = StopSecondPass.candidates(
            userTerms: settings.polishSpeakerTerms,
            dictionarySpellings: sessionReplacementDictionary?.entries.map(\.replaceWith) ?? [],
            learnedTerms: [],
            contextTrusted: false
        )
        let contextBias = MistralBatchTranscription.contextBias(from: candidates)
        let uploadRates = secondPassUploadRates
        let deadline = StopSecondPass.deadline(
            audioSeconds: audioSeconds,
            uploadBytes: wav.count,
            measuredUploadBytesPerSecond: uploadRates.rate(for: endpoint)
        )
        let transcriber = dependencies.batchTranscriber
        let sleep = dependencies.clock.sleep
        let usageRecorder = secondPassUsageRecorder
        Log.backends.notice(
            "stall backfill: sending \(String(format: "%.1f", audioSeconds), privacy: .public)s of audio after a \(described, privacy: .public), deadline \(String(describing: deadline), privacy: .public)"
        )
        let task = Task { @MainActor [weak self] in
            let outcome = await StopSecondPass.run(deadline: deadline, sleep: sleep) {
                // Billed like the second pass, which it is a slice of.
                usageRecorder?.record(UsageEntry(
                    date: Date(),
                    feature: .secondPass,
                    backend: .mistral,
                    model: MistralBatchTranscription.model,
                    audioSeconds: audioSeconds,
                    costEUR: MistralPricing.dictationCost(
                        model: MistralBatchTranscription.model, audioSeconds: audioSeconds)
                ))
                let text = try await transcriber.transcribe(
                    wav: wav,
                    language: nil,
                    contextBias: contextBias,
                    apiKey: configuration.apiKey,
                    endpoint: endpoint,
                    onUpload: { uploadRates.record($0, for: endpoint) }
                ).text
                return MistralBatchTranscription.restoringPhrases(in: text, candidates: candidates)
            }
            guard let self, !Task.isCancelled else { return }
            self.applyStallBackfill(outcome, at: mark)
        }
        stallBackfillTasks.append(task)
    }

    private func applyStallBackfill(_ outcome: StopSecondPass.Outcome, at mark: TranscriptAccumulator.StallMark) {
        switch outcome {
        case .replaced(let text):
            guard let words = transcript.spliceBackfill(text, at: mark) else {
                Log.backends.notice(
                    "stall backfill kept the hole: its text has no new words that line up with the text around the stall, or the segment was already committed"
                )
                return
            }
            let count = words.split(whereSeparator: \.isWhitespace).count
            Log.backends.notice("stall backfill restored \(count, privacy: .public) words")
            refreshOverlayBufferSession()
        case .empty:
            Log.backends.notice("stall backfill answered with no text; hole kept")
        case .deadlinePassed:
            Log.backends.notice("stall backfill missed its deadline; hole kept")
        case .failed(let reason):
            Log.backends.error("stall backfill failed; hole kept: \(reason, privacy: .public)")
        case .cancelled:
            break
        }
    }
}
