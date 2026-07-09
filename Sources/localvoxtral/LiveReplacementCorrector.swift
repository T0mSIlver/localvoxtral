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

    /// True when applying one rule's replacement can rewrite held text into
    /// words of a rule KEY, so that a later match reaches back across text the
    /// viable-prefix bound already judged dead and released. Concrete repro:
    /// rules `x y -> bar` and `foo bar z -> FOO` with chunks "foo x ", "y ",
    /// "z " — "foo " is released (nothing viable starts there), the first
    /// correction turns the held "x y " into "bar ", and "foo bar z" then
    /// matches starting inside RELEASED text. `LiveHoldBackReplacementStream`
    /// falls back to the global `maxRuleWordCount - 1` hold floor (correct by
    /// construction for rule sets without deletion rules — see
    /// `hasDeletionRule`) when this is true, and only uses the tighter
    /// viable-prefix bound when it is false.
    ///
    /// Detection is deliberately conservative, word-level, and computed once
    /// at construction: a rule's replacement value contains a word (same
    /// whitespace segmentation and full case folding as the matcher) that
    /// appears anywhere in ANOTHER rule's key word list, or in the INTERIOR
    /// (neither first nor last word) of its OWN key. Own-rule edge words
    /// cannot chain: a spanning re-match needs its first key word in already-
    /// released text — text a replacement never produces, since corrections
    /// start at or after the release boundary and the viable-prefix scan holds
    /// any replacement suffix that begins a rule — and its last key word must
    /// end at a word boundary the corrector's scan pointer has not passed,
    /// which lies beyond the applied replacement. Excluding them keeps common
    /// echo-style rules (`foo -> big foo`) on the fast bound.
    ///
    /// Known limitation: the comparison is WHOLE-TOKEN, but rule matches may
    /// start mid-token after any non-letter/number character (the regex
    /// lookbehind), so a replacement word can FUSE with adjacent released
    /// characters into another rule's key token: with `x y -> bar` and
    /// `foo-bar z -> T!`, correcting the tail of "foo-x y" produces
    /// "foo-bar", whose "foo-" half was already released — invisible to
    /// token-level comparison. Closing this would mean flagging every
    /// replacement word that appears as a SUBSTRING of any key token, taxing
    /// ordinary dictionaries with the floor for a contrived hazard; instead
    /// the stream's runtime release-boundary guard backstops it by dropping
    /// the violating correction with an error log.
    let hasChainingPotential: Bool

    /// True when some rule's replacement contains no words at all (empty or
    /// whitespace-only replaceWith) — a DELETION rule. Deletion rules chain
    /// without contributing any word `hasChainingPotential` could compare:
    /// deleting the word between two key words of another rule BRIDGES its
    /// neighbors (the key regex's `\s+` matches across the leftover
    /// whitespace), so a later match can span the release boundary. They also
    /// defeat the `maxRuleWordCount - 1` word floor: `lookbackStart(before:)`
    /// counts words in POST-deletion text, so deleting held words drags a
    /// later lookback window across text that was released while the deleted
    /// words still existed. `LiveHoldBackReplacementStream` therefore
    /// releases nothing until flush when this is true — with no releases
    /// before corrections, no correction can precede the release boundary.
    let hasDeletionRule: Bool

    init(dictionary: ReplacementDictionary) {
        let rules = dictionary.liveReplacementRules()
        self.rules = rules
        maxKeyWordCount = max(1, rules.map(\.wordCount).max() ?? 1)
        hasChainingPotential = Self.detectChainingPotential(in: rules)
        hasDeletionRule = rules.contains { rule in
            rule.replaceWith.split(whereSeparator: { Self.isWhitespace($0) }).isEmpty
        }
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

    /// See `hasChainingPotential`. Word-level and folded on both sides:
    /// replacement values are segmented with the matcher's own whitespace
    /// predicate and fully case-folded, exactly like `foldedKeyWords`.
    private static func detectChainingPotential(in rules: [LiveReplacementRule]) -> Bool {
        guard !rules.isEmpty else { return false }

        for (index, rule) in rules.enumerated() {
            let replacementWords = Set(
                rule.replaceWith
                    .split(whereSeparator: { isWhitespace($0) })
                    .map { String($0).caseFoldedForMatching }
            )
            // Word-free replacements are deletion rules: no words to compare
            // here, but they chain by bridging — `hasDeletionRule` escalates
            // them to hold-until-flush regardless of this predicate.
            guard !replacementWords.isEmpty else { continue }

            for (targetIndex, target) in rules.enumerated() {
                // Own key: only interior words can chain (see the property
                // doc); another rule's key: any position, conservatively.
                let reachableKeyWords = targetIndex == index
                    ? target.foldedKeyWords.dropFirst().dropLast()
                    : target.foldedKeyWords[...]
                if reachableKeyWords.contains(where: replacementWords.contains) {
                    return true
                }
            }
        }

        return false
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
