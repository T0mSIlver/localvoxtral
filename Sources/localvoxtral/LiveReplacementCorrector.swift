import Foundation

struct LiveReplacementCorrection: Sendable {
    let replacementText: String

    /// Where in the corrected text this correction begins rewriting.
    /// `LiveHoldBackReplacementStream` asserts it never precedes text it has
    /// already released for typing.
    let startOffset: Int

    fileprivate let endOffset: Int
}

struct LiveReplacementCorrector {
    private let rules: [LiveReplacementRule]
    private let maxKeyWordCount: Int
    private var typedText = ""
    private var scanOffset = 0

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

    /// The corrected text accumulated so far (inserted text with applied
    /// corrections). `LiveHoldBackReplacementStream` releases stable prefixes
    /// of this text for typing.
    var correctedText: String {
        typedText
    }

    /// The maximum whitespace-separated word count across all rules — the
    /// lookback window corrections can reach back into.
    var maxRuleWordCount: Int {
        maxKeyWordCount
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
        guard !text.isEmpty else { return }
        typedText.append(text)
    }

    mutating func nextCompletedBoundaryCorrection() -> LiveReplacementCorrection? {
        guard !rules.isEmpty, !typedText.isEmpty else { return nil }

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
        guard !rules.isEmpty, !typedText.isEmpty else { return nil }
        let characters = Array(typedText)
        guard let last = characters.last, !Self.isCompletionBoundary(last) else { return nil }
        scanOffset = characters.count
        return correctionEndingAt(
            wordEndOffset: characters.count,
            boundaryEndOffset: characters.count
        )
    }

    mutating func apply(_ correction: LiveReplacementCorrection) {
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
                let boundaryText = String(typedText[boundaryStart ..< boundaryEnd])

                return LiveReplacementCorrection(
                    replacementText: rule.replaceWith + boundaryText,
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

    /// True when `tail` can still grow into a match for some rule — that is,
    /// when more text could complete a match starting at `tail`'s first
    /// character. `LiveHoldBackReplacementStream` uses this to hold back only
    /// text a future correction could still reach, instead of a fixed
    /// `maxRuleWordCount` window.
    ///
    /// Rules are literal word lists (`makeRegex` escapes every key), so this
    /// compares words directly. BOTH sides are fully case-folded first, because
    /// the regex matches with full case folding, which can change length: the
    /// rule `foo ßx` matches the text "foo ssx". Comparing raw characters would
    /// judge the tail "foo s" dead (`"ßx"` does not start with `"s"`), release
    /// it, and let the correction rewrite text already typed into the user's
    /// app. Folding distributes over concatenation, so a folded prefix stays a
    /// prefix.
    ///
    /// Do NOT try to replace this with the regex's own `.hitEnd` matching flag.
    /// It reports whether ICU read to the end of the input, not whether more
    /// input could match: for the rule `the quick brown fox` it is set even for
    /// the tail "world ", which can never begin that rule. It is safe but holds
    /// nearly everything, which is the latency bug this bound exists to fix.
    ///
    /// Errs toward `true` (hold more): a completed match stays viable even
    /// though its correction has, in practice, already been applied. Never
    /// erring toward `false` is what keeps released text immutable.
    func isViableRulePrefix(_ tail: String) -> Bool {
        guard let firstCharacter = tail.first,
              let lastCharacter = tail.last,
              !Self.isWhitespace(firstCharacter)
        else {
            return false
        }

        let words = tail
            .split(whereSeparator: { Self.isWhitespace($0) })
            .map { String($0).caseFoldedForMatching }
        guard !words.isEmpty else { return false }

        // A trailing whitespace character completes the final word; without it
        // the final word is still in flight and only needs to be a prefix.
        let trailingWordIsComplete = Self.isWhitespace(lastCharacter)
        let completeWordCount = trailingWordIsComplete ? words.count : words.count - 1

        return rules.contains { rule in
            let key = rule.foldedKeyWords
            guard words.count <= key.count else { return false }

            for index in 0 ..< completeWordCount where words[index] != key[index] {
                return false
            }

            guard !trailingWordIsComplete else { return true }
            return key[words.count - 1].hasPrefix(words[words.count - 1])
        }
    }

    private static func isCompletionBoundary(_ character: Character) -> Bool {
        isWhitespace(character) || isPunctuation(character)
    }

    // Internal (not private): `LiveHoldBackReplacementStream` computes its
    // hold-back window with the exact same word segmentation as
    // `lookbackStart(before:)` so its released prefix can never be reached by
    // a future correction.
    static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// True when a rule match may begin at `offset`, mirroring the
    /// `(?<![\p{L}\p{N}])` lookbehind in `ReplacementDictionary.makeRegex`.
    ///
    /// Match starts are NOT the same as whitespace-separated word starts: the
    /// lookbehind only forbids a preceding letter or digit, so `voxtral`
    /// matches inside `foo-voxtral`. The hold-back scan must treat every such
    /// offset as a candidate, or it would release text a later correction
    /// reaches back into.
    static func isCandidateMatchStart(_ characters: [Character], _ offset: Int) -> Bool {
        guard offset < characters.count, !isWhitespace(characters[offset]) else { return false }
        guard offset > 0 else { return true }
        return !isLetterOrNumber(characters[offset - 1])
    }

    /// `\p{L}` or `\p{N}` applied to the LAST unicode scalar of `character`.
    ///
    /// The regex lookbehind inspects the code point immediately before the
    /// match, not the grapheme cluster. For a decomposed `e` + U+0301 the
    /// preceding code point is a combining mark (category Mn), which the
    /// lookbehind accepts — so the scan must accept it too. Testing the last
    /// scalar reproduces that exactly, while a whole-grapheme test would
    /// wrongly reject the offset and release text that can still be corrected.
    private static func isLetterOrNumber(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.last else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
