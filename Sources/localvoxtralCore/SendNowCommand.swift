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
/// The latch holds the normalized segment of the last submission. A final
/// equal to it is a duplicate unless it is a new segment. None of the
/// backends name their segments (speechd, vLLM and Mistral finals carry text
/// only), so the segment's identity is its own partials: a new utterance
/// streams partials from its first word, so the partials received since the
/// last final must spell the start of the new final. A late partial of the
/// utterance already submitted ("it." after "fix the build send it") is the
/// tail of that utterance, not the start of a new one, and re-arms nothing.
/// The caller claims the submission BEFORE the irreversible insertion or
/// Return, so a failed Return leaves the latch set and a duplicate final
/// cannot retry it.
package struct SendNowResubmitLatch: Equatable, Sendable {
    package private(set) var lastSubmittedSegment: String?
    /// The partial deltas since the last final, joined as they arrived.
    private var partialsSinceLastFinal = ""

    package init() {}

    /// A partial delta arrived.
    package mutating func notePartial(_ delta: String) {
        partialsSinceLastFinal.append(delta)
    }

    /// A final that inserts text without submitting. Clears the latch: the
    /// next submission follows new text, so it cannot be a duplicate.
    package mutating func noteNonSubmittingFinal() {
        lastSubmittedSegment = nil
        partialsSinceLastFinal = ""
    }

    /// Returns true when `segment` may submit, and sets the latch in the same
    /// step. Returns false for a duplicate final; the caller then does
    /// nothing at all, not even the insertion.
    package mutating func claimSubmission(of segment: String) -> Bool {
        let normalized = SendNowCommandParser.normalizedSegment(segment)
        let partials = SendNowCommandParser.normalizedSegment(partialsSinceLastFinal)
        partialsSinceLastFinal = ""
        if normalized == lastSubmittedSegment,
           !Self.partials(partials, openSegment: normalized)
        {
            return false
        }
        lastSubmittedSegment = normalized
        return true
    }

    package mutating func reset() {
        self = SendNowResubmitLatch()
    }

    /// Whether the normalized partials are the first words of the normalized
    /// segment. The last partial word may still be growing ("fo" before
    /// "focused"), so it only has to start the segment's word.
    private static func partials(_ partials: String, openSegment segment: String) -> Bool {
        let partialWords = partials.split(separator: " ")
        let segmentWords = segment.split(separator: " ")
        guard !partialWords.isEmpty, partialWords.count <= segmentWords.count else {
            return false
        }
        for (index, word) in partialWords.enumerated() {
            let isLast = index == partialWords.count - 1
            let matches = isLast
                ? segmentWords[index].hasPrefix(word)
                : segmentWords[index] == word
            guard matches else { return false }
        }
        return true
    }
}

/// The ordered keystroke steps for one action, all aimed at one process.
///
/// The PID is captured once, when the text's target is resolved, and every
/// step carries it: a focus change between the insertion and the Return
/// cannot land the prompt in one app and its Return in another. Without a
/// PID there is no Return at all — the text is still inserted, since that is
/// what Live Auto-Paste would have done without the trigger.
package enum SendNowStep: Equatable, Sendable {
    case insert(String, pid: Int32?)
    case pressReturn(pid: Int32)
}

package enum SendNowPlan {
    package static func steps(
        for action: SendNowCommandAction,
        targetPID: Int32?
    ) -> [SendNowStep] {
        switch action {
        case .none:
            return []
        case .insertText(let text):
            return [.insert(text, pid: targetPID)]
        case .pressReturn:
            guard let pid = targetPID else { return [] }
            return [.pressReturn(pid: pid)]
        case .insertTextAndPressReturn(let text):
            guard let pid = targetPID else { return [.insert(text, pid: nil)] }
            return [.insert(text, pid: pid), .pressReturn(pid: pid)]
        }
    }
}
