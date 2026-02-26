import Foundation

enum TextMergingAlgorithms {
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

    static func longestSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
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

    static func mergeIncrementalText(existing: String, incoming: String) -> (merged: String, appendedDelta: String) {
        guard !incoming.isEmpty else { return (existing, "") }
        guard !existing.isEmpty else { return (incoming, incoming) }

        if incoming == existing {
            return (existing, "")
        }

        if incoming.hasPrefix(existing) {
            let start = incoming.index(incoming.startIndex, offsetBy: existing.count)
            let delta = String(incoming[start...])
            return (incoming, delta)
        }

        if existing.hasSuffix(incoming) || existing.contains(incoming) {
            return (existing, "")
        }

        let overlap = longestSuffixPrefixOverlap(lhs: existing, rhs: incoming)
        if overlap > 0 {
            let start = incoming.index(incoming.startIndex, offsetBy: overlap)
            let delta = String(incoming[start...])
            return (existing + delta, delta)
        }

        return (existing + incoming, incoming)
    }

    static func appendToCurrentDictationEvent(segment: String, existingText: String) -> String {
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

        let overlap = longestSuffixPrefixOverlap(lhs: normalizedExisting, rhs: normalizedSegment)
        if overlap > 0 {
            let overlapIndex = normalizedSegment.index(normalizedSegment.startIndex, offsetBy: overlap)
            let suffix = String(normalizedSegment[overlapIndex...])
            return normalizedExisting + suffix
        }

        return normalizedExisting + "\n" + normalizedSegment
    }

    static func longestCommonPrefixLength(lhs: String, rhs: String) -> Int {
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

    static func stableWordBoundaryLength(in text: String, upTo rawLength: Int) -> Int {
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

    static func isWordBoundaryCharacter(_ character: Character) -> Bool {
        if character.isWhitespace {
            return true
        }

        let punctuation = CharacterSet.punctuationCharacters
        return character.unicodeScalars.allSatisfy { punctuation.contains($0) }
    }

    static func shouldAvoidLeadingSpace(before character: Character) -> Bool {
        let noLeadingSpaceBefore = CharacterSet(charactersIn: ".,!?;:)]}\"'%-")
        return character.unicodeScalars.allSatisfy { noLeadingSpaceBefore.contains($0) }
    }

    static func appendWithTailOverlap(
        existing: String,
        incoming: String
    ) -> (merged: String, appendedDelta: String) {
        guard !incoming.isEmpty else { return (existing, "") }
        guard !existing.isEmpty else { return (incoming, incoming) }

        if existing.hasSuffix(incoming) {
            return (existing, "")
        }

        if incoming.count >= replayCharacterThreshold, existing.contains(incoming) {
            return (existing, "")
        }

        let overlap = longestSuffixPrefixOverlap(lhs: existing, rhs: incoming)
        if overlap > 0 {
            let start = incoming.index(incoming.startIndex, offsetBy: overlap)
            let delta = String(incoming[start...])
            return (existing + delta, delta)
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
    static func normalizeTranscriptionFormatting(_ text: String) -> String {
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
