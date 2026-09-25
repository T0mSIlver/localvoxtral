import Foundation

package enum TextMergingAlgorithms {
    private static let replayCharacterThreshold = 32
    private static let replayWordThreshold = 8

    // Pre-compiled regex patterns for normalizeTranscriptionFormatting.
    // These are static string literals so try! is safe — a crash here means a
    // coding error in the pattern, which we want to catch immediately.
    private static let apostropheSpacingRegex = try! NSRegularExpression(pattern: "(\\p{L})\\s*'\\s*(\\p{L})")
    private static let hyphenSpacingRegex = try! NSRegularExpression(pattern: "(\\p{L})\\s*-\\s*(\\p{L})")
    private static let preSymbolSpaceRegex = try! NSRegularExpression(pattern: "\\s+([,.;:!?%\\)\\]])")
    private static let postSymbolSpaceRegex = try! NSRegularExpression(pattern: "([\\(\\[])\\s+")
    private static let multipleSpacesRegex = try! NSRegularExpression(pattern: "[ \\t]{2,}")
    private static let wordTokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    package static func longestSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
        let maxOverlap = min(lhs.count, rhs.count)
        guard maxOverlap > 0 else { return 0 }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -overlap)
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: overlap)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return overlap
            }
        }

        return 0
    }

    /// `longestSuffixPrefixOverlap`, counting only an overlap that starts a
    /// word in `lhs`. A shared letter inside a word is a coincidence, not an
    /// alignment: "I need" + "doing" is not "I needoing" (#516).
    package static func wordAlignedSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
        let maxOverlap = min(lhs.count, rhs.count)
        guard maxOverlap > 0 else { return 0 }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -overlap)
            if lhsStart > lhs.startIndex, isWordCharacter(lhs[lhs.index(before: lhsStart)]) {
                continue
            }
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: overlap)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return overlap
            }
        }

        return 0
    }

    /// Whether raw transcript text begins inside a word. Voxtral's tokenizer
    /// carries a word's leading space on its first token, so text a new
    /// generation or a reconnected socket starts mid-word opens on the rest of
    /// that word, lowercase and with no space: "e help" after "Pleas".
    package static func startsMidWord(_ rawText: String) -> Bool {
        guard let first = rawText.first else { return false }
        return first.isLetter && first.isLowercase
    }

    /// The overlap to drop when joining `incoming` onto `existing`. Text that
    /// starts mid-word may repeat the end of the word it continues
    /// ("information" + "ation overload"), so it also aligns inside a word,
    /// on two letters or more.
    private static func joinOverlap(existing: String, incoming: String, incomingStartsMidWord: Bool) -> Int {
        let aligned = wordAlignedSuffixPrefixOverlap(lhs: existing, rhs: incoming)
        guard aligned == 0, incomingStartsMidWord else { return aligned }
        let unaligned = longestSuffixPrefixOverlap(lhs: existing, rhs: incoming)
        return unaligned >= 2 ? unaligned : 0
    }

    /// Whether text that `startsMidWord` finishes the last word of `existing`.
    private static func continuesLastWord(of existing: String, startsMidWord: Bool) -> Bool {
        startsMidWord && existing.last?.isLetter == true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Joins a finalized segment onto the dictation event. A segment boundary
    /// is where the backend ended a generation or the socket reconnected, not
    /// where the speaker paused, so it joins with a space, or with nothing
    /// when the segment `startsMidWord` (#516).
    package static func appendToCurrentDictationEvent(
        segment: String,
        existingText: String,
        segmentStartsMidWord: Bool = false
    ) -> String {
        let normalizedSegment = segment.trimmed
        guard !normalizedSegment.isEmpty else { return existingText }

        let normalizedExisting = existingText.trimmed
        guard !normalizedExisting.isEmpty else { return normalizedSegment }

        if normalizedSegment == normalizedExisting {
            return normalizedExisting
        }

        if normalizedSegment.hasPrefix(normalizedExisting) {
            return normalizedSegment
        }

        if normalizedExisting.hasSuffix(normalizedSegment) {
            return normalizedExisting
        }

        let overlap = joinOverlap(
            existing: normalizedExisting,
            incoming: normalizedSegment,
            incomingStartsMidWord: segmentStartsMidWord
        )
        if overlap > 0 {
            let overlapIndex = normalizedSegment.index(normalizedSegment.startIndex, offsetBy: overlap)
            let suffix = String(normalizedSegment[overlapIndex...])
            return normalizedExisting + suffix
        }

        if continuesLastWord(of: normalizedExisting, startsMidWord: segmentStartsMidWord) {
            return normalizedExisting + normalizedSegment
        }
        return normalizedExisting + " " + normalizedSegment
    }

    package static func longestCommonPrefixLength(lhs: String, rhs: String) -> Int {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        var length = 0

        while leftIndex < lhs.endIndex,
              rightIndex < rhs.endIndex,
              lhs[leftIndex] == rhs[rightIndex]
        {
            length += 1
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }

        return length
    }

    /// Computes the missing suffix to type into the focused field when a final
    /// transcript arrives after live partial deltas have already been inserted.
    ///
    /// Backends frequently deliver a trailing addition — typically the final
    /// "." — only in the `.finalTranscript`, never as a partial delta. When the
    /// final is a *pure extension* of the text already typed live
    /// (`finalText == liveInsertedText + suffix`, using the same preprocessing
    /// the live path applies on both sides), this returns exactly that suffix
    /// so it can be appended to the field without duplicating earlier text.
    ///
    /// Returns nil when the final revises earlier content (not a pure
    /// extension): live mode cannot rewrite already-typed text, so the caller
    /// keeps today's behavior of inserting nothing. Also returns nil for an
    /// empty suffix (final identical to the live text), making it a no-op.
    package static func livePasteExtensionSuffix(
        finalText: String,
        liveInsertedText: String
    ) -> String? {
        // The finalized-transcript path trims surrounding whitespace, so mirror
        // that here: a final of "hello. " must type "." — never a dangling
        // space the transcript itself discards.
        let normalizedFinal = finalText.trimmed
        guard !liveInsertedText.isEmpty, normalizedFinal.hasPrefix(liveInsertedText) else {
            return nil
        }
        let startIndex = normalizedFinal.index(
            normalizedFinal.startIndex,
            offsetBy: liveInsertedText.count
        )
        let suffix = String(normalizedFinal[startIndex...])
        return suffix.isEmpty ? nil : suffix
    }

    package static func stableWordBoundaryLength(in text: String, upTo rawLength: Int) -> Int {
        let length = min(max(0, rawLength), text.count)
        guard length > 0 else { return 0 }

        let boundaryIndex = text.index(text.startIndex, offsetBy: length)
        if boundaryIndex == text.endIndex {
            return length
        }

        let previousIndex = text.index(before: boundaryIndex)
        if isWordBoundaryCharacter(text[previousIndex]) || isWordBoundaryCharacter(text[boundaryIndex]) {
            return length
        }

        var cursor = boundaryIndex
        while cursor > text.startIndex {
            let prior = text.index(before: cursor)
            if isWordBoundaryCharacter(text[prior]) {
                return text.distance(from: text.startIndex, to: cursor)
            }
            cursor = prior
        }

        return 0
    }

    package static func isWordBoundaryCharacter(_ character: Character) -> Bool {
        if character.isWhitespace {
            return true
        }

        let punctuation = CharacterSet.punctuationCharacters
        return character.unicodeScalars.allSatisfy { punctuation.contains($0) }
    }

    package static func shouldAvoidLeadingSpace(before character: Character) -> Bool {
        let noLeadingSpaceBefore = CharacterSet(charactersIn: ".,!?;:)]}\"'%-")
        return character.unicodeScalars.allSatisfy { noLeadingSpaceBefore.contains($0) }
    }

    package static func appendWithTailOverlap(
        existing: String,
        incoming: String,
        incomingStartsMidWord: Bool = false
    ) -> (merged: String, appendedDelta: String) {
        guard !incoming.isEmpty else { return (existing, "") }
        guard !existing.isEmpty else { return (incoming, incoming) }

        if existing.hasSuffix(incoming) {
            return (existing, "")
        }

        if incoming.count >= replayCharacterThreshold, existing.contains(incoming) {
            return (existing, "")
        }

        let overlap = joinOverlap(
            existing: existing, incoming: incoming, incomingStartsMidWord: incomingStartsMidWord)
        if overlap > 0 {
            let start = incoming.index(incoming.startIndex, offsetBy: overlap)
            let delta = String(incoming[start...])
            return (existing + delta, delta)
        }

        if continuesLastWord(of: existing, startsMidWord: incomingStartsMidWord) {
            return (existing + incoming, incoming)
        }

        if incoming.count >= replayCharacterThreshold {
            let commonPrefix = longestCommonPrefixLength(lhs: existing, rhs: incoming)
            let prefixCoverage = Double(commonPrefix) / Double(incoming.count)
            if commonPrefix >= replayCharacterThreshold, prefixCoverage >= 0.8 {
                let boundary = stableWordBoundaryLength(in: incoming, upTo: commonPrefix)
                if boundary >= incoming.count {
                    return (existing, "")
                }
                if boundary > 0 {
                    let start = incoming.index(incoming.startIndex, offsetBy: boundary)
                    let trimmedSuffix = String(incoming[start...]).trimmed
                    if !trimmedSuffix.isEmpty {
                        return appendWithoutOverlap(existing: existing, incoming: trimmedSuffix)
                    }
                    return (existing, "")
                }
            }
        }

        if let boundary = replayBoundaryFromWordOverlap(existing: existing, incoming: incoming) {
            if boundary == incoming.endIndex {
                return (existing, "")
            }
            let suffix = String(incoming[boundary...]).trimmed
            if !suffix.isEmpty {
                return appendWithoutOverlap(existing: existing, incoming: suffix)
            }
            return (existing, "")
        }

        return appendWithoutOverlap(existing: existing, incoming: incoming)
    }

    /// Lightweight transcription cleanup for tokenizer spacing artifacts.
    /// This is intentionally conservative and should not rewrite semantics.
    package static func normalizeTranscriptionFormatting(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var output = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        output = applyRegex(apostropheSpacingRegex, template: "$1'$2", to: output)
        output = applyRegex(hyphenSpacingRegex, template: "$1-$2", to: output)
        output = applyRegex(preSymbolSpaceRegex, template: "$1", to: output)
        output = applyRegex(postSymbolSpaceRegex, template: "$1", to: output)
        output = applyRegex(multipleSpacesRegex, template: " ", to: output)
        return output
    }

    private static func applyRegex(_ regex: NSRegularExpression, template: String, to text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func appendWithoutOverlap(
        existing: String,
        incoming: String
    ) -> (merged: String, appendedDelta: String) {
        guard !incoming.isEmpty else { return (existing, "") }

        var adjustedIncoming = incoming
        if let existingLast = existing.last,
           let incomingFirst = incoming.first,
           !existingLast.isWhitespace,
           !incomingFirst.isWhitespace,
           !shouldAvoidLeadingSpace(before: incomingFirst)
        {
            adjustedIncoming = " " + incoming
        }

        return (existing + adjustedIncoming, adjustedIncoming)
    }

    private struct WordToken {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func replayBoundaryFromWordOverlap(existing: String, incoming: String) -> String.Index? {
        let existingTokens = wordTokens(in: existing)
        let incomingTokens = wordTokens(in: incoming)
        guard existingTokens.count >= replayWordThreshold,
              incomingTokens.count >= replayWordThreshold
        else {
            return nil
        }

        let maxOverlap = min(existingTokens.count, incomingTokens.count)
        for overlap in stride(from: maxOverlap, through: replayWordThreshold, by: -1) {
            let existingStart = existingTokens.count - overlap
            let existingSlice = existingTokens[existingStart...]
            let incomingSlice = incomingTokens[0 ..< overlap]
            var matched = true
            for (existingToken, incomingToken) in zip(existingSlice, incomingSlice) {
                if existingToken.normalized != incomingToken.normalized {
                    matched = false
                    break
                }
            }

            if matched {
                if overlap == incomingTokens.count {
                    return incoming.endIndex
                }
                return incomingTokens[overlap].range.lowerBound
            }
        }

        return nil
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        let nsRange = NSRange(text.startIndex..., in: text)
        let regex = wordTokenRegex
        let matches = regex.matches(in: text, options: [], range: nsRange)
        var tokens: [WordToken] = []
        tokens.reserveCapacity(matches.count)

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let token = text[range].lowercased()
            guard !token.isEmpty else { continue }
            tokens.append(WordToken(normalized: token, range: range))
        }

        return tokens
    }
}
