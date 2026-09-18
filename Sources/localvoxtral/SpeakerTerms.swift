import Foundation

/// The user's own list of names and terms, written the way they should appear
/// ("Qwen", "Claude Code", "vLLM"). Only the CORRECT spelling is stored — never
/// how the recognizer mishears it; working that out is the polish model's job.
///
/// One list, three consumers: the About-you block of the polish prompt, exact
/// casing/spacing fixes that need no model (so they also work in Live
/// Auto-Paste), and the one-time import of what the user had already typed
/// into `replacement_dictionary.toml`.
enum SpeakerTerms {
    static let maxTerms = 80
    static let maxTermCharacters = 60

    /// Single-line, trimmed, first spelling wins a case-insensitive duplicate.
    static func sanitized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in raw {
            let term = RepoVocabularyMatcher.sanitizedTerm(candidate)
                .replacingOccurrences(of: ",", with: " ")
                .collapsingInternalWhitespace
                .trimmed
            guard !term.isEmpty, term.count <= maxTermCharacters,
                  seen.insert(term.caseFoldedForMatching).inserted
            else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result
    }

    /// What one submission of the field adds: "Qwen, Claude Code" is two terms.
    static func adding(_ input: String, to terms: [String]) -> [String] {
        sanitized(terms + input.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init))
    }

    /// Rules that rewrite a term's own words to its spelling, whatever the
    /// case or spacing ("claude code" -> "Claude Code", "vllm" -> "vLLM").
    ///
    /// A plain capitalized word gets NO rule: with "Work" or "Vibe" in the list
    /// it would capitalize the ordinary word in every sentence, and nothing
    /// without a model can tell the product from the noun. Those terms reach
    /// the polish prompt only.
    static func replacementEntries(for terms: [String]) -> [ReplacementEntry] {
        sanitized(terms).compactMap { term in
            guard hasDistinctiveShape(term) else { return nil }
            return ReplacementEntry(replaceWith: term, matches: [term])
        }
    }

    static func hasDistinctiveShape(_ term: String) -> Bool {
        if term.contains(where: \.isWhitespace) { return true }
        if term.contains(where: { !$0.isLetter }) { return true }
        return term.dropFirst().contains(where: \.isUppercase)
    }

    /// The spellings the user already maintains in the replacement dictionary.
    static func migrated(from dictionary: ReplacementDictionary) -> [String] {
        sanitized(dictionary.entries.map(\.replaceWith))
    }
}

extension ReplacementDictionary {
    /// File entries first, so a rule the user wrote by hand wins a tie against
    /// the casing rule derived from a term.
    func adding(speakerTerms terms: [String]) -> ReplacementDictionary {
        ReplacementDictionary(entries: entries + SpeakerTerms.replacementEntries(for: terms))
    }
}
