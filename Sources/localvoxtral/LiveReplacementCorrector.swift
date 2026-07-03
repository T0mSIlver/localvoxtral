import Foundation

struct LiveReplacementCorrection: Sendable {
    let erasedText: String
    let replacementText: String
    let backspaceCount: Int

    fileprivate let startOffset: Int
    fileprivate let endOffset: Int
}

struct LiveReplacementCorrector {
    private let rules: [LiveReplacementRule]
    private let maxKeyWordCount: Int
    private var typedText = ""
    private var scanOffset = 0
    private(set) var isStandingDown = false

    init(dictionary: ReplacementDictionary) {
        let rules = dictionary.liveReplacementRules()
        self.rules = rules
        maxKeyWordCount = max(1, rules.map(\.wordCount).max() ?? 1)
    }

    var hasRules: Bool {
        !rules.isEmpty
    }

    var ruleCount: Int {
        rules.count
    }

    static func completedBoundaryCorrectedText(
        _ text: String,
        dictionary: ReplacementDictionary,
        includeFinalUnboundedWord: Bool = false
    ) -> String {
        var corrector = LiveReplacementCorrector(dictionary: dictionary)
        guard corrector.hasRules else { return text }

        corrector.recordInsertedText(text)
        while let correction = corrector.nextCompletedBoundaryCorrection() {
            corrector.apply(correction)
        }
        if includeFinalUnboundedWord,
           let correction = corrector.finalUnboundedCorrection()
        {
            corrector.apply(correction)
        }
        return corrector.typedText
    }

    mutating func recordInsertedText(_ text: String) {
        guard !text.isEmpty, !isStandingDown else { return }
        typedText.append(text)
    }

    mutating func standDown() {
        isStandingDown = true
    }

    mutating func nextCompletedBoundaryCorrection() -> LiveReplacementCorrection? {
        guard !isStandingDown, !rules.isEmpty, !typedText.isEmpty else { return nil }

        while scanOffset < typedText.count {
            let characters = Array(typedText)
            var offset = scanOffset

            while offset < characters.count {
                guard Self.isCompletionBoundary(characters[offset]) else {
                    offset += 1
                    continue
                }

                guard offset > 0, !Self.isCompletionBoundary(characters[offset - 1]) else {
                    offset += 1
                    continue
                }

                let wordEndOffset = offset
                var boundaryEndOffset = offset
                while boundaryEndOffset < characters.count,
                      Self.isCompletionBoundary(characters[boundaryEndOffset])
                {
                    boundaryEndOffset += 1
                }
                scanOffset = boundaryEndOffset

                if let correction = correctionEndingAt(
                    wordEndOffset: wordEndOffset,
                    boundaryEndOffset: boundaryEndOffset
                ) {
                    return correction
                }

                offset = boundaryEndOffset
            }

            scanOffset = characters.count
        }

        return nil
    }

    mutating func finalUnboundedCorrection() -> LiveReplacementCorrection? {
        guard !isStandingDown, !rules.isEmpty, !typedText.isEmpty else { return nil }
        let characters = Array(typedText)
        guard let last = characters.last, !Self.isCompletionBoundary(last) else { return nil }
        scanOffset = characters.count
        return correctionEndingAt(
            wordEndOffset: characters.count,
            boundaryEndOffset: characters.count
        )
    }

    mutating func apply(_ correction: LiveReplacementCorrection) {
        guard !isStandingDown else { return }
        let startIndex = typedText.index(typedText.startIndex, offsetBy: correction.startOffset)
        let endIndex = typedText.index(typedText.startIndex, offsetBy: correction.endOffset)
        typedText.replaceSubrange(startIndex ..< endIndex, with: correction.replacementText)
        scanOffset = correction.startOffset + correction.replacementText.count
    }

    private func correctionEndingAt(
        wordEndOffset: Int,
        boundaryEndOffset: Int
    ) -> LiveReplacementCorrection? {
        let lookbackStartOffset = lookbackStart(before: wordEndOffset)
        guard lookbackStartOffset < wordEndOffset else { return nil }

        let searchStart = typedText.index(typedText.startIndex, offsetBy: lookbackStartOffset)
        let searchEnd = typedText.index(typedText.startIndex, offsetBy: wordEndOffset)
        let searchText = String(typedText[searchStart ..< searchEnd])
        let searchRange = NSRange(searchText.startIndex..., in: searchText)

        for rule in rules {
            let matches = rule.regex.matches(in: searchText, options: [], range: searchRange)
            for match in matches {
                guard let matchRange = Range(match.range, in: searchText),
                      matchRange.upperBound == searchText.endIndex
                else {
                    continue
                }

                let matchStartDelta = searchText.distance(
                    from: searchText.startIndex,
                    to: matchRange.lowerBound
                )
                let matchStartOffset = lookbackStartOffset + matchStartDelta
                let boundaryStart = typedText.index(typedText.startIndex, offsetBy: wordEndOffset)
                let boundaryEnd = typedText.index(typedText.startIndex, offsetBy: boundaryEndOffset)
                let erasedStart = typedText.index(
                    typedText.startIndex,
                    offsetBy: matchStartOffset
                )
                let erasedText = String(typedText[erasedStart ..< boundaryEnd])
                let boundaryText = String(typedText[boundaryStart ..< boundaryEnd])

                return LiveReplacementCorrection(
                    erasedText: erasedText,
                    replacementText: rule.replaceWith + boundaryText,
                    // Keyboard backspace is counted by grapheme so composed
                    // characters are erased as users expect in native fields.
                    // Some web/Electron controls delete by UTF-16 unit instead;
                    // the next caret-guard check catches that mismatch and
                    // disables further live corrections for the session.
                    backspaceCount: erasedText.count,
                    startOffset: matchStartOffset,
                    endOffset: boundaryEndOffset
                )
            }
        }

        return nil
    }

    private func lookbackStart(before endOffset: Int) -> Int {
        let characters = Array(typedText)
        var offset = endOffset
        var wordsSeen = 0
        var isInsideWord = false

        while offset > 0 {
            let previousOffset = offset - 1
            let character = characters[previousOffset]

            if Self.isWhitespace(character) {
                if isInsideWord {
                    wordsSeen += 1
                    if wordsSeen == maxKeyWordCount {
                        return offset
                    }
                    isInsideWord = false
                }
            } else {
                isInsideWord = true
            }

            offset = previousOffset
        }

        return 0
    }

    private static func isCompletionBoundary(_ character: Character) -> Bool {
        isWhitespace(character) || isPunctuation(character)
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
