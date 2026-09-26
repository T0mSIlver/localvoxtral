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
    /// dictation and polishing never had to fix. Keeps one polishing fixed
    /// (casing included, `mcp` → `MCP`), and one found in no raw text at all:
    /// the model recovered it from misrecognitions, the most valuable kind.
    /// The fixed ones come first, most fixes first; ties keep the model's order.
    package static func screened(_ candidates: [String], dictations: [Dictation]) -> [String] {
        let scored = candidates.compactMap { candidate -> (term: String, fixes: Int)? in
            guard let exact = pattern(candidate, caseInsensitive: false),
                  let loose = pattern(candidate, caseInsensitive: true)
            else { return nil }
            var spelledRight = 0
            var fixes = 0
            for dictation in dictations {
                if occurs(exact, in: dictation.raw) {
                    spelledRight += 1
                } else if occurs(loose, in: dictation.final) {
                    fixes += 1
                }
            }
            guard fixes > 0 || spelledRight == 0 else { return nil }
            return (candidate, fixes)
        }
        return scored.enumerated()
            .sorted { ($0.element.fixes, -$0.offset) > ($1.element.fixes, -$1.offset) }
            .map(\.element.term)
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
