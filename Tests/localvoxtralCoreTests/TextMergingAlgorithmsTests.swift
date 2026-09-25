import Foundation
import XCTest
@testable import localvoxtralCore

final class TextMergingAlgorithmsTests: XCTestCase {

    // MARK: - longestSuffixPrefixOverlap

    func testSuffixPrefixOverlap() {
        let cases: [(name: String, lhs: String, rhs: String, expected: Int)] = [
            ("emptyLhs", "", "hello", 0),
            ("emptyRhs", "hello", "", 0),
            ("noOverlap", "abc", "xyz", 0),
            ("partialOverlap", "hello wor", "world", 3),
            ("fullOverlap_equalStrings", "abc", "abc", 3),
            ("singleCharOverlap", "cat", "top", 1),
            ("unicode", "café", "é au lait", 1),
            // "abcabc" suffix "abc" and "abcabc" suffix "abcabc" — rhs prefix "abcx" only matches "abc"
            ("longestMatch", "xyzabc", "abcdef", 3),
        ]
        for (name, lhs, rhs, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: lhs, rhs: rhs), expected, name
            )
        }
    }

    // MARK: - appendToCurrentDictationEvent

    func testAppendEvent() {
        let cases: [(name: String, segment: String, existingText: String, expected: String)] = [
            ("whitespaceOnlySegment", "   \n  ", "hello", "hello"),
            ("emptyExisting", " world ", "", "world"),
            ("exactMatch", "hello", "hello", "hello"),
            ("segmentPrefixesExisting", "hello world", "hello", "hello world"),
            ("existingSuffixesSegment", "world", "hello world", "hello world"),
            ("suffixPrefixOverlap", "world today", "hello wor", "hello world today"),
            ("noOverlap_spaceJoin", "goodbye", "hello", "hello goodbye"),
            ("whitespaceNormalization", "  world  ", "  hello  ", "hello world"),
            ("oneLetterInsideAWordIsNotAnOverlap", "doing this", "I need", "I need doing this"),
            ("wholeWordOverlap", "the plan", "back to the", "back to the plan"),
        ]
        for (name, segment, existingText, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.appendToCurrentDictationEvent(segment: segment, existingText: existingText),
                expected,
                name
            )
        }
    }

    func testAppendEventRejoinsASegmentThatStartsMidWord() {
        let cases: [(name: String, segment: String, existingText: String, expected: String)] = [
            ("gluesOntoAWord", "e help me", "Pleas", "Please help me"),
            ("afterPunctuationKeepsTheSpace", "s", "information.", "information. s"),
        ]
        for (name, segment, existingText, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.appendToCurrentDictationEvent(
                    segment: segment, existingText: existingText, segmentStartsMidWord: true),
                expected,
                name
            )
        }
    }

    func testStartsMidWord() {
        XCTAssertTrue(TextMergingAlgorithms.startsMidWord("e help"))
        XCTAssertTrue(TextMergingAlgorithms.startsMidWord("ng"))
        XCTAssertFalse(TextMergingAlgorithms.startsMidWord(" help"))
        XCTAssertFalse(TextMergingAlgorithms.startsMidWord("Second"))
        XCTAssertFalse(TextMergingAlgorithms.startsMidWord("."))
        XCTAssertFalse(TextMergingAlgorithms.startsMidWord(""))
    }

    // MARK: - normalizeTranscriptionFormatting

    func testNormalizeFormatting() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("compactsTokenizerSpacingArtifacts", "l'  homme  est  ici  -  maintenant", "l'homme est ici-maintenant"),
            ("punctuationSpacing", "hello , world ! ( test ) [ value ]", "hello, world! (test) [value]"),
            ("preservesNewlines", "hello\t\tworld\nfoo    bar", "hello world\nfoo bar"),
            // Italian punctuation characterization (issue #13), see testTailOverlap.
            // Tokenizer spacing artifact "sparisce ." must collapse to "sparisce.".
            ("compactsSpaceBeforePeriod_italian", "sparisce .", "sparisce."),
            // "al , fondo" → "al, fondo" (no relocation of the comma into the word).
            ("compactsSpaceBeforeComma_italian", "al , fondo", "al, fondo"),
            // "l' acqua" → "l'acqua" (elision glues without splitting).
            ("apostropheElision_italian", "l' acqua", "l'acqua"),
            // A legitimately mid-word period (abbreviation/url) must be preserved
            // as-is — the normalizer never *inserts* punctuation into a word.
            ("preservesWordInternalPeriod_italian", "sparisce.al fondo", "sparisce.al fondo"),
        ]
        for (name, input, expected) in cases {
            XCTAssertEqual(TextMergingAlgorithms.normalizeTranscriptionFormatting(input), expected, name)
        }
    }

    // MARK: - longestCommonPrefixLength

    func testCommonPrefix() {
        let cases: [(name: String, lhs: String, rhs: String, expected: Int)] = [
            ("emptyStrings", "", "", 0),
            ("noCommon", "abc", "xyz", 0),
            ("partial", "hello world", "hello there", 6),
            ("fullMatch", "abc", "abc", 3),
            ("unicode", "café latte", "café mocha", 5),
        ]
        for (name, lhs, rhs, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.longestCommonPrefixLength(lhs: lhs, rhs: rhs), expected, name
            )
        }
    }

    // MARK: - stableWordBoundaryLength

    func testWordBoundary() {
        let cases: [(name: String, text: String, upTo: Int, expected: Int)] = [
            ("zeroLength", "hello world", 0, 0),
            // "hello world" at length 6 → char before is ' ' (boundary char), so returns 6
            ("atWordEdge", "hello world", 6, 6),
            // "hello world" at length 8 → mid "wor|ld", snaps back to 6 (after space)
            ("midWord_snapsBack", "hello world", 8, 6),
            ("atEndOfString", "hello", 5, 5),
            ("rawLengthExceedsText", "hi", 100, 2),
            ("negativeRawLength", "hello", -5, 0),
            // "hello.world" at length 6 → char at index 5 is '.', which is boundary
            ("punctuationAsBoundary", "hello.world", 6, 6),
            // Single long word, cut mid-word with no boundary → returns 0
            ("noWordBreakFound", "abcdefghij", 5, 0),
        ]
        for (name, text, upTo, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.stableWordBoundaryLength(in: text, upTo: upTo), expected, name
            )
        }
    }

    // MARK: - isWordBoundaryCharacter

    func testIsWordBoundary() {
        let cases: [(name: String, character: Character, expected: Bool)] = [
            ("space", " ", true),
            ("tab", "\t", true),
            ("period", ".", true),
            ("comma", ",", true),
            ("letter", "a", false),
            ("digit", "5", false),
        ]
        for (name, character, expected) in cases {
            XCTAssertEqual(TextMergingAlgorithms.isWordBoundaryCharacter(character), expected, name)
        }
    }

    // MARK: - shouldAvoidLeadingSpace

    func testAvoidLeadingSpace() {
        let cases: [(name: String, character: Character, expected: Bool)] = [
            ("period", ".", true),
            ("comma", ",", true),
            ("exclamation", "!", true),
            ("question", "?", true),
            ("closingParen", ")", true),
            ("closingBracket", "]", true),
            ("hyphen", "-", true),
            ("letter", "a", false),
            // Apostrophe glues (no leading space) so elisions like "l'acqua" form.
            ("apostrophe", "'", true),
        ]
        for (name, character, expected) in cases {
            XCTAssertEqual(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: character), expected, name)
        }
    }

    // MARK: - appendWithTailOverlap

    func testTailOverlap() {
        let cases: [(name: String, existing: String, incoming: String, merged: String, delta: String)] = [
            ("emptyIncoming", "hello", "", "hello", ""),
            ("emptyExisting", "", "hello", "hello", "hello"),
            ("existingSuffixesIncoming", "hello world", "world", "hello world", ""),
            ("overlapPresent", "hello wor", "world", "hello world", "ld"),
            ("noOverlap_spaceInserted", "hello", "world", "hello world", " world"),
            ("noOverlap_avoidLeadingSpace", "hello", ".", "hello.", "."),
            ("noOverlap_hyphenNoSpace", "Est", "-ce", "Est-ce", "-ce"),
            ("noOverlap_existingEndsWithWhitespace", "hello ", "world", "hello world", "world"),

            // Italian punctuation characterization (issue #13).
            //
            // These cases exercise the exact transformations that would be required to
            // turn a well-formed stream into the reported malformed output
            // ("sparis.ce", "al, fondo"). They assert the merge helpers produce the
            // *correct* result, proving the malformed output does not originate in
            // TextMergingAlgorithms when deltas are delivered in left-to-right order.

            // "sparisce" + "." must produce "sparisce." — never "sparis.ce".
            ("periodGluesToWordEnd_italian", "sparisce", ".", "sparisce.", "."),
            // "al fondo" + "," must produce "al fondo," — the comma never jumps
            // before "fondo".
            ("commaGluesToWordEnd_italian", "al fondo", ",", "al fondo,", ","),
            // "al" + "fondo," must produce "al fondo,".
            ("wordThenSpaceWord_gluesWithSpace_italian", "al", "fondo,", "al fondo,", " fondo,"),
            // "l" + "'acqua" must produce "l'acqua" (no leading space before ').
            ("apostropheGluesToWord_italian", "l", "'acqua", "l'acqua", "'acqua"),
            // "un" + "'altra" must produce "un'altra".
            ("apostropheGluesAfterArticle_italian", "un", "'altra", "un'altra", "'altra"),
            // Overlap merge when the incoming segment replays the prefix and grows:
            // "spari" + "sparisce." → "sparisce." (the boundary stays at the end).
            ("replayedGrowingWord_keepsOnlySuffix_italian", "spari", "sparisce.", "sparisce.", "sce."),
            // #516: one letter shared inside a word is not an alignment.
            ("oneLetterInsideAWordIsNotAnOverlap", "I need", "doing", "I need doing", " doing"),
        ]
        for (name, existing, incoming, merged, delta) in cases {
            let result = TextMergingAlgorithms.appendWithTailOverlap(existing: existing, incoming: incoming)
            XCTAssertEqual(result.merged, merged, "\(name): merged")
            XCTAssertEqual(result.appendedDelta, delta, "\(name): appendedDelta")
        }
    }

    func testTailOverlap_incomingThatStartsMidWordGluesOntoTheLastWord() {
        let glued = TextMergingAlgorithms.appendWithTailOverlap(
            existing: "Pleas", incoming: "e help", incomingStartsMidWord: true)
        XCTAssertEqual(glued.merged, "Please help")
        XCTAssertEqual(glued.appendedDelta, "e help")

        let afterPunctuation = TextMergingAlgorithms.appendWithTailOverlap(
            existing: "information.", incoming: "s", incomingStartsMidWord: true)
        XCTAssertEqual(afterPunctuation.merged, "information. s")
    }

    func testTailOverlap_wordReplayWithFormattingArtifacts_keepsOnlySuffix() {
        let existing = "Alors j'espere que maintenant ca va etre encore mieux qu'avant et je recois un texte propre"
        let incoming = "Alors j' espere que maintenant ca va etre encore mieux qu'avant et je recois un texte propre apres"
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: existing, incoming: incoming)
        XCTAssertEqual(result.merged, existing + " apres")
        XCTAssertEqual(result.appendedDelta, " apres")
    }

    func testTailOverlap_wordReplayFullyContained_dropsIncoming() {
        let existing = "je vais simplement devoir attendre d'avoir tout recu"
        let incoming = "je vais simplement devoir attendre d' avoir tout recu"
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: existing, incoming: incoming)
        XCTAssertEqual(result.merged, existing)
        XCTAssertEqual(result.appendedDelta, "")
    }

    // MARK: - livePasteExtensionSuffix

    func testLivePasteExtensionSuffix() {
        let cases: [(name: String, finalText: String, liveInsertedText: String, expected: String?)] = [
            // "sparisce" typed live, final "sparisce." is a pure extension → ".".
            ("trailingPeriod", "sparisce.", "sparisce", "."),
            // A multi-char trailing addition is returned verbatim.
            ("multiCharSuffix", "you are right, right?", "you are right", ", right?"),
            // Final equals the live text: empty suffix → no-op.
            ("identicalReturnsNil", "sparisce", "sparisce", nil),
            // The final revises earlier content (not a pure extension) → nil.
            ("revisionReturnsNil", "sparisci.", "sparisce", nil),
            // The final is a prefix of the live text (contraction) → not a pure
            // extension → nil.
            ("finalShorterThanLiveReturnsNil", "spari", "sparisce", nil),
            // No live text typed yet: the caller takes the whole-segment path, so a
            // suffix must not be synthesized here.
            ("emptyLiveReturnsNil", "sparisce.", "", nil),
            // Final carries only the punctuation (disjoint from the live word) →
            // not a pure extension → nil (the whole-segment boundary join is a
            // separate concern handled by resolvedFinalizedSegment).
            ("disjointReturnsNil", ".", "sparisce", nil),
            // The finalized-transcript path trims trailing whitespace; the typed
            // suffix must match, or the field diverges from the transcript.
            ("trailingWhitespaceInFinalIsNotTyped_space", "sparisce. ", "sparisce", "."),
            ("trailingWhitespaceInFinalIsNotTyped_newline", "sparisce.\n", "sparisce", "."),
            ("whitespaceOnlyExtensionReturnsNil", "sparisce ", "sparisce", nil),
        ]
        for (name, finalText, liveInsertedText, expected) in cases {
            XCTAssertEqual(
                TextMergingAlgorithms.livePasteExtensionSuffix(
                    finalText: finalText,
                    liveInsertedText: liveInsertedText
                ),
                expected,
                name
            )
        }
    }
}
