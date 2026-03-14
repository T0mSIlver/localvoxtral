import Foundation

extension String {
    /// Shorthand for `trimmingCharacters(in: .whitespacesAndNewlines)`.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var collapsingInternalWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
