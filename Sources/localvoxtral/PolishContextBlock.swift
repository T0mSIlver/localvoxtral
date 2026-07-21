import Foundation

/// A rendered reference-context block, independent of where its text came from
/// (clipboard, terminal screen, or a future source).
///
/// This is the integration seam. No source invents its own attachment path,
/// prompt-cache rules, or excerpt budget: each produces a block, and
/// `attaching(to:)` owns the one rule that must hold for every source. A second
/// source that re-derived those rules is exactly how prompt caching gets broken
/// twice.
///
/// Both live sources now go through this type:
///
/// - **Budget.** No source carries a cap of its own. `PolishContextBudget`
///   allocates across every populated source for one request and the grant is
///   passed INTO the block builders. Do not add a cap inside the AX reader (its
///   24k is a read ceiling for matching, a different question) or inside the
///   reconciler.
/// - **Ordering.** Clipboard and screen go through a SINGLE `attaching(to:)`
///   call, ordered by `PolishContextSource.allocationRank`. Two sequential
///   prepends also keep the transcript last, but the resulting source order is
///   the reverse of the call order — the array is the form that cannot get this
///   wrong.
/// - **Fencing.** Every excerpt is fence-escaped before it is rendered, because
///   every source's text is arbitrary user content that may contain a bare
///   `---` line. See `PolishContextClipboardReader.fenceSafe`.
/// - **Provenance.** `summary` is count-only by construction. A merged
///   summary is `blocks.map(\.summary).joined(separator: " ")`.
struct PolishContextBlock: Equatable {
    /// The fixed, source-specific instruction prefix.
    let instruction: String
    /// The sanitized, capped excerpt.
    let excerpt: String
    /// Count-only provenance for logs and the session record. Never content.
    let summary: String

    /// The instruction followed by the excerpt fenced between `---` lines —
    /// the shape both existing context sources already use.
    var rendered: String {
        "\(instruction)\n---\n\(excerpt)\n---"
    }

    /// Prepends `blocks`, in the given order, to the LAST user message — keeping
    /// the transcript last within it.
    ///
    /// The two invariants this must hold (context rides INSIDE the last message
    /// so polishd's single-slot prefix checkpoint survives; prepended so the
    /// transcript stays last) are NOT re-implemented here. They are
    /// `PolishContextComposer.prepending`'s, and this delegates to it — because
    /// two copies of a rule whose violation is invisible at the call site and
    /// only shows up as a field timeout is precisely the shape of the bug this
    /// type exists to prevent. This function's own job is narrower: rendering
    /// blocks in a caller-fixed order and joining them.
    ///
    /// Returns `userPrompts` unchanged when there are no blocks or no messages
    /// to attach to.
    static func attaching(
        _ blocks: [PolishContextBlock],
        to userPrompts: [String]
    ) -> [String] {
        guard !blocks.isEmpty else { return userPrompts }
        return PolishContextComposer.prepending(
            contextMessage: blocks.map(\.rendered).joined(separator: "\n\n"),
            to: userPrompts
        )
    }
}

extension PolishClipboardContext {
    /// The clipboard's context block for an already-selected `excerpt`.
    ///
    /// Renders byte-identically to `PolishContextClipboardReader.contextMessage(excerpt:characterCap:)`,
    /// which it replaces at the call site: same instruction, same fence, same
    /// `fenceSafe` cap handling. That equality is asserted by a test and is the
    /// point — moving the clipboard onto the shared attachment path must not
    /// change a single byte of the prompt, or every eval baseline moves with it.
    ///
    /// - Parameter renderBudget: the budget's grant for `.clipboard`, the same
    ///   cap the selector was given.
    func contextBlock(excerpt: String, renderBudget: Int) -> PolishContextBlock? {
        guard !excerpt.isEmpty, renderBudget > 0 else { return nil }
        let fenced = PolishContextClipboardReader.fenceSafe(excerpt, characterCap: renderBudget)
        return PolishContextBlock(
            instruction: PolishContextClipboardReader.contextMessageInstruction,
            excerpt: fenced,
            summary: provenanceSummary(renderedCharacterCount: excerpt.count)
        )
    }
}

extension TerminalScreenContextDecision {
    /// The context block this decision authorizes, or nil when it withholds the
    /// excerpt (`vocabularyOnly`, `drop`).
    ///
    /// `vocabularyOnly` returning nil here is the abstention: the start text
    /// still reaches the vocabulary matcher through `vocabularyGroundingText`,
    /// but nothing about it enters the prompt.
    ///
    /// Both arguments are required, with no defaults: an unbounded excerpt is
    /// exactly the mistake this signature exists to prevent, and the number
    /// belongs to whoever owns the prompt budget. The summary reports both
    /// counts when trimming occurred (`screen:2000/8412ch`), mirroring
    /// `PolishClipboardContext.provenanceSummary`.
    ///
    /// - Parameters:
    ///   - excerpt: the already-selected excerpt from `PolishContextPreparation`
    ///     — relevance-selected against the transcript within the budget's
    ///     grant, not a head cut. A terminal screen's most relevant lines are
    ///     not reliably its first ones (a prefix keeps the oldest rows and drops
    ///     the command the user is talking about), which is why selection is the
    ///     shared preparation's job for this source exactly as it is for the
    ///     clipboard.
    ///   - renderBudget: the budget's grant for `.terminal`, the same cap the
    ///     selector was given. Zero means the budget gave this source nothing,
    ///     which is an abstention rather than a reason to render an empty fence.
    func contextBlock(excerpt: String, renderBudget: Int) -> PolishContextBlock? {
        // `.render` is the ONLY case that may produce a block. `vocabularyOnly`
        // has already contributed its terms through the matcher and abstains
        // from the prompt; `drop` contributes nothing at all. This guard is what
        // makes an unjoined Ghostty pane's scrollback unrenderable.
        guard case let .render(full, _, _) = self, !excerpt.isEmpty, renderBudget > 0 else { return nil }
        // Fence-escaping is the only step that can GROW the text, so it takes
        // the cap too — otherwise a screen full of `---` dividers would spend
        // more prompt space than the budget granted it.
        let fenced = PolishContextClipboardReader.fenceSafe(excerpt, characterCap: renderBudget)
        guard !fenced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let summary = fenced.count < full.count
            ? "screen:\(fenced.count)/\(full.count)ch"
            : "screen:\(full.count)ch"
        return PolishContextBlock(
            instruction: TerminalScreenContext.contextMessageInstruction,
            excerpt: fenced,
            summary: summary
        )
    }

    /// The text a vocabulary matcher may ground against — the start-of-speech
    /// screen for both `render` and `vocabularyOnly`, nil for `drop`.
    var vocabularyGroundingText: String? {
        switch self {
        case let .render(_, startText, _): return startText
        case let .vocabularyOnly(startText, _): return startText
        case .drop: return nil
        }
    }

    /// Count-only provenance line for logs and the session record. Contains
    /// character counts and a reason slug — never screen content.
    var provenanceSummary: String {
        switch self {
        case let .render(excerpt, _, elidedChurnLines):
            return elidedChurnLines == 0
                ? "screen:\(excerpt.count)ch"
                : "screen:\(excerpt.count)ch:elided-churn:\(elidedChurnLines)"
        case let .vocabularyOnly(startText, cause):
            return "screen-vocab-only:\(startText.count)ch:\(cause.summarySlug)"
        case let .drop(reason): return "screen-dropped:\(reason.rawValue)"
        }
    }
}
