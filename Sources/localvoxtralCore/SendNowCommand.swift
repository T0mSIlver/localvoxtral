import Foundation

// Spoken send trigger (#318). Ported from @eastokes's fork
// (eastokes/localvoxtral, `SendNowCommandParser.swift`): dictated text that
// ends in a trigger phrase such as "send it" inserts the text before the
// phrase and then presses Return.

/// What a finalized segment asks for.
package enum SendNowCommandAction: Equatable, Sendable {
    /// No trigger: insert the segment as dictated.
    case insertText(String)
    /// The segment was the trigger alone: press Return on what is already typed.
    case pressReturn
    /// Insert the text before the trigger, then press Return.
    case insertTextAndPressReturn(String)
    /// Empty segment: do nothing.
    case none

    package var pressesReturn: Bool {
        switch self {
        case .pressReturn, .insertTextAndPressReturn: true
        case .insertText, .none: false
        }
    }
}

package enum SendNowCommandParser {
    /// The phrases the parser accepts when the caller passes none. The fork
    /// ships English only; no French equivalent is added until one is chosen
    /// and measured against real dictation.
    package static let defaultTriggerPhrases = ["send it", "send now"]

    /// Punctuation the ASR may attach to the trigger or to the text before
    /// it ("Run the tests, send it."). Stripped from word edges only.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?…")

    /// Parses one FINALIZED segment. The trigger counts only as the last
    /// whole words of the segment: "resend now" and "send it later" insert
    /// text. Never call this on partial text — a partial ending in "send"
    /// followed by "it" in the next delta would split the decision.
    package static func parse(
        _ segment: String,
        triggerPhrases: [String] = defaultTriggerPhrases
    ) -> SendNowCommandAction {
        let trimmed = segment.trimmed
        guard !trimmed.isEmpty else { return .none }

        // A punctuation-only token at the end ("send it .") is not a word:
        // dropped here so it neither hides the trigger nor moves the cut,
        // which still uses the ranges in the original string.
        var words = wordRanges(in: trimmed)
        while let last = words.last, normalizedWord(trimmed[last]).isEmpty {
            words.removeLast()
        }
        let normalizedWords = words.map { normalizedWord(trimmed[$0]) }

        for phrase in triggerPhrases {
            let phraseWords = phrase
                .split(whereSeparator: \.isWhitespace)
                .map { normalizedWord($0) }
                .filter { !$0.isEmpty }
            guard !phraseWords.isEmpty,
                  phraseWords.count <= normalizedWords.count,
                  Array(normalizedWords.suffix(phraseWords.count)) == phraseWords
            else { continue }

            let firstTriggerWord = words[words.count - phraseWords.count]
            let textBefore = droppingTrailingPunctuationAndWhitespace(
                trimmed[..<firstTriggerWord.lowerBound]
            )
            return textBefore.isEmpty
                ? .pressReturn
                : .insertTextAndPressReturn(textBefore)
        }
        return .insertText(trimmed)
    }

    /// The form the resubmit latch compares: case, edge punctuation and
    /// whitespace runs do not make two finals different.
    package static func normalizedSegment(_ segment: String) -> String {
        let trimmed = segment.trimmed
        return wordRanges(in: trimmed)
            .map { normalizedWord(trimmed[$0]) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Run the tests, send it" keeps "Run the tests": the comma belonged to
    /// the pause before the trigger. Leading text is left as dictated.
    private static func droppingTrailingPunctuationAndWhitespace(
        _ text: Substring
    ) -> String {
        let drop = edgePunctuation.union(.whitespacesAndNewlines)
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            let isDroppable = text[previous].unicodeScalars.allSatisfy {
                drop.contains($0)
            }
            guard isDroppable else { break }
            end = previous
        }
        return String(text[..<end])
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let wordStart = start {
                    ranges.append(wordStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            ranges.append(wordStart..<text.endIndex)
        }
        return ranges
    }

    private static func normalizedWord<S: StringProtocol>(_ word: S) -> String {
        String(word)
            .trimmingCharacters(in: edgePunctuation)
            .caseFoldedForMatching
    }
}

/// Keeps a duplicate final from submitting twice. Some backends deliver the
/// same finalized segment again; pressing Return a second time would send an
/// empty or repeated prompt to the agent, which cannot be undone.
///
/// The rule: a submission equal to the previous one (case, punctuation and
/// spacing aside) is refused until a final that submits nothing comes in
/// between, or the session ends. None of the backends name their segments
/// (speechd, vLLM and Mistral finals carry text only), and partials cannot
/// tell a new utterance from a straggler of the old one: a late "send"
/// before a repeated "send it" looks exactly like the user saying it again
/// (Codex review of #494). The cost: saying the same submitting phrase twice
/// in a row, "send it" then "send it", presses Return once; the second needs
/// other words between them or a new dictation. The caller claims the
/// submission BEFORE the irreversible insertion or Return, so a failed Return
/// leaves the latch set and a duplicate final cannot retry it.
package struct SendNowResubmitLatch: Equatable, Sendable {
    package private(set) var lastSubmittedSegment: String?

    package init() {}

    /// A final that inserts text without submitting. Clears the latch: the
    /// next submission follows new text, so it cannot be a duplicate.
    package mutating func noteNonSubmittingFinal() {
        lastSubmittedSegment = nil
    }

    /// Returns true when `segment` may submit, and sets the latch in the same
    /// step. Returns false for a duplicate final; the caller then does
    /// nothing at all, not even the insertion.
    package mutating func claimSubmission(of segment: String) -> Bool {
        let normalized = SendNowCommandParser.normalizedSegment(segment)
        guard normalized != lastSubmittedSegment else { return false }
        lastSubmittedSegment = normalized
        return true
    }

    package mutating func reset() {
        self = SendNowResubmitLatch()
    }
}
