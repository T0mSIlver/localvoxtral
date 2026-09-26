import Foundation

/// Where an Overlay Buffer dictation's settled text is cut into pieces that
/// are polished while the user is still speaking (#709), and how the stop
/// joins them with the tail.
///
/// A piece is a run of whole sentences from the backend's finals that
/// reaches `minimumPieceWords`. Each piece is polished on its own; a replay
/// of long dictations on GLM 5.3 found that giving a piece the text polished
/// before it, or polishing the last settled sentence again at stop, changed
/// more words than polishing it alone (#709 study).
package enum EarlyPolishPlan {
    package static let minimumPieceWords = 30

    /// The next piece of `settledText` after `consumedPrefix`: whole sentences
    /// until they reach `minimumWords`, or nil when too few have settled.
    /// `consumedPrefix` is the exact prefix of `settledText` earlier pieces
    /// took; nil also when `settledText` no longer starts with it.
    package static func nextPiece(
        settledText: String,
        consumedPrefix: String,
        minimumWords: Int = minimumPieceWords
    ) -> (piece: String, consumedPrefix: String)? {
        guard settledText.hasPrefix(consumedPrefix) else { return nil }
        let rest = settledText[consumedPrefix.endIndex...]
        var words = 0
        var inWord = false
        var index = rest.startIndex
        while index < rest.endIndex {
            let character = rest[index]
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
            let next = rest.index(after: index)
            if words >= minimumWords, isSentenceEnd(in: rest, at: index) {
                let piece = rest[rest.startIndex..<next]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (piece, String(settledText[..<next]))
            }
            index = next
        }
        return nil
    }

    /// What the stop still has to polish: `workingText` after the pieces'
    /// prefix, trimmed. Nil when the stop's text no longer starts with that
    /// prefix (the replacement dictionary, the payload macro or the spoken
    /// send cut changed it), and the whole text must be polished instead.
    package static func tail(workingText: String, consumedPrefix: String) -> String? {
        guard !consumedPrefix.isEmpty, workingText.hasPrefix(consumedPrefix) else { return nil }
        let rest = workingText[consumedPrefix.endIndex...]
        // A piece ends on a sentence end, so what follows starts a new word.
        // Text glued onto that end would mean the prefix split a word.
        if let first = rest.first, !first.isWhitespace { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The polished pieces and the polished tail, one space apart.
    package static func joined(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A `.`, `!`, `?` or `…` at the end of the text or before whitespace. A
    /// period after a bare number or a single letter is a list marker or part
    /// of a spoken literal ("1.", "HTTPS 2."), and one inside a dotted token
    /// ("e.g.", "v1.2.") is not an end either: the study's first cut split a
    /// numbered list and a URL there.
    static func isSentenceEnd(in text: Substring, at index: Substring.Index) -> Bool {
        let character = text[index]
        guard ".!?…".contains(character) else { return false }
        let next = text.index(after: index)
        if next < text.endIndex, !text[next].isWhitespace { return false }
        guard character == "." else { return true }
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        let token = text[start..<index]
        if token.isEmpty || token.contains(".") { return false }
        if token.allSatisfy(\.isNumber) { return false }
        if token.count == 1, token.first?.isLetter == true { return false }
        return true
    }
}
