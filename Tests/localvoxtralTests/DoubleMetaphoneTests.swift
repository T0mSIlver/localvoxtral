import XCTest
@testable import localvoxtral

final class DoubleMetaphoneTests: XCTestCase {
    func testPublishedReferenceVectors_includeBothPronunciationsWithoutTruncation() {
        // These are the standard names and rule-exercising words used by
        // Double Metaphone reference implementations. Classic tables stop each
        // result at four characters; expectations below continue the same rule
        // evaluation to the end of the word, as localvoxtral's API requires.
        let vectors: [(word: String, primary: String, secondary: String)] = [
            ("smith", "SM0", "XMT"),
            ("schmidt", "XMT", "SMT"),
            ("school", "SKL", "SKL"),
            ("thomas", "TMS", "TMS"),
            ("wright", "RT", "RT"),
            ("knight", "NT", "NT"),
            ("pneumonia", "NMN", "NMN"),
            ("psalm", "SLM", "SLM"),
            // Final-R rule: a terminal R preceded by "IE" (French-style
            // ending) is dropped from the primary and kept in the secondary.
            ("Xavier", "SF", "SFR"),
            ("whale", "AL", "AL"),
            ("jose", "HS", "HS"),
            ("cabrillo", "KPRL", "KPR"),
            ("ghost", "KST", "KST"),
            ("caesar", "SSR", "SSR"),
            ("chianti", "KNT", "KNT"),
            // The CH in "michael" is hard: K primary, X (SH) alternate —
            // matches the Apache Commons reference implementation.
            ("michael", "MKL", "MXL"),
            ("aggie", "AJ", "AK"),
            ("edge", "AJ", "AJ"),
            ("gnome", "NM", "NM"),
            ("filipowicz", "FLPTS", "FLPFX"),
            ("Robert", "RPRT", "RPRT"),
            ("Rupert", "RPRT", "RPRT"),
            ("Rubin", "RPN", "RPN"),
            ("Ashcraft", "AXKRFT", "AXKRFT"),
            ("Tymczak", "TMSK", "TMXK"),
            ("Pfister", "PFSTR", "PFSTR"),
            ("Honeyman", "HNMN", "HNMN"),
            ("Jackson", "JKSN", "AKSN"),
            ("accident", "AKSTNT", "AKSTNT"),
            ("bacchus", "PKS", "PKS"),
            ("bacher", "PKR", "PKR"),
            ("macher", "MKR", "MKR"),
            ("czerny", "SRN", "XRN"),
            ("arnow", "ARN", "ARNF"),
            ("campbell", "KMPL", "KMPL"),
            ("raspberry", "RSPR", "RSPR"),
            ("island", "ALNT", "ALNT"),
            ("sugar", "XKR", "SKR"),
            ("chore", "XR", "XR"),
            ("charac", "KRK", "KRK"),
            ("architect", "ARKTKT", "ARKTKT"),
            ("orchestra", "ARKSTR", "ARKSTR"),
            ("orchid", "ARKT", "ARKT"),
            ("question", "KSXN", "KSXN"),
            ("danger", "TNJR", "TNKR"),
            ("ranger", "RNJR", "RNKR"),
            ("manger", "MNJR", "MNKR"),
            ("gypsy", "KPS", "JPS"),
            ("tagliaro", "TKLR", "TLR"),
            ("resnais", "RSN", "RSNS"),
            ("rogier", "RJ", "RJR"),
            ("breaux", "PR", "PR"),
            ("cough", "KF", "KF"),
            ("laugh", "LF", "LF"),
            ("dumb", "TM", "TM"),
            ("thumb", "0M", "TM"),
        ]

        for vector in vectors {
            XCTAssertEqual(
                DoubleMetaphone.encode(vector.word),
                DoubleMetaphone.Key(primary: vector.primary, secondary: vector.secondary),
                "Unexpected keys for \(vector.word)"
            )
        }
    }

    func testLongKeys_areNotTruncatedAtClassicFourCharacterLimit() {
        XCTAssertEqual(
            DoubleMetaphone.encode("filipowicz"),
            DoubleMetaphone.Key(primary: "FLPTS", secondary: "FLPFX")
        )
        XCTAssertEqual(
            DoubleMetaphone.encode("architect"),
            DoubleMetaphone.Key(primary: "ARKTKT", secondary: "ARKTKT")
        )
    }

    func testCanonicalRuleEdges_matchReferenceImplementation() {
        // Non-initial GN not followed by "EY": the reference keeps a
        // (vacuously true) check on the letter after the G, so a "-GNY-"
        // word is N primary / KN secondary — not KN/KN.
        XCTAssertEqual(
            DoubleMetaphone.encode("signy"),
            DoubleMetaphone.Key(primary: "SN", secondary: "SKN")
        )
        // A word-initial W before a vowel appends its vowel sound and then
        // falls through, so an initial "witz"/"wicz" still reaches the
        // WICZ rule — as the reference does.
        XCTAssertEqual(
            DoubleMetaphone.encode("witz"),
            DoubleMetaphone.Key(primary: "ATS", secondary: "FFX")
        )
        // "-GIER" softens G only at the end of the word; mid-word the
        // J/K alternates survive.
        XCTAssertEqual(
            DoubleMetaphone.encode("rogiers"),
            DoubleMetaphone.Key(primary: "RJRS", secondary: "RKRS")
        )
    }

    func testMotivatingPhoneticRelationships() {
        let pain = DoubleMetaphone.encode("pain")
        let pane = DoubleMetaphone.encode("pane")
        let claude = DoubleMetaphone.encode("claude")
        let clothes = DoubleMetaphone.encode("clothes")
        let close = DoubleMetaphone.encode("close")

        XCTAssertEqual(pain, DoubleMetaphone.Key(primary: "PN", secondary: "PN"))
        XCTAssertEqual(pane, DoubleMetaphone.Key(primary: "PN", secondary: "PN"))
        XCTAssertTrue(DoubleMetaphone.keysMatch(pain, pane))

        XCTAssertEqual(claude, DoubleMetaphone.Key(primary: "KLT", secondary: "KLT"))
        XCTAssertEqual(clothes, DoubleMetaphone.Key(primary: "KL0S", secondary: "KLTS"))
        XCTAssertEqual(close, DoubleMetaphone.Key(primary: "KLS", secondary: "KLS"))
        XCTAssertFalse(DoubleMetaphone.keysMatch(claude, clothes))
        XCTAssertFalse(DoubleMetaphone.keysMatch(claude, close))
    }

    func testShortWords_canIntentionallyCollide() {
        // Both encode to KT. Candidate-length and evidence guards belong to
        // the matcher tier, not to this faithful phonetic primitive.
        let expected = DoubleMetaphone.Key(primary: "KT", secondary: "KT")
        XCTAssertEqual(DoubleMetaphone.encode("code"), expected)
        XCTAssertEqual(DoubleMetaphone.encode("coat"), expected)
        XCTAssertTrue(
            DoubleMetaphone.keysMatch(
                DoubleMetaphone.encode("code"),
                DoubleMetaphone.encode("coat")
            )
        )
    }

    func testNormalizationAndEmptyInputs() {
        let empty = DoubleMetaphone.Key(primary: "", secondary: "")
        XCTAssertEqual(DoubleMetaphone.encode(""), empty)
        XCTAssertEqual(DoubleMetaphone.encode("2048"), empty)
        XCTAssertEqual(
            DoubleMetaphone.encode("auth2"),
            DoubleMetaphone.Key(primary: "A0", secondary: "AT")
        )
        XCTAssertEqual(DoubleMetaphone.encode("café"), DoubleMetaphone.encode("cafe"))
        XCTAssertEqual(DoubleMetaphone.encode("SCHMIDT"), DoubleMetaphone.encode("schmidt"))
    }

    func testSingleLetterAndAllVowelWords() {
        XCTAssertEqual(
            DoubleMetaphone.encode("a"),
            DoubleMetaphone.Key(primary: "A", secondary: "A")
        )
        XCTAssertEqual(
            DoubleMetaphone.encode("x"),
            DoubleMetaphone.Key(primary: "S", secondary: "S")
        )
        XCTAssertEqual(
            DoubleMetaphone.encode("aeiou"),
            DoubleMetaphone.Key(primary: "A", secondary: "A")
        )
    }

    func testKeysMatch_checksPrimarySecondaryCrossPairings() {
        let primaryOnlySide = DoubleMetaphone.Key(primary: "ABC", secondary: "DEF")
        let secondaryOnlySide = DoubleMetaphone.Key(primary: "XYZ", secondary: "ABC")
        XCTAssertTrue(DoubleMetaphone.keysMatch(primaryOnlySide, secondaryOnlySide))
        XCTAssertTrue(DoubleMetaphone.keysMatch(secondaryOnlySide, primaryOnlySide))
        XCTAssertFalse(
            DoubleMetaphone.keysMatch(
                primaryOnlySide,
                DoubleMetaphone.Key(primary: "UVW", secondary: "XYZ")
            )
        )
    }

    func testKeysMatch_neverMatchesEmptyKeys() {
        let empty = DoubleMetaphone.Key(primary: "", secondary: "")
        XCTAssertFalse(DoubleMetaphone.keysMatch(empty, empty))
        XCTAssertFalse(
            DoubleMetaphone.keysMatch(
                empty,
                DoubleMetaphone.Key(primary: "", secondary: "A")
            )
        )
    }

    func testTerminalReferenceKey() {
        XCTAssertEqual(
            DoubleMetaphone.encode("terminal"),
            DoubleMetaphone.Key(primary: "TRMNL", secondary: "TRMNL")
        )
    }
}
