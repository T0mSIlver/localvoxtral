import Foundation

/// Applies replacement-dictionary rules to Live Auto-Paste text BEFORE it is
/// typed into the target app.
///
/// The post-typing `LiveReplacementCorrector` path erases already-typed text
/// with backspaces and retypes it, verified by a caret guard. Some targets
/// can never satisfy that guard: terminals expose a screen-grid cursor over
/// the whole scrollback (field bug 2026-07-06 — the guard armed, the first
/// correction timed out, and the corrector stood down for the session), and
/// targets without a readable caret used to receive blind, unverified
/// backspaces. This stream replaces both cases: transcript text is held back
/// until it can no longer participate in a future rule match, replacements
/// are applied to the held text, and only corrected text is ever released
/// for typing — no backspaces, ever.
///
/// Hold-back policy: the trailing partial word (no whitespace after it yet) is
/// always held, plus the shortest suffix before it that is still a live prefix
/// of some rule — text a future match could still grow into. Text that is a
/// prefix of no rule is released immediately, so an unrelated four-word entry
/// in the dictionary no longer delays every dictated word by three. The bound
/// is capped by the corrector's own `lookbackStart(before:)` window, and uses
/// the same word segmentation, so a released prefix can never be reached by a
/// correction the embedded corrector produces later.
///
/// Rule chaining caveat: the viable-prefix judgment is made against the text
/// as it stands, but applying a rule can rewrite held text INTO rule-key words
/// (`x y -> bar` feeding `foo bar z -> FOO`), retroactively making released
/// text part of a longer match. When the rule set has that potential
/// (`LiveReplacementCorrector.hasChainingPotential`), the stream keeps the
/// global `maxRuleWordCount - 1` word floor instead — correct by construction
/// for rule sets whose replacements all keep at least one word, because no
/// correction can then reach back further than that many complete words.
///
/// Deletion rule caveat: a rule that deletes its match outright
/// (`LiveReplacementCorrector.hasDeletionRule`) breaks BOTH bounds — it
/// bridges another key's words across the deleted gap (defeating the
/// viable-prefix scan) and collapses held words out of the floor's post-
/// deletion word count (defeating the floor). With any deletion rule in the
/// set, nothing is released until `flushRemainder()`: with no releases before
/// corrections, no correction can ever precede the release boundary.
///
/// Newline/tab policy (terminal targets): a typed newline can act as Enter
/// and submit a prompt mid-dictation, and a typed Tab can trigger shell
/// completion UI — both mutate terminal state. When `sanitizesNewlines` is
/// on, every whitespace run containing a newline or tab — including all
/// adjacent whitespace on BOTH sides of it — collapses to exactly one
/// space, even when the run spans release boundaries or ends in the flushed
/// remainder. To decide a run's fate, EVERY trailing whitespace character —
/// not just ASCII space, but also the NBSP/narrow-NBSP French typography
/// puts before `?!:;` — is buffered until the next non-whitespace character
/// (or the remainder flush); runs without a newline or tab are then
/// re-emitted verbatim, so no dictated text is ever dropped or rewritten.
/// Buffering the full whitespace set is load-bearing: it is what makes
/// `flushRemainder()` the only path that can emit a trailing whitespace
/// character to a terminal, which the TUI-autocomplete trailing-space policy
/// relies on (`TUIAutocompleteTrailingSpace`). Collapse runs at the very
/// start of the session produce no leading space.
struct LiveHoldBackReplacementStream {
    /// How much text `safeReleaseLimit()` may release mid-session, chosen
    /// once per rule set (see the type doc's caveats, most conservative
    /// first): deletion rules hold everything until flush; chaining potential
    /// holds the global word floor; otherwise the viable-prefix scan applies.
    private enum HoldBackBound {
        case untilFlush
        case wordFloor
        case viablePrefix
    }

    private var corrector: LiveReplacementCorrector
    private let sanitizesNewlines: Bool
    private let bound: HoldBackBound
    /// Character offset into `corrector.correctedText` already released for
    /// typing. Everything before this offset is immutable by construction.
    private var releasedCharacterCount = 0

    #if DEBUG
        /// Test seam: forces the viable-prefix bound even when a stricter
        /// bound was selected, so tests can exercise the release-boundary
        /// drop guard that backstops any detection gap.
        var debugForceViablePrefixBound = false
        /// Number of corrections dropped by the release-boundary guard. The
        /// os_log error is invisible to tests; equivalence tests assert this
        /// stays zero.
        private(set) var debugDroppedCorrectionCount = 0
    #endif

    // Newline/tab sanitization state, persisted across releases so whitespace
    // runs spanning chunk boundaries still collapse to a single space.
    // Starts "as if a space was emitted" so leading collapse runs are
    // dropped. `pendingPlainWhitespace` buffers whitespace (space, NBSP, …)
    // whose run fate (verbatim vs collapsed) is not yet known;
    // `pendingRunNeedsCollapse` marks the current whitespace run as
    // containing a newline or tab.
    private var lastEmittedCharacterWasSpace = true
    private var pendingPlainWhitespace = ""
    private var pendingRunNeedsCollapse = false

    init(dictionary: ReplacementDictionary, sanitizesNewlines: Bool) {
        let corrector = LiveReplacementCorrector(dictionary: dictionary)
        self.corrector = corrector
        self.sanitizesNewlines = sanitizesNewlines

        let ruleCount = corrector.ruleCount
        if corrector.hasDeletionRule {
            bound = .untilFlush
            Log.corrector.notice(
                "holdback bound=until-flush reason=deletion-rule rules=\(ruleCount, privacy: .public)"
            )
        } else if corrector.hasChainingPotential {
            bound = .wordFloor
            let heldWords = corrector.maxRuleWordCount - 1
            Log.corrector.notice(
                "holdback bound=word-floor reason=rule-chaining-potential rules=\(ruleCount, privacy: .public) held_words=\(heldWords, privacy: .public)"
            )
        } else {
            bound = .viablePrefix
        }
    }

    var ruleCount: Int {
        corrector.ruleCount
    }

    /// Ingests the next stabilized transcript chunk and returns the text that
    /// is now safe to type, with dictionary replacements already applied (and
    /// newlines sanitized when the policy is on).
    mutating func ingest(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        corrector.recordInsertedText(text)
        applyCompletedBoundaryCorrections()
        return release(upTo: safeReleaseLimit())
    }

    /// Session stop: applies a final unbounded-word match (mirroring
    /// `completedBoundaryCorrectedText(_:dictionary:includeFinalUnboundedWord:)`)
    /// and releases everything still held.
    mutating func flushRemainder() -> String {
        applyCompletedBoundaryCorrections()
        if let correction = corrector.finalUnboundedCorrection() {
            applyIfInsideHoldBack(correction)
        }
        var output = release(upTo: corrector.correctedText.count)
        if sanitizesNewlines {
            // End of session decides the fate of a still-buffered trailing
            // whitespace run.
            emitPendingWhitespaceRun(into: &output)
        }
        return output
    }

    // MARK: - Private

    private mutating func applyCompletedBoundaryCorrections() {
        while let correction = corrector.nextCompletedBoundaryCorrection() {
            applyIfInsideHoldBack(correction)
        }
    }

    /// The never-un-type invariant, enforced on every correction in ALL
    /// builds: a correction must never begin inside text already released for
    /// typing, because that text is in the user's app and cannot be recalled.
    /// A violating correction is dropped with an error log — missing one
    /// replacement is recoverable, rewriting the user's typed text is not —
    /// and released text is never touched. This used to be a bare `assert`,
    /// compiled out of release builds, which guarded production not at all.
    ///
    /// Comparing final output against a batch correction is a weaker oracle — a
    /// correction that rewrites released text can still reproduce it verbatim
    /// and slip through. This catches the violation where it happens.
    private mutating func applyIfInsideHoldBack(_ correction: LiveReplacementCorrection) {
        guard correction.startOffset >= releasedCharacterCount else {
            let startOffset = correction.startOffset
            let releasedCount = releasedCharacterCount
            Log.corrector.error(
                "holdback invariant violated: correction start=\(startOffset, privacy: .public) released_chars=\(releasedCount, privacy: .public) — correction dropped"
            )
            #if DEBUG
                debugDroppedCorrectionCount += 1
            #endif
            return
        }
        corrector.apply(correction)
    }

    /// The largest character offset into the corrected text that no future
    /// correction can modify.
    ///
    /// Two independent lower bounds on where a future correction can start:
    ///
    /// 1. A correction reaches back at most `maxRuleWordCount` whitespace-
    ///    separated words from a future word boundary, so it can never start
    ///    before the `maxRuleWordCount - 1` complete words preceding the
    ///    trailing partial word (`windowStart`).
    /// 2. A correction starts at a rule match, so it can only start at an
    ///    offset from which the remaining text is still a live prefix of some
    ///    rule (`isViableRulePrefix`).
    ///
    /// Both bound the same quantity, so the safe limit is the larger. Bound 2
    /// is usually far tighter: most text is a prefix of no rule at all, and
    /// then nothing is held beyond the trailing partial word — a single long
    /// entry in the dictionary no longer taxes every unrelated word.
    ///
    /// Bound 2 judges viability against the CURRENT text, so it is only sound
    /// when no correction can rewrite held text into rule-key words: with
    /// chaining potential in the rule set, only bound 1 applies, and bound 1
    /// itself only holds while every correction keeps at least one word —
    /// deletion rules hold everything until flush instead (see the type doc).
    ///
    /// The trailing partial word is always held: punctuation does not complete
    /// a word here, so "def" in "abc def." could still grow into "def.x".
    private func safeReleaseLimit() -> Int {
        guard corrector.hasRules else {
            return corrector.correctedText.count
        }

        var effectiveBound = bound
        #if DEBUG
            if debugForceViablePrefixBound {
                effectiveBound = .viablePrefix
            }
        #endif

        if effectiveBound == .untilFlush {
            // Release nothing mid-session; `flushRemainder()` releases the
            // whole corrected text after the final corrections.
            return releasedCharacterCount
        }

        let characters = Array(corrector.correctedText)
        let partialWordStart = trailingPartialWordStart(in: characters)
        var offset = wordWindowStart(in: characters, before: partialWordStart)

        if effectiveBound == .viablePrefix {
            // Advance to the earliest offset a rule match could still begin
            // at. Candidate offsets are match starts, not word starts — see
            // `isCandidateMatchStart`.
            while offset < partialWordStart {
                if LiveReplacementCorrector.isCandidateMatchStart(characters, offset),
                   corrector.isViableRulePrefix(String(characters[offset...]))
                {
                    break
                }
                offset += 1
            }
        }

        return max(offset, releasedCharacterCount)
    }

    /// The offset of the trailing run of non-whitespace characters.
    private func trailingPartialWordStart(in characters: [Character]) -> Int {
        var offset = characters.count
        while offset > 0, !LiveReplacementCorrector.isWhitespace(characters[offset - 1]) {
            offset -= 1
        }
        return offset
    }

    /// The offset `maxRuleWordCount - 1` complete words before `end` — the
    /// furthest back any correction can reach.
    private func wordWindowStart(in characters: [Character], before end: Int) -> Int {
        var offset = end
        var wordsToHold = corrector.maxRuleWordCount - 1
        while wordsToHold > 0, offset > 0 {
            while offset > 0, LiveReplacementCorrector.isWhitespace(characters[offset - 1]) {
                offset -= 1
            }
            while offset > 0, !LiveReplacementCorrector.isWhitespace(characters[offset - 1]) {
                offset -= 1
            }
            wordsToHold -= 1
        }
        return offset
    }

    private mutating func release(upTo limit: Int) -> String {
        guard limit > releasedCharacterCount else { return "" }
        let text = corrector.correctedText
        let start = text.index(text.startIndex, offsetBy: releasedCharacterCount)
        let end = text.index(text.startIndex, offsetBy: limit)
        releasedCharacterCount = limit
        let released = String(text[start ..< end])
        return sanitizesNewlines ? sanitizingNewlines(in: released) : released
    }

    /// Collapses every whitespace run containing a newline or tab — with all
    /// adjacent whitespace on both sides — into a single space, without ever
    /// producing double spaces. Every trailing whitespace character (the full
    /// `Character.isWhitespace` set — ASCII space, NBSP, narrow NBSP, …) is
    /// buffered (not emitted) until the next non-whitespace character or the
    /// remainder flush decides whether the run stays verbatim or collapses;
    /// state persists across release boundaries. Verbatim re-emission
    /// preserves the exact characters, so French NBSP spacing survives.
    private mutating func sanitizingNewlines(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        for character in text {
            if character.isNewline || character == "\t" {
                pendingRunNeedsCollapse = true
                pendingPlainWhitespace = ""
                continue
            }
            if character.isWhitespace {
                if !pendingRunNeedsCollapse {
                    pendingPlainWhitespace.append(character)
                }
                continue
            }
            emitPendingWhitespaceRun(into: &output)
            output.append(character)
            lastEmittedCharacterWasSpace = false
        }

        return output
    }

    private mutating func emitPendingWhitespaceRun(into output: inout String) {
        if pendingRunNeedsCollapse {
            if !lastEmittedCharacterWasSpace {
                output.append(" ")
                lastEmittedCharacterWasSpace = true
            }
        } else if !pendingPlainWhitespace.isEmpty {
            output.append(pendingPlainWhitespace)
            lastEmittedCharacterWasSpace = true
        }
        pendingPlainWhitespace = ""
        pendingRunNeedsCollapse = false
    }
}
