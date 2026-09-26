import Foundation
#if canImport(os)
import os
#endif

/// Shows the user, in one line, that a fix of theirs was learned, and offers
/// to take it back.
@MainActor
package protocol CorrectionLearningPresenting: AnyObject {
    func showLearned(term: String, undo: @escaping @MainActor () -> Void)
}

/// Learns a spelling from the fix a user makes to a dictation before sending
/// it to their coding agent (#520).
///
/// The evidence is the prompt the joined session reports as submitted
/// (`UserPromptSubmit`), compared with the text the app inserted into that
/// session. Nothing reads the screen or the keyboard: the agent hands over the
/// final prompt through the hook the join already trusts, so this sees the
/// user's words only when they send them, and only in a session a dictation
/// positively joined. See invariants.md, "A fix is learned only from the
/// prompt the joined session submits".
///
/// What is held, and for how long: the inserted text, in memory, until the
/// session submits a prompt or `window` passes. The prompt is compared and
/// dropped; one that arrives before its dictation's commit waits at most
/// `earlyPromptGrace`. Only the learned spelling reaches the disk (`LearnedTermStore`);
/// the log gets verdict categories, never text.
@MainActor
package final class CorrectionLearning {
    /// A prompt sent later than this after the dictation is not a fix of it:
    /// the user moved on, and what they sent is likely other work.
    package static let window: TimeInterval = 180
    /// Sessions waiting at once. One per terminal tab is plenty.
    package static let maxPending = 8
    /// How long a prompt that arrived with nothing to compare is kept for a
    /// dictation still finishing. An Enter pressed the moment the last word
    /// appears can reach the app before the stop's commit does; a prompt
    /// older than this belongs to no dictation still in flight.
    package static let earlyPromptGrace: TimeInterval = 10

    package struct Pending {
        package var inserted: String
        package let project: LearnedTermProjectResolver.Identity
        package var insertedAt: Date
    }

    private let store: LearnedTermStore
    private let knownTerms: @MainActor () -> [String]
    private let now: @MainActor () -> Date
    package weak var presenter: (any CorrectionLearningPresenting)?
    package private(set) var pending: [String: Pending] = [:]
    package private(set) var earlyPrompts: [String: (prompt: String, at: Date)] = [:]

    package init(
        store: LearnedTermStore,
        knownTerms: @escaping @MainActor () -> [String],
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.knownTerms = knownTerms
        self.now = now
    }

    /// Called after a commit put `inserted` into the joined session's prompt.
    /// Two dictations before one send are one prompt, so a second one within
    /// the window appends rather than replaces.
    package func expect(inserted: String, sessionID: String, project: LearnedTermProjectResolver.Identity) {
        let text = inserted.trimmed
        guard !text.isEmpty, !sessionID.isEmpty else { return }
        let moment = now()
        dropExpired(at: moment)
        if var existing = pending[sessionID], existing.project == project {
            existing.inserted += " " + text
            existing.insertedAt = moment
            pending[sessionID] = existing
        } else {
            pending[sessionID] = Pending(inserted: text, project: project, insertedAt: moment)
        }
        if pending.count > Self.maxPending,
           let oldest = pending.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            pending.removeValue(forKey: oldest)
        }
        if let early = earlyPrompts.removeValue(forKey: sessionID) {
            promptSubmitted(sessionID: sessionID, prompt: early.prompt)
        }
    }

    /// The joined session submitted `prompt`. Compared once with what was
    /// inserted into it, then both are dropped whatever the verdict.
    package func promptSubmitted(sessionID: String, prompt: String) {
        let moment = now()
        dropExpired(at: moment)
        guard let entry = pending.removeValue(forKey: sessionID) else {
            earlyPrompts[sessionID] = (prompt, moment)
            return
        }

        let remembered = store.snapshot().projects
            .first { $0.key == entry.project.key }?.terms ?? []
        let speakerTerms = knownTerms()
        let verdict = CorrectionDiffClassifier.classify(
            inserted: entry.inserted,
            submitted: prompt,
            knownTerms: Set(speakerTerms),
            learnedTerms: Set(remembered.map(\.term))
        )

        switch verdict {
        case .nothing(let reason):
            Log.polishing.info(
                "Correction learning: nothing learned (\(reason.rawValue, privacy: .public))"
            )
        case .forget(let term):
            store.forget(term, projectKey: entry.project.key)
            Log.polishing.info("Correction learning: a reverted term was forgotten")
        case .learn(let term, _, let forgetting):
            if let forgetting {
                store.forget(forgetting, projectKey: entry.project.key)
            }
            // The store keeps nothing it cannot sanitize (a spelling past 60
            // characters); announcing it would promise a term that is not there.
            guard !LearnedTerms.sanitized(term).isEmpty else {
                Log.polishing.info("Correction learning: fix too long to remember")
                return
            }
            let folded = term.caseFoldedForMatching
            // A spelling the user typed into Names and terms is already theirs
            // everywhere; remembering it per project adds nothing.
            guard !speakerTerms.contains(where: { $0.caseFoldedForMatching == folded }) else {
                Log.polishing.info("Correction learning: fix was already a listed term")
                return
            }
            let alreadyLearned = remembered.contains {
                $0.isConfirmedByCorrection && $0.term.caseFoldedForMatching == folded
            }
            store.recordCorrection(term, project: entry.project)
            Log.polishing.info(
                "Correction learning: learned a term (\(alreadyLearned ? "again" : "new", privacy: .public))"
            )
            // Tell the user once per spelling, not every time they fix it.
            guard !alreadyLearned else { return }
            let store = store
            let projectKey = entry.project.key
            presenter?.showLearned(term: term) {
                store.forget(term, projectKey: projectKey)
                Log.polishing.info("Correction learning: undone by the user")
            }
        }
    }

    private func dropExpired(at moment: Date) {
        pending = pending.filter { moment.timeIntervalSince($0.value.insertedAt) <= Self.window }
        earlyPrompts = earlyPrompts.filter {
            moment.timeIntervalSince($0.value.at) <= Self.earlyPromptGrace
        }
    }
}
