import Foundation

extension String {
    /// Shorthand for `trimmingCharacters(in: .whitespacesAndNewlines)`.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
