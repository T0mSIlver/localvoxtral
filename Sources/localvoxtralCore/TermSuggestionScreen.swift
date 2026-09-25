import Foundation

/// Keeps the suggested terms a vocabulary entry would actually help: the
/// ones the recognizer gets wrong. The model reads polished text and cannot
/// tell "IBM", which every recognizer spells, from "Qwen", heard as "Coin"
/// (owner's GLM 5.3 run, 2026-09-25: IBM, Mac, Word, ChatGPT, S3, 3090). The
/// raw transcript can: it is the recognizer's own spelling, so no dictionary
/// or capitalization rule is involved (owner ruling, 2026-09-18).
package enum TermSuggestionScreen {
    /// One saved dictation: what the recognizer wrote and what was committed.
    package struct Dictation: Equatable, Sendable {
        package let raw: String
        package let final: String

        package init(raw: String, final: String) {
            self.raw = raw
            self.final = final
        }
    }

    /// Drops a candidate the recognizer wrote spelled exactly right in some
    /// dictation, when nothing shows it ever getting it wrong. Two things do:
    /// polishing fixing it (casing included, `mcp` → `MCP`), or a wrong form
    /// the model quotes in `heard` that really is in a transcript, which
    /// catches a mistake polishing left in the final text too. A candidate in
    /// no raw text at all stays: the model recovered it from misrecognitions,
    /// the most valuable kind. Candidates are ranked by the dictations that
    /// show a mistake; ties keep the model's order.
    ///
    /// `heard` maps a candidate to the wrong forms the model quoted; a form
    /// found in no transcript counts for nothing.
    package static func screened(
        _ candidates: [String], dictations: [Dictation], heard: [String: [String]] = [:]
    ) -> [String] {
        let heardByKey = Dictionary(heard.map { (key($0.key), $0.value) }, uniquingKeysWith: +)
        let scored = candidates.compactMap { candidate -> (term: String, misses: Int)? in
            guard let exact = pattern(candidate, caseInsensitive: false),
                  let loose = pattern(candidate, caseInsensitive: true)
            else { return nil }
            // Exact, as the model is told to copy them; "v l l m" and "vllm"
            // are mistakes for vLLM, "vLLM" is not.
            let wrongForms = (heardByKey[key(candidate)] ?? [])
                .filter { $0.trimmed != candidate.trimmed }
                .compactMap { pattern($0, caseInsensitive: false) }
            var spelledRight = 0
            var misses = 0
            for dictation in dictations {
                if occurs(exact, in: dictation.raw) {
                    spelledRight += 1
                } else if occurs(loose, in: dictation.final)
                    || wrongForms.contains(where: { occurs($0, in: dictation.raw) })
                {
                    misses += 1
                }
            }
            guard misses > 0 || spelledRight == 0 else { return nil }
            return (candidate, misses)
        }
        return scored.enumerated()
            .sorted { ($0.element.misses, -$0.offset) > ($1.element.misses, -$1.offset) }
            .map(\.element.term)
    }

    /// Case, spacing and punctuation ignored, as `SpeakerTermSuggestions.key`.
    private static func key(_ term: String) -> String {
        String(term.caseFoldedForMatching.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// The term as a whole word: "Mac" is not found in "MacBook" or "iMac".
    private static func pattern(_ term: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: trimmed))(?![\\p{L}\\p{N}])",
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    private static func occurs(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
