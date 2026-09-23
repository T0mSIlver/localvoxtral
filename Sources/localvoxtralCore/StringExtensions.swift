import Foundation

extension String {
    /// Shorthand for `trimmingCharacters(in: .whitespacesAndNewlines)`.
    package var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var collapsingInternalWhitespace: String {
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
    package var caseFoldedForMatching: String {
        folding(options: .caseInsensitive, locale: nil)
    }

    /// Drops NUL and other control scalars (which can corrupt the request or the
    /// LLM's parsing) while preserving newlines and tabs so multi-line snippets
    /// and indentation survive as spelling context.
    package var sanitizedControlCharacters: String {
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
