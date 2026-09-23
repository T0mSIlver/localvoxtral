import Foundation

/// Clipboard entities join the vocabulary-hint pipeline: the clipboard polish-
/// context excerpt tells the model the exact spelling of a copied identifier.
/// Extracting its code-like entities with the existing `PolishTokenGuard`
/// recognizer plus a narrow technical-identifier supplement, matching
/// transcript n-grams against them exactly like repo vocabulary, then
/// pre-applying only the selected spans gives the model exact bytes without
/// scanning its output.
///
/// Pure functions; all privacy gating (feature toggle, loopback endpoint,
/// concealed/transient pasteboard) already happened when the excerpt was
/// captured — this type never touches the pasteboard.
package enum ClipboardVocabulary {
    /// Ordered, de-duplicated code-like entities in `excerpt`, recognized by
    /// `PolishTokenGuard.protectedTokens` plus a narrow supplemental grammar
    /// for long bare env vars, method signatures, and mixed-case identifiers.
    /// Backtick spans are unwrapped to their inner text: the vocabulary term
    /// is the identifier, not its markdown decoration.
    package static func entities(inExcerpt excerpt: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func append(_ term: String) {
            guard !term.isEmpty, seen.insert(term).inserted else { return }
            result.append(term)
        }
        for token in PolishTokenGuard.protectedTokens(in: excerpt) {
            var term = token
            if term.hasPrefix("`"), term.hasSuffix("`"), term.count > 2 {
                term = String(term.dropFirst().dropLast())
            }
            append(term)
        }
        // The guard recognizer is intentionally conservative and does not
        // cover every useful INPUT-side context spelling (notably a bare
        // ALL_CAPS env var, a method signature, or a PascalCase package name).
        // Admit only long tokens carrying machine-checkable technical signal;
        // ordinary clipboard prose never becomes a fallback candidate.
        for match in supplementalEntityRegex.matches(
            in: excerpt,
            range: NSRange(excerpt.startIndex..., in: excerpt)
        ) {
            guard let range = Range(match.range, in: excerpt) else { continue }
            var term = String(excerpt[range])
                .trimmingCharacters(in: supplementalEntityEdges)
            if term.hasSuffix(")"), !term.contains("(") {
                term.removeLast()
            }
            guard isSupplementalTechnicalEntity(term) else { continue }
            append(term)
        }
        return result
    }

    private static let supplementalEntityRegex = try! NSRegularExpression(
        pattern: #"[$#A-Za-z0-9][_$#A-Za-z0-9./:()'\-]{6,}"#
    )
    private static let supplementalEntityEdges = CharacterSet(
        charactersIn: "`'\"“”‘’[]{}<>.,;!?"
    )

    private static func isSupplementalTechnicalEntity(_ value: String) -> Bool {
        guard value.count >= 7 else { return false }
        let envBody = value.drop(while: { $0 == "$" })
        let isLongEnvironmentVariable = envBody.contains("_")
            && envBody.contains(where: { $0.isLetter })
            && envBody.allSatisfy { $0 == "_" || $0.isUppercase || $0.isNumber }
        if isLongEnvironmentVariable { return true }

        if let openParen = value.firstIndex(of: "("),
           openParen != value.startIndex,
           value.hasSuffix(")")
        {
            return true
        }

        let hasLowercase = value.contains { $0.isLowercase }
        let hasInternalUppercase = value.dropFirst().contains { $0.isUppercase }
        let hasLetter = value.contains { $0.isLetter }
        let hasNumber = value.contains { $0.isNumber }
        return (hasLowercase && hasInternalUppercase) || (hasLetter && hasNumber)
    }

    /// The transcript-relevant clipboard entities as replacement entries, via
    /// the exact matcher repo vocabulary uses (same n-gram windows, same
    /// normalization, same fuzzy tier, same cap). Empty when the excerpt holds
    /// no code-like entities or none matches the transcript.
    package static func candidateEntries(
        transcript: String,
        excerpt: String
    ) -> [ReplacementEntry] {
        candidateOutcome(transcript: transcript, clipboardText: excerpt).entries
    }

    /// `candidateEntries` with its provenance retained, over the COMPLETE
    /// retained clipboard text.
    ///
    /// `clipboardText` is deliberately not called `excerpt`: matching runs over
    /// everything capture retained, not over the smaller block the budget
    /// renders into the prompt. A term is groundable when the user copied it —
    /// not when it happened to survive excerpt selection.
    package static func candidateOutcome(
        transcript: String,
        clipboardText: String
    ) -> RepoVocabularyMatcher.GroundingOutcome {
        let terms = entities(inExcerpt: clipboardText)
        guard !terms.isEmpty else { return .empty }
        let vocabulary = RepoVocabulary(terms: terms, branch: nil)
        return RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: vocabulary
        )
    }
}
