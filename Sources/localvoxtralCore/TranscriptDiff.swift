import Foundation

/// Which words polishing took out of a transcript and which it put in, as
/// ranges into the two original strings, so each can be drawn as it was
/// written (line breaks included) with only the changed words marked.
enum TranscriptDiff {
    struct Result: Equatable, Sendable {
        /// Words of `before` that `after` does not keep.
        var removed: [Range<String.Index>] = []
        /// Words of `after` that `before` did not have.
        var added: [Range<String.Index>] = []

        var isEmpty: Bool { removed.isEmpty && added.isEmpty }
    }

    /// Past this many differing words on either side the comparison stops
    /// looking for what they share and marks them all: the table is
    /// quadratic, and a rewrite that large has no word-level story to tell.
    static let maxComparedWords = 1_200

    /// One stretch where the texts part ways: the words `before` had there
    /// and the words `after` has instead. Either side may be empty.
    struct Hunk: Equatable, Sendable {
        var removed: [Range<String.Index>]
        var added: [Range<String.Index>]
    }

    static func words(from before: String, to after: String) -> Result {
        let hunks = hunks(from: before, to: after)
        return Result(removed: hunks.flatMap(\.removed), added: hunks.flatMap(\.added))
    }

    /// In reading order. Two hunks always have a kept word between them.
    static func hunks(from before: String, to after: String) -> [Hunk] {
        let beforeWords = wordRanges(in: before)
        let afterWords = wordRanges(in: after)

        // Polishing leaves most of a dictation alone, so the shared head and
        // tail are usually nearly everything.
        var head = 0
        while head < beforeWords.count, head < afterWords.count,
            before[beforeWords[head]] == after[afterWords[head]]
        {
            head += 1
        }
        var tail = 0
        while tail < beforeWords.count - head, tail < afterWords.count - head,
            before[beforeWords[beforeWords.count - 1 - tail]]
                == after[afterWords[afterWords.count - 1 - tail]]
        {
            tail += 1
        }

        let beforeMiddle = Array(beforeWords[head..<(beforeWords.count - tail)])
        let afterMiddle = Array(afterWords[head..<(afterWords.count - tail)])
        guard !beforeMiddle.isEmpty || !afterMiddle.isEmpty else { return [] }
        guard beforeMiddle.count <= maxComparedWords, afterMiddle.count <= maxComparedWords else {
            return [Hunk(removed: beforeMiddle, added: afterMiddle)]
        }

        let kept = longestCommonSubsequence(
            beforeMiddle.map { before[$0] }, afterMiddle.map { after[$0] })
        var hunks: [Hunk] = []
        var beforeIndex = 0
        var afterIndex = 0
        // The pair past the end closes the last stretch.
        for (keptBefore, keptAfter) in kept + [(beforeMiddle.count, afterMiddle.count)] {
            if keptBefore > beforeIndex || keptAfter > afterIndex {
                hunks.append(
                    Hunk(
                        removed: Array(beforeMiddle[beforeIndex..<keptBefore]),
                        added: Array(afterMiddle[afterIndex..<keptAfter])))
            }
            beforeIndex = keptBefore + 1
            afterIndex = keptAfter + 1
        }
        return hunks
    }

    /// Runs of non-whitespace, in order.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let start = wordStart {
                    ranges.append(start..<index)
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = index
            }
        }
        if let start = wordStart { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Index pairs `(left, right)` of one longest common subsequence.
    private static func longestCommonSubsequence(
        _ left: [Substring], _ right: [Substring]
    ) -> [(Int, Int)] {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        let width = right.count + 1
        var lengths = [Int32](repeating: 0, count: (left.count + 1) * width)
        for row in stride(from: left.count - 1, through: 0, by: -1) {
            for column in stride(from: right.count - 1, through: 0, by: -1) {
                lengths[row * width + column] =
                    left[row] == right[column]
                    ? lengths[(row + 1) * width + column + 1] + 1
                    : max(lengths[(row + 1) * width + column], lengths[row * width + column + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0
        var column = 0
        while row < left.count, column < right.count {
            if left[row] == right[column] {
                pairs.append((row, column))
                row += 1
                column += 1
            } else if lengths[(row + 1) * width + column] >= lengths[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }
}
