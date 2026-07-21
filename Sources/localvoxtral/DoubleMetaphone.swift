import Foundation

/// Pure Swift Double Metaphone (Lawrence Philips, 2000) for the phonetic
/// grounding tier. Repository terms and ASR output can be several character
/// edits apart while still sounding alike; the two pronunciation keys let the
/// matcher recognize that relationship without making locale-dependent or
/// model-dependent guesses.
///
/// This follows the published rule set, including its Germanic,
/// Slavo-Germanic, Romance, and alternate-pronunciation branches. Unlike the
/// classic implementation, which stops after four key characters, this
/// implementation deliberately keeps the complete keys so long identifiers
/// remain discriminative.
///
/// One further consequence of the single-word contract: rules that inspect
/// spaces inside the input ("VAN ", "VON ", "SAN ", " C") can never match,
/// because normalization strips everything but letters. Those branches are
/// kept verbatim for structural parity with the reference, not because they
/// are reachable.
enum DoubleMetaphone {
    struct Key: Equatable, Hashable, Sendable {
        let primary: String
        /// Equal to `primary` when the word has no alternate pronunciation.
        let secondary: String
    }

    /// Encodes one word (no whitespace expected; caller pre-splits).
    ///
    /// Diacritics are folded before applying the algorithm. Characters that
    /// do not normalize to ASCII letters are ignored, which keeps digits and
    /// identifier punctuation from manufacturing phonetic sounds.
    static func encode(_ word: String) -> Key {
        let folded = word.folding(
            options: [.diacriticInsensitive],
            locale: Locale(identifier: "en_US")
        ).uppercased()
        let letters = folded.unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return Character(String(scalar))
        }
        guard !letters.isEmpty else { return Key(primary: "", secondary: "") }

        var encoder = Encoder(letters: letters)
        return encoder.encode()
    }

    /// True when any primary/secondary pairing of the two keys is equal and
    /// non-empty.
    static func keysMatch(_ a: Key, _ b: Key) -> Bool {
        let left = [a.primary, a.secondary]
        let right = [b.primary, b.secondary]
        return left.contains { candidate in
            !candidate.isEmpty && right.contains(candidate)
        }
    }
}

private extension DoubleMetaphone {
    struct Encoder {
        let letters: [Character]
        let isSlavoGermanic: Bool
        var index: Int
        var primary = ""
        var secondary = ""

        init(letters: [Character]) {
            self.letters = letters
            isSlavoGermanic = letters.contains("W")
                || letters.contains("K")
                || Self.containsAnywhere(letters, "CZ")
                || Self.containsAnywhere(letters, "WITZ")
            index = Self.contains(letters, at: 0, anyOf: ["GN", "KN", "PN", "WR", "PS"])
                ? 1
                : 0
        }

        mutating func encode() -> Key {
            if character(at: 0) == "X" {
                append("S")
                index += 1
            }

            while index < letters.count {
                switch letters[index] {
                case "A", "E", "I", "O", "U", "Y":
                    if index == 0 { append("A") }
                    index += 1
                case "B":
                    append("P")
                    index += character(at: index + 1) == "B" ? 2 : 1
                case "C":
                    index = handleC(at: index)
                case "D":
                    index = handleD(at: index)
                case "F":
                    append("F")
                    index += character(at: index + 1) == "F" ? 2 : 1
                case "G":
                    index = handleG(at: index)
                case "H":
                    index = handleH(at: index)
                case "J":
                    index = handleJ(at: index)
                case "K":
                    append("K")
                    index += character(at: index + 1) == "K" ? 2 : 1
                case "L":
                    index = handleL(at: index)
                case "M":
                    append("M")
                    index += conditionM(at: index) ? 2 : 1
                case "N":
                    append("N")
                    index += character(at: index + 1) == "N" ? 2 : 1
                case "P":
                    index = handleP(at: index)
                case "Q":
                    append("K")
                    index += character(at: index + 1) == "Q" ? 2 : 1
                case "R":
                    index = handleR(at: index)
                case "S":
                    index = handleS(at: index)
                case "T":
                    index = handleT(at: index)
                case "V":
                    append("F")
                    index += character(at: index + 1) == "V" ? 2 : 1
                case "W":
                    index = handleW(at: index)
                case "X":
                    index = handleX(at: index)
                case "Z":
                    index = handleZ(at: index)
                default:
                    index += 1
                }
            }

            return Key(primary: primary, secondary: secondary)
        }

        // MARK: - C

        mutating func handleC(at position: Int) -> Int {
            if conditionC0(at: position) {
                append("K")
                return position + 2
            }
            if position == 0, contains(at: position, "CAESAR") {
                append("S")
                return position + 2
            }
            if contains(at: position, "CHIA") {
                append("K")
                return position + 2
            }
            if contains(at: position, "CH") {
                return handleCH(at: position)
            }
            if contains(at: position, "CZ"), !contains(at: position - 2, "WICZ") {
                append("S", "X")
                return position + 2
            }
            if contains(at: position + 1, "CIA") {
                append("X")
                return position + 3
            }
            if contains(at: position, "CC"), !(position == 1 && character(at: 0) == "M") {
                return handleCC(at: position)
            }
            if contains(at: position, "CK", "CG", "CQ") {
                append("K")
                return position + 2
            }
            if contains(at: position, "CI", "CE", "CY") {
                if contains(at: position, "CIO", "CIE", "CIA") {
                    append("S", "X")
                } else {
                    append("S")
                }
                return position + 2
            }

            append("K")
            if contains(at: position + 1, " C", " Q", " G") {
                return position + 3
            }
            if contains(at: position + 1, "C", "K", "Q")
                && !contains(at: position + 1, "CE", "CI") {
                return position + 2
            }
            return position + 1
        }

        func conditionC0(at position: Int) -> Bool {
            guard position > 1,
                  !isVowel(at: position - 2),
                  contains(at: position - 1, "ACH") else {
                return false
            }
            let after = character(at: position + 2)
            return (after != "I" && after != "E")
                || contains(at: position - 2, "BACHER", "MACHER")
        }

        mutating func handleCH(at position: Int) -> Int {
            if position > 0, contains(at: position, "CHAE") {
                append("K", "X")
            } else if conditionCH0(at: position) || conditionCH1(at: position) {
                append("K")
            } else if position > 0 {
                if contains(at: 0, "MC") {
                    append("K")
                } else {
                    append("X", "K")
                }
            } else {
                append("X")
            }
            return position + 2
        }

        func conditionCH0(at position: Int) -> Bool {
            guard position == 0 else { return false }
            return (contains(at: position + 1, "HARAC", "HARIS")
                    || contains(at: position + 1, "HOR", "HYM", "HIA", "HEM"))
                && !contains(at: 0, "CHORE")
        }

        func conditionCH1(at position: Int) -> Bool {
            if contains(at: 0, "VAN ", "VON ") || contains(at: 0, "SCH") {
                return true
            }
            if contains(at: position - 2, "ORCHES", "ARCHIT", "ORCHID")
                || contains(at: position + 2, "T", "S") {
                return true
            }
            guard position == 0 || contains(at: position - 1, "A", "O", "U", "E") else {
                return false
            }
            return contains(at: position + 2, "L", "R", "N", "M", "B", "H", "F", "V", "W")
                || position + 2 == letters.count
        }

        mutating func handleCC(at position: Int) -> Int {
            if contains(at: position + 2, "I", "E", "H")
                && !contains(at: position + 2, "HU") {
                if (position == 1 && character(at: position - 1) == "A")
                    || contains(at: position - 1, "UCCEE", "UCCES") {
                    append("KS")
                } else {
                    append("X")
                }
                return position + 3
            }
            append("K")
            return position + 2
        }

        // MARK: - D through H

        mutating func handleD(at position: Int) -> Int {
            if contains(at: position, "DG") {
                if contains(at: position + 2, "I", "E", "Y") {
                    append("J")
                    return position + 3
                }
                append("TK")
                return position + 2
            }
            if contains(at: position, "DT", "DD") {
                append("T")
                return position + 2
            }
            append("T")
            return position + 1
        }

        mutating func handleG(at position: Int) -> Int {
            if character(at: position + 1) == "H" {
                return handleGH(at: position)
            }
            if character(at: position + 1) == "N" {
                if position == 1, isVowel(at: 0), !isSlavoGermanic {
                    append("KN", "N")
                } else if !contains(at: position + 2, "EY")
                            // The reference checks the letter after the G —
                            // always the N here, so the condition is
                            // vacuously true. Kept verbatim for bit-parity
                            // with published key tables.
                            && character(at: position + 1) != "Y"
                            && !isSlavoGermanic {
                    append("N", "KN")
                } else {
                    append("KN")
                }
                return position + 2
            }
            if contains(at: position + 1, "LI"), !isSlavoGermanic {
                append("KL", "L")
                return position + 2
            }
            if position == 0,
               (character(at: position + 1) == "Y"
                || contains(at: position + 1, "ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER")) {
                append("K", "J")
            } else if (contains(at: position + 1, "ER") || character(at: position + 1) == "Y")
                        && !contains(at: 0, "DANGER", "RANGER", "MANGER")
                        && !contains(at: position - 1, "E", "I")
                        && !contains(at: position - 1, "RGY", "OGY") {
                append("K", "J")
            } else if contains(at: position + 1, "E", "I", "Y")
                        || contains(at: position - 1, "AGGI", "OGGI") {
                if contains(at: 0, "VAN ", "VON ")
                    || contains(at: 0, "SCH")
                    || contains(at: position + 1, "ET") {
                    append("K")
                } else if contains(at: position + 1, "IER"),
                          position + 4 == letters.count {
                    // The reference matches "IER " against its trailing
                    // padding, i.e. only at the end of the word.
                    append("J")
                } else {
                    append("J", "K")
                }
            } else {
                append("K")
            }
            return position + (character(at: position + 1) == "G" ? 2 : 1)
        }

        mutating func handleGH(at position: Int) -> Int {
            if position > 0, !isVowel(at: position - 1) {
                append("K")
            } else if position == 0 {
                append(character(at: position + 2) == "I" ? "J" : "K")
            } else if (position > 1 && contains(at: position - 2, "B", "H", "D"))
                        || (position > 2 && contains(at: position - 3, "B", "H", "D"))
                        || (position > 3 && contains(at: position - 4, "B", "H")) {
                // Parker's rule: -bough, -hugh, and -dough make GH silent.
            } else if position > 2,
                      character(at: position - 1) == "U",
                      contains(at: position - 3, "C", "G", "L", "R", "T") {
                append("F")
            } else if position > 0, character(at: position - 1) != "I" {
                append("K")
            }
            return position + 2
        }

        mutating func handleH(at position: Int) -> Int {
            if (position == 0 || isVowel(at: position - 1)), isVowel(at: position + 1) {
                append("H")
                return position + 2
            }
            return position + 1
        }

        // MARK: - J through R

        mutating func handleJ(at position: Int) -> Int {
            if contains(at: position, "JOSE") || contains(at: 0, "SAN ") {
                if (position == 0 && character(at: position + 4) == nil)
                    || contains(at: 0, "SAN ") {
                    append("H")
                } else {
                    append("J", "H")
                }
            } else if position == 0 {
                append("J", "A")
            } else if isVowel(at: position - 1),
                      !isSlavoGermanic,
                      contains(at: position + 1, "A", "O") {
                append("J", "H")
            } else if position == letters.count - 1 {
                appendPrimary("J")
            } else if !contains(at: position + 1, "L", "T", "K", "S", "N", "M", "B", "Z")
                        && !contains(at: position - 1, "S", "K", "L") {
                append("J")
            }
            return position + (character(at: position + 1) == "J" ? 2 : 1)
        }

        mutating func handleL(at position: Int) -> Int {
            append("L")
            if character(at: position + 1) == "L" {
                if conditionL0(at: position) {
                    // Spanish -illo/-illa and -alle commonly drop the final L.
                    secondary.removeLast()
                }
                return position + 2
            }
            return position + 1
        }

        func conditionL0(at position: Int) -> Bool {
            if position == letters.count - 3,
               contains(at: position - 1, "ILLO", "ILLA", "ALLE") {
                return true
            }
            return (contains(at: letters.count - 2, "AS", "OS")
                    || contains(at: letters.count - 1, "A", "O"))
                && contains(at: position - 1, "ALLE")
        }

        func conditionM(at position: Int) -> Bool {
            if character(at: position + 1) == "M" { return true }
            return contains(at: position - 1, "UMB")
                && (position + 1 == letters.count - 1 || contains(at: position + 2, "ER"))
        }

        mutating func handleP(at position: Int) -> Int {
            if character(at: position + 1) == "H" {
                append("F")
                return position + 2
            }
            append("P")
            return position + (contains(at: position + 1, "P", "B") ? 2 : 1)
        }

        mutating func handleR(at position: Int) -> Int {
            if position == letters.count - 1,
               !isSlavoGermanic,
               contains(at: position - 2, "IE"),
               !contains(at: position - 4, "ME", "MA") {
                appendSecondary("R")
            } else {
                append("R")
            }
            return position + (character(at: position + 1) == "R" ? 2 : 1)
        }

        // MARK: - S through Z

        mutating func handleS(at position: Int) -> Int {
            if contains(at: position - 1, "ISL", "YSL") {
                return position + 1
            }
            if position == 0, contains(at: position, "SUGAR") {
                append("X", "S")
                return position + 1
            }
            if contains(at: position, "SH") {
                if contains(at: position + 1, "HEIM", "HOEK", "HOLM", "HOLZ") {
                    append("S")
                } else {
                    append("X")
                }
                return position + 2
            }
            if contains(at: position, "SIO", "SIA") || contains(at: position, "SIAN") {
                if isSlavoGermanic {
                    append("S")
                } else {
                    append("S", "X")
                }
                return position + 3
            }
            if (position == 0 && contains(at: position + 1, "M", "N", "L", "W"))
                || character(at: position + 1) == "Z" {
                append("S", "X")
                return position + (character(at: position + 1) == "Z" ? 2 : 1)
            }
            if contains(at: position, "SC") {
                return handleSC(at: position)
            }
            if position == letters.count - 1, contains(at: position - 2, "AI", "OI") {
                appendSecondary("S")
            } else {
                append("S")
            }
            return position + (contains(at: position + 1, "S", "Z") ? 2 : 1)
        }

        mutating func handleSC(at position: Int) -> Int {
            if character(at: position + 2) == "H" {
                if contains(at: position + 3, "OO", "ER", "EN", "UY", "ED", "EM") {
                    if contains(at: position + 3, "ER", "EN") {
                        append("X", "SK")
                    } else {
                        append("SK")
                    }
                } else if position == 0,
                          !isVowel(at: 3),
                          character(at: 3) != "W" {
                    append("X", "S")
                } else {
                    append("X")
                }
                return position + 3
            }
            if contains(at: position + 2, "I", "E", "Y") {
                append("S")
                return position + 3
            }
            append("SK")
            return position + 3
        }

        mutating func handleT(at position: Int) -> Int {
            if contains(at: position, "TION") {
                append("X")
                return position + 3
            }
            if contains(at: position, "TIA", "TCH") {
                append("X")
                return position + 3
            }
            if contains(at: position, "TH", "TTH") {
                if contains(at: position + 2, "OM", "AM")
                    || contains(at: 0, "VAN ", "VON ")
                    || contains(at: 0, "SCH") {
                    append("T")
                } else {
                    append("0", "T")
                }
                return position + 2
            }
            append("T")
            return position + (contains(at: position + 1, "T", "D") ? 2 : 1)
        }

        mutating func handleW(at position: Int) -> Int {
            if contains(at: position, "WR") {
                append("R")
                return position + 2
            }
            if position == 0,
               (isVowel(at: position + 1) || contains(at: position, "WH")) {
                if isVowel(at: position + 1) {
                    append("A", "F")
                } else {
                    append("A")
                }
                // No return: the reference falls through, so an initial
                // "witz"/"wicz" still reaches the WICZ rule below.
            }
            if (position == letters.count - 1 && isVowel(at: position - 1))
                || contains(at: position - 1, "EWSKI", "EWSKY", "OWSKI", "OWSKY")
                || contains(at: 0, "SCH") {
                appendSecondary("F")
                return position + 1
            }
            if contains(at: position, "WICZ", "WITZ") {
                append("TS", "FX")
                return position + 4
            }
            return position + 1
        }

        mutating func handleX(at position: Int) -> Int {
            if position == 0 {
                append("S")
                return position + 1
            }
            if position != letters.count - 1
                || (!contains(at: position - 3, "IAU", "EAU")
                    && !contains(at: position - 2, "AU", "OU")) {
                append("KS")
            }
            return position + (contains(at: position + 1, "C", "X") ? 2 : 1)
        }

        mutating func handleZ(at position: Int) -> Int {
            if character(at: position + 1) == "H" {
                append("J")
                return position + 2
            }
            if contains(at: position + 1, "ZO", "ZI", "ZA")
                || (isSlavoGermanic && position > 0 && character(at: position - 1) != "T") {
                append("S", "TS")
            } else {
                append("S")
            }
            return position + (character(at: position + 1) == "Z" ? 2 : 1)
        }

        // MARK: - Result and lookup helpers

        mutating func append(_ value: String) {
            primary += value
            secondary += value
        }

        mutating func append(_ primaryValue: String, _ secondaryValue: String) {
            primary += primaryValue
            secondary += secondaryValue
        }

        mutating func appendPrimary(_ value: String) {
            primary += value
        }

        mutating func appendSecondary(_ value: String) {
            secondary += value
        }

        func character(at position: Int) -> Character? {
            guard letters.indices.contains(position) else { return nil }
            return letters[position]
        }

        func isVowel(at position: Int) -> Bool {
            guard let value = character(at: position) else { return false }
            return value == "A" || value == "E" || value == "I"
                || value == "O" || value == "U" || value == "Y"
        }

        func contains(at position: Int, _ candidates: String...) -> Bool {
            Self.contains(letters, at: position, anyOf: candidates)
        }

        static func contains(_ letters: [Character], at position: Int, anyOf candidates: [String]) -> Bool {
            guard position >= 0 else { return false }
            return candidates.contains { candidate in
                let expected = Array(candidate)
                guard position + expected.count <= letters.count else { return false }
                return Array(letters[position..<(position + expected.count)]) == expected
            }
        }

        static func containsAnywhere(_ letters: [Character], _ candidate: String) -> Bool {
            let expected = Array(candidate)
            guard !expected.isEmpty, expected.count <= letters.count else { return false }
            return (0...(letters.count - expected.count)).contains { position in
                Array(letters[position..<(position + expected.count)]) == expected
            }
        }
    }
}
