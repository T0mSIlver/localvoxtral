import Foundation

/// Turns a retained context buffer into the two things the polish request needs
/// from it: the grounding entries to pre-apply, and the excerpt to render.
///
/// It exists so those two steps stay welded together, in order: extraction runs
/// ONCE over the whole buffer, and its results feed line selection. Splitting
/// them is what let an earlier version re-run the entity recognizer per line.
///
/// The work is pure and deterministic, and potentially large:
/// `retentionCharacterCap` allows a 2M-character paste. The stop-commit path
/// runs on `@MainActor`, so this must not run there — hence `prepared` is
/// `nonisolated async`, which under this package's settings executes on the
/// generic executor while remaining a structured child of the caller.
struct PolishContextPreparation: Sendable, Equatable {
    /// Grounding matched over the COMPLETE retained text — never the excerpt.
    let grounding: RepoVocabularyMatcher.GroundingOutcome
    /// What actually renders into the prompt, within the granted budget.
    let excerpt: String

    static let empty = PolishContextPreparation(grounding: .empty, excerpt: "")

    /// Prepares `clipboardText` off the main actor.
    ///
    /// `nonisolated` + `async` is the whole mechanism: under this package's
    /// settings a nonisolated async function runs on the generic executor, so
    /// awaiting it from the `@MainActor` commit path already hops off the main
    /// actor. The earlier version wrapped the body in `Task.detached` to buy
    /// that hop — which it already had — at the cost of severing cancellation:
    /// a detached task has no parent, so cancelling the commit left the sweep
    /// running to completion over a 2M-character buffer. Structured is both
    /// simpler and more correct.
    ///
    /// No artificial deadline, deliberately. The repo-vocabulary path races a
    /// 2 s deadline because it shells out to `git`, which can block forever on
    /// a wedged filesystem. This work cannot block: it is CPU-bound over an
    /// in-memory string with a hard size cap, and it now checks
    /// `Task.isCancelled` between batches, so cancelling the commit abandons it
    /// promptly. Boundedness comes from the cap; timeliness from cancellation.
    nonisolated static func prepared(
        clipboardText: String,
        transcript: String,
        renderBudget: Int
    ) async -> PolishContextPreparation {
        prepare(
            clipboardText: clipboardText,
            transcript: transcript,
            renderBudget: renderBudget
        )
    }

    /// The pure computation, synchronous and actor-agnostic. Exposed for tests;
    /// production callers should prefer `prepared`, which runs it off the main
    /// actor.
    nonisolated static func prepare(
        clipboardText: String,
        transcript: String,
        renderBudget: Int
    ) -> PolishContextPreparation {
        guard !clipboardText.isEmpty else { return .empty }
        // Matching sees everything retained; rendering is what pays the budget.
        // This is the ONE whole-buffer entity extraction — its results then feed
        // the selector, which must never re-derive them per line.
        let grounding = ClipboardVocabulary.candidateOutcome(
            transcript: transcript,
            clipboardText: clipboardText
        )
        let excerpt = PolishContextExcerptSelector.select(
            text: clipboardText,
            transcript: transcript,
            characterCap: renderBudget,
            groundingTerms: grounding.entries.map(\.replaceWith)
        )
        return PolishContextPreparation(grounding: grounding, excerpt: excerpt)
    }
}
