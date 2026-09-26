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

    /// Terms this dictation's own context offers (#647), read at the stop
    /// from what was already in hand: nothing here waits on a subprocess or
    /// re-reads the screen.
    package struct ContextTerms: Equatable, Sendable {
        /// Code-like terms from the joined coding-agent session's text.
        package var session: [String]
        /// The project's own term list: what its coding agent proposed (#609).
        package var repository: [String]
        /// Code-like terms from the screen as it was when speech started,
        /// newest line first.
        package var screen: [String]

        package init(session: [String] = [], repository: [String] = [], screen: [String] = []) {
            self.session = session
            self.repository = repository
            self.screen = screen
        }

        package static let none = ContextTerms()
    }

    /// The terms the second pass is biased with, in the order the 100-term
    /// cap cuts against, before `MistralBatchTranscription.contextBias` makes
    /// them acceptable to the API. The list leaves the Mac. The user's own
    /// words go to any endpoint, as they do in the polish prompt: the Names
    /// and terms list, then the spellings of the replacement dictionary.
    /// Everything else is drawn from screen, session and repository context,
    /// so it goes only when `contextTrusted` (the trusted-endpoint opt-in, as
    /// for every other context sent off a non-loopback endpoint): terms
    /// learned from polishing, then the project's, the session's and the
    /// screen's. The screen goes last because it holds the most terms nobody
    /// is about to say, and a listed term that is not said can be written
    /// anyway.
    package static func candidates(
        userTerms: [String],
        dictionarySpellings: [String],
        learnedTerms: [String],
        context: ContextTerms = .none,
        contextTrusted: Bool
    ) -> [String] {
        let own = userTerms + dictionarySpellings
        guard contextTrusted else { return own }
        return own + learnedTerms + context.repository + context.session + context.screen
    }

    /// `candidates`, as sent.
    package static func vocabulary(
        userTerms: [String],
        dictionarySpellings: [String],
        learnedTerms: [String],
        context: ContextTerms = .none,
        contextTrusted: Bool
    ) -> [String] {
        MistralBatchTranscription.contextBias(from: candidates(
            userTerms: userTerms,
            dictionarySpellings: dictionarySpellings,
            learnedTerms: learnedTerms,
            context: context,
            contextTrusted: contextTrusted
        ))
    }

    /// The code-like terms of a screen or session text that someone could
    /// say: a path gives its last component, and URLs, flags and anything
    /// over `maxContextTermLength` characters (hashes, keys, long paths) are
    /// left out. `newestFirst` reads the text bottom up, as a terminal
    /// screen's newest line is its last.
    package static func speakableTerms(in text: String, newestFirst: Bool = false) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline)
        var seen = Set<String>()
        var terms: [String] = []
        for line in newestFirst ? lines.reversed() : Array(lines) {
            for entity in ClipboardVocabulary.entities(inExcerpt: String(line)) {
                guard let term = speakableTerm(entity),
                    seen.insert(term.lowercased()).inserted
                else { continue }
                terms.append(term)
            }
        }
        return terms
    }

    package static let maxContextTermLength = 40

    private static func speakableTerm(_ entity: String) -> String? {
        guard !entity.contains("://"), !entity.hasPrefix("-") else { return nil }
        var term = entity
        if term.contains("/") {
            guard let last = term.split(separator: "/").last else { return nil }
            term = String(last)
        }
        term = term.trimmingCharacters(in: CharacterSet(charactersIn: "~.:;,()'\""))
        guard term.count >= 3, term.count <= maxContextTermLength,
            term.contains(where: \.isLetter)
        else { return nil }
        return term
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
