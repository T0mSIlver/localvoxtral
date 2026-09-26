import Foundation
import Synchronization

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
    /// from what was already in hand. Only the project waits, on a git root
    /// bounded by `repositoryRootBound` (#705); nothing runs a subprocess or
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

    // MARK: - Repository root (#705)

    /// How long the stop waits for the git root before sending the pass
    /// without the project's terms. The lookup is a few `stat`s up from one
    /// directory, or a process-table walk under a terminal, and answers in
    /// milliseconds; the bound is there for a `stat` parked on a dead mount.
    package static let repositoryRootBound: Duration = .milliseconds(250)

    /// The git root `resolve` finds, or `.unknown` when `bound` passes on
    /// `sleep` first or an earlier lookup still holds `gate`.
    ///
    /// `resolve` runs detached and is never cancelled, since a blocked
    /// syscall would not notice. Its task holds `gate` until it returns, so a
    /// wedged lookup costs one thread however many stops follow. The gate is
    /// the second pass's own: the repository pipeline the polish runs has
    /// another, and a lookup still in flight never makes it skip.
    package static func repositoryRoot(
        bound: Duration = repositoryRootBound,
        sleep: @escaping @Sendable (Duration) async -> Void,
        gate: RepoVocabularyFlightGate,
        resolve: @escaping @Sendable () async -> LearnedTermProjectResolver.RepositoryRoot
    ) async -> LearnedTermProjectResolver.RepositoryRoot {
        guard gate.acquire() else { return .unknown }
        // A continuation, not a task group: a group awaits every child, and
        // the wedged `resolve` this bound exists for would never let it end.
        // The bound's sleep is cancelled by an answer, so it leaves no timer
        // behind, and by the caller's cancellation, which ends the wait.
        let timer = BoundTimer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let answer = ResumeOnce(continuation)
                let sleeper = Task.detached(priority: .userInitiated) {
                    await sleep(bound)
                    answer.resume(.unknown)
                }
                timer.set(sleeper)
                Task.detached(priority: .userInitiated) {
                    let root = await resolve()
                    gate.release()
                    answer.resume(root)
                    sleeper.cancel()
                }
            }
        } onCancel: {
            timer.cancel()
        }
    }

    /// The bound's sleep, cancellable before it exists: a cancellation that
    /// lands first cancels it as it is set.
    private final class BoundTimer: Sendable {
        private let state = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

        func set(_ task: Task<Void, Never>) {
            let cancelled = state.withLock { state in
                state.task = task
                return state.cancelled
            }
            if cancelled { task.cancel() }
        }

        func cancel() {
            state.withLock { state in
                state.cancelled = true
                return state.task
            }?.cancel()
        }
    }

    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<LearnedTermProjectResolver.RepositoryRoot, Never>?>

        init(_ continuation: CheckedContinuation<LearnedTermProjectResolver.RepositoryRoot, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ root: LearnedTermProjectResolver.RepositoryRoot) {
            continuation.withLock { pending in
                pending?.resume(returning: root)
                pending = nil
            }
        }
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
