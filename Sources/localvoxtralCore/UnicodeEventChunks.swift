import Foundation

/// The UTF-16 slices keyboard insertion hands to `keyboardSetUnicodeString`,
/// one keyboard event each.
package enum UnicodeEventChunks {
    /// Units per event. The Claude Desktop measurements in
    /// `docs/agent/invariants.md` were made with this size.
    package static let maxUnits = 20

    /// Cuts `text` into chunks of at most `maxUnits` units, only between
    /// grapheme clusters, so no event carries half a surrogate pair or a
    /// character without its combining marks (#1092). A cluster longer than
    /// one event (a long ZWJ sequence) is cut between its scalars.
    package static func chunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []

        func append(_ units: [UInt16]) {
            if current.count + units.count > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current += units
        }

        for character in text {
            let units = Array(character.utf16)
            if units.count <= maxUnits {
                append(units)
            } else {
                for scalar in character.unicodeScalars {
                    append(Array(String(scalar).utf16))
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
