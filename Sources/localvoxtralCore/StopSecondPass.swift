import Foundation

/// The second transcription an Overlay Buffer dictation gets on stop (#317):
/// the session's audio sent whole to a model that takes a vocabulary. Its
/// text replaces the realtime text only when it answers before the deadline;
/// otherwise the realtime text is committed as it is.
package enum StopSecondPass {
    // MARK: - Deadline

    /// Measured from a datacenter link on 2026-09-26 (`voxtral-mini-latest`,
    /// 16 kHz mono PCM16 WAV, two runs each): 15 s of audio answered in
    /// 0.36–0.43 s, 1 min in 1.1–1.4 s, 5 min in 2.8–3.3 s, 10 min in 4.5 s.
    /// The per-minute allowance also covers the upload on a slower line: a
    /// minute is 1.92 MB, one second at about 15 Mbit/s.
    package static let baseDeadlineSeconds: Double = 2.5
    package static let deadlineSecondsPerAudioMinute: Double = 1.0

    package static func deadline(audioSeconds: Double) -> Duration {
        let seconds = baseDeadlineSeconds
            + max(audioSeconds, 0) / 60 * deadlineSecondsPerAudioMinute
        return .milliseconds(Int((seconds * 1_000).rounded(.up)))
    }

    // MARK: - Vocabulary

    /// The terms the second pass is biased with, in the order the 100-term
    /// cap cuts against. The list leaves the Mac. The user's own words go to
    /// any endpoint, as they do in the polish prompt: the Names and terms
    /// list, then the spellings of the replacement dictionary. Terms learned
    /// from polishing are drawn from screen, session and repository context,
    /// so they go only when `contextTrusted` (the trusted-endpoint opt-in,
    /// as for every other context sent off a non-loopback endpoint).
    package static func vocabulary(
        userTerms: [String],
        dictionarySpellings: [String],
        learnedTerms: [String],
        contextTrusted: Bool
    ) -> [String] {
        MistralBatchTranscription.contextBias(
            from: userTerms + dictionarySpellings + (contextTrusted ? learnedTerms : []))
    }

    // MARK: - Race

    package enum Outcome: Equatable, Sendable {
        /// The second pass answered in time with text: commit this instead.
        case replaced(String)
        /// It answered in time with nothing to say; the realtime text stays.
        case empty
        /// The deadline passed first; the request was cancelled.
        case deadlinePassed
        /// It failed first; `reason` is for the log.
        case failed(reason: String)
        /// The caller's task was cancelled: commit nothing.
        case cancelled
    }

    private enum Arrival: Sendable {
        case answer(String)
        case failure(String)
        case deadline
    }

    /// Runs `transcribe` against `deadline` on `sleep`, and cancels whichever
    /// loses.
    package static func run(
        deadline: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void,
        transcribe: @escaping @Sendable () async throws -> String
    ) async -> Outcome {
        let first: Arrival? = await withTaskGroup(of: Arrival.self) { group in
            group.addTask {
                do {
                    return .answer(try await transcribe())
                } catch {
                    return .failure(String(describing: error))
                }
            }
            group.addTask {
                await sleep(deadline)
                return .deadline
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        guard !Task.isCancelled, let first else { return .cancelled }
        switch first {
        case .answer(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .empty : .replaced(trimmed)
        case .failure(let reason):
            return .failed(reason: reason)
        case .deadline:
            return .deadlinePassed
        }
    }
}
