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
/// Newline/tab policy (terminal targets): a typed newline can act as Enter
/// and submit a prompt mid-dictation, and a typed Tab can trigger shell
/// completion UI — both mutate terminal state. When `sanitizesNewlines` is
/// on, every whitespace run containing a newline or tab — including all
/// adjacent spaces/tabs on BOTH sides of it — collapses to exactly one
/// space, even when the run spans release boundaries or ends in the flushed
/// remainder. To decide a run's fate, trailing spaces/tabs are buffered
/// until the next non-whitespace character (or the remainder flush); plain
/// space runs are then re-emitted verbatim, so no dictated text is ever
/// dropped. Collapse runs at the very start of the session produce no
/// leading space.
struct LiveHoldBackReplacementStream {
    private var corrector: LiveReplacementCorrector
    private let sanitizesNewlines: Bool
    /// Character offset into `corrector.correctedText` already released for
    /// typing. Everything before this offset is immutable by construction.
    private var releasedCharacterCount = 0

    // Newline/tab sanitization state, persisted across releases so whitespace
    // runs spanning chunk boundaries still collapse to a single space.
    // Starts "as if a space was emitted" so leading collapse runs are
    // dropped. `pendingPlainSpaces` buffers spaces whose run fate (verbatim
    // vs collapsed) is not yet known; `pendingRunNeedsCollapse` marks the
    // current whitespace run as containing a newline or tab.
    private var lastEmittedCharacterWasSpace = true
    private var pendingPlainSpaces = ""
    private var pendingRunNeedsCollapse = false

    init(dictionary: ReplacementDictionary, sanitizesNewlines: Bool) {
        corrector = LiveReplacementCorrector(dictionary: dictionary)
        self.sanitizesNewlines = sanitizesNewlines
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
            assertCannotReachReleasedText(correction)
            corrector.apply(correction)
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
            assertCannotReachReleasedText(correction)
            corrector.apply(correction)
        }
    }

    /// The never-un-type invariant, checked on every correction in debug
    /// builds: a correction must never begin inside text already released for
    /// typing, because that text is in the user's app and cannot be recalled.
    ///
    /// Comparing final output against a batch correction is a weaker oracle — a
    /// correction that rewrites released text can still reproduce it verbatim
    /// and slip through. This catches the violation where it happens.
    private func assertCannotReachReleasedText(_ correction: LiveReplacementCorrection) {
        assert(
            correction.startOffset >= releasedCharacterCount,
            """
            hold-back violated: correction starts at \(correction.startOffset) \
            but \(releasedCharacterCount) characters were already typed
            """
        )
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
    /// The trailing partial word is always held: punctuation does not complete
    /// a word here, so "def" in "abc def." could still grow into "def.x".
    private func safeReleaseLimit() -> Int {
        guard corrector.hasRules else {
            return corrector.correctedText.count
        }

        let characters = Array(corrector.correctedText)
        let partialWordStart = trailingPartialWordStart(in: characters)
        var offset = wordWindowStart(in: characters, before: partialWordStart)

        // Advance to the earliest offset a rule match could still begin at.
        // Candidate offsets are match starts, not word starts — see
        // `isCandidateMatchStart`.
        while offset < partialWordStart {
            if LiveReplacementCorrector.isCandidateMatchStart(characters, offset),
               corrector.isViableRulePrefix(String(characters[offset...]))
            {
                break
            }
            offset += 1
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
    /// adjacent spaces/tabs on both sides — into a single space, without ever
    /// producing double spaces. Trailing spaces are buffered (not emitted)
    /// until the next non-whitespace character or the remainder flush decides
    /// whether the run stays verbatim or collapses; state persists across
    /// release boundaries.
    private mutating func sanitizingNewlines(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        for character in text {
            if character.isNewline || character == "\t" {
                pendingRunNeedsCollapse = true
                pendingPlainSpaces = ""
                continue
            }
            if character == " " {
                if !pendingRunNeedsCollapse {
                    pendingPlainSpaces.append(" ")
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
        } else if !pendingPlainSpaces.isEmpty {
            output.append(pendingPlainSpaces)
            lastEmittedCharacterWasSpace = true
        }
        pendingPlainSpaces = ""
        pendingRunNeedsCollapse = false
    }
}
