import Foundation
import Synchronization

/// The repository vocabulary a commit grounds against: the entries the
/// terminal's working directory offers for this transcript, and the git root
/// it resolved (the learned-terms project key). The production pipeline
/// walks the commit target's window title and git index off the main actor
/// under a deadline; a test fake answers from memory.
protocol RepoVocabularyGrounding: AnyObject {
    @MainActor
    func grounding(
        endpointURL: URL,
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox?
    ) async -> RepoVocabularyMatcher.GroundingOutcome?
}

/// The production pipeline, with the two points a test holds still: the
/// detached body and the deadline clock. The setting and endpoint gates sit
/// above it, in `PolishContextGatherer.repoVocabularyGroundingIfEnabled`, so
/// an injected grounding is consulted only after they pass.
@MainActor
final class RepoVocabularyPipeline: RepoVocabularyGrounding {
    /// Overall deadline on the detached vocabulary pipeline. The git wait is
    /// internally bounded, but a `fileExists` stat on a stale network mount in
    /// the cwd resolution can block indefinitely — and the polish Task awaits
    /// this, so without a deadline that session's commit would wedge at
    /// "Polishing…". Vocabulary is best-effort; the commit is not.
    static let deadline: Duration = .seconds(3)

    let settings: SettingsStore
    /// TTL cache for harvested repo vocabularies, keyed by git root. Held for
    /// the owner's lifetime so a burst of commits reuses one index.
    let cache = RepoVocabularyCache()
    /// Single-flight gate for the detached pipeline (see
    /// `RepoVocabularyFlightGate`): while a prior pipeline is still in flight,
    /// commits fast-skip vocabulary instead of stacking more blocked threads.
    let inFlight = RepoVocabularyFlightGate()
    private let commitTargetAppPID: () -> pid_t?
    private let targetBundleID: () -> String?
    /// Replaces only the DETACHED body (AX title / process cwd + git index +
    /// match) while keeping the deadline race in play, so a test can inject a
    /// never-completing pipeline and prove the commit still proceeds.
    var pipeline: (@Sendable (String) async -> RepoVocabularyMatcher.GroundingOutcome?)?
    /// The deadline clock of the race; an immediately-returning closure makes
    /// the deadline expire at once.
    var deadlineSleep: @Sendable () async -> Void = {
        try? await Task.sleep(for: RepoVocabularyPipeline.deadline)
    }

    init(
        settings: SettingsStore,
        commitTargetAppPID: @escaping () -> pid_t?,
        targetBundleID: @escaping () -> String?
    ) {
        self.settings = settings
        self.commitTargetAppPID = commitTargetAppPID
        self.targetBundleID = targetBundleID
    }

    /// Repo-vocabulary grounding: harvests file names / path components /
    /// the branch from the git repo in the focused terminal and returns the
    /// transcript-relevant ones as replacement entries.
    ///
    /// The consent gates (setting on, permitted endpoint) are NOT here: they
    /// sit above, in `PolishContextGatherer.repoVocabularyGroundingIfEnabled`,
    /// which is the only way into this method. Repo file names never ride to
    /// an endpoint the user has not consented to, so nothing may call this
    /// method around that gate.
    ///
    /// Only the AX title and captured-app identity reads happen on the main
    /// actor (with a 0.5 s AX messaging timeout); everything blocking-ish — FS
    /// stats on the title/process CWD candidates (possibly a stale network
    /// mount), the process-table/CWD reads, the git subprocess (2 s timeout),
    /// and the n-gram match over a possibly-20k-term vocabulary — runs in one
    /// detached hop RACED against `Self.deadline`, so no blocked syscall can
    /// ever wedge the commit. A single-flight gate caps the cost of
    /// abandonment at one blocked pool thread: while an abandoned pipeline is
    /// still wedged, subsequent commits fast-skip vocabulary instead of
    /// stacking more blocked threads until the pool (and the deadline itself)
    /// starves.
    ///
    /// Returns nil (silent skip) when there is no trustworthy terminal repo
    /// signal, no transcript-relevant match, deadline expiry, or an in-flight
    /// skip.
    ///
    /// - Parameter repositoryRoot: filled with the git root the pipeline
    ///   resolved, when it gets that far. The caller owns the box and reads it
    ///   after this returns; a late write from an abandoned pipeline is
    ///   therefore discarded rather than carried into the next dictation.
    func grounding(
        endpointURL: URL,
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox? = nil
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        guard inFlight.acquire() else {
            Log.polishing.info("Repo vocabulary skipped: a previous pipeline is still in flight")
            return nil
        }
        guard let pipelineTask = makePipelineTask(
            transcript: transcript, repositoryRoot: repositoryRoot
        ) else {
            inFlight.release()
            return nil
        }

        let deadlineSleep = deadlineSleep
        // Race via a resume-once continuation, NOT a task group: a group
        // awaits ALL its children before returning, and the pipeline child —
        // awaiting a possibly-forever-blocked task's value, which is not
        // cancellation-responsive — would wedge the group (and the commit)
        // in exactly the case the deadline exists for. The losing side is
        // abandoned; its late resumeOnce call is a guarded no-op.
        let raceOutcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<RepoVocabularyRaceOutcome, Never>) in
            let resumed = Mutex(false)
            let resumeOnce: @Sendable (RepoVocabularyRaceOutcome) -> Void = { outcome in
                let shouldResume = resumed.withLock { alreadyResumed in
                    if alreadyResumed { return false }
                    alreadyResumed = true
                    return true
                }
                if shouldResume { continuation.resume(returning: outcome) }
            }
            // The continuation propagates no priority to the race children
            // (unlike the previous direct `await .value`, which escalated the
            // pipeline to the awaiting task's priority). Deliberate for the
            // pipeline — vocabulary is best-effort background work — but the
            // deadline's whole job is timeliness, so it runs `.userInitiated`
            // to keep its resumption from being starved under CPU pressure.
            Task.detached(priority: .utility) { [gate = inFlight] in
                let entries = await pipelineTask.value
                // Release the single-flight gate only when the pipeline truly
                // finished — on the abandonment path this runs arbitrarily
                // late, and until then new commits fast-skip vocabulary.
                gate.release()
                resumeOnce(.pipeline(entries))
            }
            Task.detached(priority: .userInitiated) {
                await deadlineSleep()
                resumeOnce(.deadlineExpired)
            }
        }

        switch raceOutcome {
        case .pipeline(let entries):
            return entries
        case .deadlineExpired:
            // Abandonment is safe by construction: the detached pipeline only
            // ever RETURNS a value — it never mutates view-model state — so
            // when it eventually completes its result is simply discarded.
            // (Its only shared side effects are inserting into the
            // Mutex-guarded RepoVocabularyCache, which only makes a later
            // session faster, and releasing the single-flight gate.) Until it
            // completes it holds the gate, so a genuinely wedged pipeline
            // costs at most ONE blocked pool thread across any number of
            // subsequent commits.
            Log.polishing.info("Repo vocabulary skipped: pipeline exceeded deadline")
            return nil
        }
    }

    /// The detached focused-title/terminal-PID -> cwd -> index -> match
    /// pipeline as a task. A title is optional because foreground terminal
    /// programs commonly overwrite it; the captured terminal app PID enables
    /// the conservative descendant-CWD fallback. Split out so the deadline
    /// race above stays readable and the DEBUG pipeline seam replaces exactly
    /// the detached section (keeping the race in play for deadline tests).
    private func makePipelineTask(
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox? = nil
    ) -> Task<RepoVocabularyMatcher.GroundingOutcome?, Never>? {
        if let pipeline {
            return Self.detachedRepoVocabularyPipeline { await pipeline(transcript) }
        }
        guard let terminalApplicationPID = commitTargetAppPID() else {
            Log.polishing.info("Repo vocabulary: no terminal application PID available")
            return nil
        }
        let title = TerminalWorkingDirectoryResolver.windowTitle(
            forApplicationPID: terminalApplicationPID
        )
        let targetBundleID = targetBundleID()
        let processFallbackPID: pid_t?
        if let targetBundleID,
            TerminalTargetDetector.isTerminalLikeBundleID(targetBundleID)
                || settings.userTerminalAppBundleIDs.contains(targetBundleID)
        {
            processFallbackPID = terminalApplicationPID
        } else {
            // Descendant CWDs only have the intended meaning for terminal
            // emulators. Other apps (IDEs especially) may own build helpers in
            // unrelated repos; never treat those as a focused-terminal signal.
            processFallbackPID = nil
        }
        let cache = cache
        return Self.detachedRepoVocabularyPipeline {
            await RepoVocabularyService.entries(
                forWindowTitle: title,
                terminalApplicationPID: processFallbackPID,
                transcript: transcript,
                cache: cache,
                rootSink: { root in repositoryRoot?.report(root) }
            )
        }
    }

    /// The detached pipeline task, with the ONE dogfood obligation both the
    /// live pipeline and the DEBUG override seam must share: in a dogfood
    /// build, the body runs under the tap generation read at creation time
    /// (synchronously, in the caller's main-actor context — ordered against
    /// `beginSession`). Task-locals do not cross `Task.detached`, so the
    /// binding happens inside the closure; see `DogfoodCaptureTap.noteGeneration`
    /// for why an abandoned pipeline's late harvest note must be rejectable.
    /// Routing the seam through here too is what makes the binding testable —
    /// a pipeline path that skipped it would accept stale notes unchecked.
    private static func detachedRepoVocabularyPipeline(
        _ body: @escaping @Sendable () async -> RepoVocabularyMatcher.GroundingOutcome?
    ) -> Task<RepoVocabularyMatcher.GroundingOutcome?, Never> {
        #if LOCALVOXTRAL_DOGFOOD
        let dogfoodGeneration = DogfoodCaptureTap.shared.currentGeneration
        return Task.detached(priority: .utility) {
            await DogfoodCaptureTap.$noteGeneration.withValue(dogfoodGeneration) {
                await body()
            }
        }
        #else
        return Task.detached(priority: .utility) { await body() }
        #endif
    }
}

/// One-slot handoff for the git root the repo-vocabulary pipeline resolves,
/// off the main actor, on its way to the vocabulary index.
///
/// A class because `Mutex` is noncopyable and this crosses a detached task.
/// One is created per commit: an abandoned pipeline that reports its root
/// after the deadline writes into a box nobody will read again, rather than
/// attributing the next dictation's terms to the wrong project.
final class RepoVocabularyRootBox: @unchecked Sendable {
    private let outcome = Mutex(LearnedTermProjectResolver.RepositoryRoot.unknown)

    var value: LearnedTermProjectResolver.RepositoryRoot { outcome.withLock { $0 } }

    /// Nil means the pipeline resolved no repository, which is not the same as
    /// never reporting — see `LearnedTermProjectResolver.RepositoryRoot`.
    func report(_ root: String?) {
        outcome.withLock { $0 = root.map { .root($0) } ?? .noRepository }
    }
}

private enum RepoVocabularyRaceOutcome: Sendable {
    case pipeline(RepoVocabularyMatcher.GroundingOutcome?)
    case deadlineExpired
}
