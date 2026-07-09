import Foundation

extension String {
    /// Shorthand for `trimmingCharacters(in: .whitespacesAndNewlines)`.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var collapsingInternalWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Full Unicode case folding, matching how `NSRegularExpression` compares
    /// literals under `.caseInsensitive`: `ß` folds to `ss`, `ﬁ` to `fi`, and
    /// U+212A KELVIN SIGN to `k`.
    ///
    /// Folding is defined per code point, so it distributes over concatenation
    /// — the fold of a prefix is a prefix of the fold. That is what lets
    /// `LiveHoldBackReplacementStream` decide whether partially-dictated text
    /// can still grow into a replacement-rule match. `lowercased()` is not a
    /// substitute: it leaves `ß` alone, and the rule `foo ßx` really does match
    /// the text "foo ssx".
    var caseFoldedForMatching: String {
        folding(options: .caseInsensitive, locale: nil)
    }
}
