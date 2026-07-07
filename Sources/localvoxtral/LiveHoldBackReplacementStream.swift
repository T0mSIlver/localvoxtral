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
/// Hold-back policy: the trailing partial word (no whitespace after it yet)
/// plus the last `maxRuleWordCount - 1` complete words stay held, because
/// they could still be part of a rule match that only completes with future
/// text. Single-word dictionaries therefore release with zero hold beyond
/// the trailing partial word. The policy mirrors the corrector's own
/// `lookbackStart(before:)` word segmentation, so a released prefix can
/// never be reached by a correction the embedded corrector produces later.
///
/// Newline policy (terminal targets): a typed newline can act as Enter and
/// submit a prompt mid-dictation. When `sanitizesNewlines` is on, released
/// text collapses each newline run — together with adjacent spaces/tabs —
/// into a single space, including runs that span release boundaries.
struct LiveHoldBackReplacementStream {
    private var corrector: LiveReplacementCorrector
    private let sanitizesNewlines: Bool
    /// Character offset into `corrector.correctedText` already released for
    /// typing. Everything before this offset is immutable by construction.
    private var releasedCharacterCount = 0

    // Newline sanitization state, persisted across releases so whitespace
    // runs spanning chunk boundaries still collapse to a single space.
    // Starts "as if a space was emitted" so leading newlines are dropped.
    private var lastEmittedCharacterWasSpace = true
    private var isAbsorbingCollapsedWhitespace = false

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
            corrector.apply(correction)
        }
        return release(upTo: corrector.correctedText.count)
    }

    // MARK: - Private

    private mutating func applyCompletedBoundaryCorrections() {
        while let correction = corrector.nextCompletedBoundaryCorrection() {
            corrector.apply(correction)
        }
    }

    /// The largest character offset into the corrected text that no future
    /// correction can modify. Corrections end at a future word boundary and
    /// reach back at most `maxRuleWordCount` whitespace-separated words from
    /// it, so the trailing partial word plus the `maxRuleWordCount - 1`
    /// complete words before it must stay held.
    private func safeReleaseLimit() -> Int {
        guard corrector.hasRules else {
            return corrector.correctedText.count
        }

        let characters = Array(corrector.correctedText)
        var offset = characters.count

        // Hold the trailing partial word (punctuation does not complete a
        // word here: "def" in "abc def." could still grow into "def.x").
        while offset > 0, !LiveReplacementCorrector.isWhitespace(characters[offset - 1]) {
            offset -= 1
        }

        // Hold the last (maxRuleWordCount - 1) complete words: they may be
        // the leading words of a multi-word match that completes later.
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

        return max(offset, releasedCharacterCount)
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

    /// Collapses each newline run (with adjacent spaces/tabs) into a single
    /// space without ever producing double spaces, tracking state across
    /// release boundaries.
    private mutating func sanitizingNewlines(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        for character in text {
            if character.isNewline {
                isAbsorbingCollapsedWhitespace = true
                if !lastEmittedCharacterWasSpace {
                    output.append(" ")
                    lastEmittedCharacterWasSpace = true
                }
                continue
            }
            if isAbsorbingCollapsedWhitespace, character == " " || character == "\t" {
                continue
            }
            isAbsorbingCollapsedWhitespace = false
            output.append(character)
            lastEmittedCharacterWasSpace = character == " " || character == "\t"
        }

        return output
    }
}
