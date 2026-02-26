import Foundation
import XCTest
@testable import localvoxtral

final class TextMergingAlgorithmsTests: XCTestCase {

    // MARK: - longestSuffixPrefixOverlap

    func testSuffixPrefixOverlap_emptyLhs() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "", rhs: "hello"), 0)
    }

    func testSuffixPrefixOverlap_emptyRhs() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "hello", rhs: ""), 0)
    }

    func testSuffixPrefixOverlap_noOverlap() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "abc", rhs: "xyz"), 0)
    }

    func testSuffixPrefixOverlap_partialOverlap() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "hello wor", rhs: "world"), 3)
    }

    func testSuffixPrefixOverlap_fullOverlap_equalStrings() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "abc", rhs: "abc"), 3)
    }

    func testSuffixPrefixOverlap_singleCharOverlap() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "cat", rhs: "top"), 1)
    }

    func testSuffixPrefixOverlap_unicode() {
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "café", rhs: "é au lait"), 1)
    }

    func testSuffixPrefixOverlap_longestMatch() {
        // "abcabc" suffix "abc" and "abcabc" suffix "abcabc" — rhs prefix "abcx" only matches "abc"
        XCTAssertEqual(TextMergingAlgorithms.longestSuffixPrefixOverlap(lhs: "xyzabc", rhs: "abcdef"), 3)
    }

    // MARK: - mergeIncrementalText

    func testMergeIncremental_emptyIncoming() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello", incoming: "")
        XCTAssertEqual(result.merged, "hello")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testMergeIncremental_emptyExisting() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "", incoming: "hello")
        XCTAssertEqual(result.merged, "hello")
        XCTAssertEqual(result.appendedDelta, "hello")
    }

    func testMergeIncremental_exactMatch() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello", incoming: "hello")
        XCTAssertEqual(result.merged, "hello")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testMergeIncremental_incomingPrefixedByExisting() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello", incoming: "hello world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, " world")
    }

    func testMergeIncremental_existingSuffixesIncoming() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello world", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testMergeIncremental_existingContainsIncoming() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello world", incoming: "lo wor")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testMergeIncremental_suffixPrefixOverlap() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "hello wor", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "ld")
    }

    func testMergeIncremental_noOverlap() {
        let result = TextMergingAlgorithms.mergeIncrementalText(existing: "abc", incoming: "xyz")
        XCTAssertEqual(result.merged, "abcxyz")
        XCTAssertEqual(result.appendedDelta, "xyz")
    }

    // MARK: - appendToCurrentDictationEvent

    func testAppendEvent_whitespaceOnlySegment() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "   \n  ", existingText: "hello")
        XCTAssertEqual(result, "hello")
    }

    func testAppendEvent_emptyExisting() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: " world ", existingText: "")
        XCTAssertEqual(result, "world")
    }

    func testAppendEvent_exactMatch() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "hello", existingText: "hello")
        XCTAssertEqual(result, "hello")
    }

    func testAppendEvent_segmentPrefixesExisting() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "hello world", existingText: "hello")
        XCTAssertEqual(result, "hello world")
    }

    func testAppendEvent_existingSuffixesSegment() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "world", existingText: "hello world")
        XCTAssertEqual(result, "hello world")
    }

    func testAppendEvent_suffixPrefixOverlap() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "world today", existingText: "hello wor")
        XCTAssertEqual(result, "hello world today")
    }

    func testAppendEvent_noOverlap_newlineJoin() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "goodbye", existingText: "hello")
        XCTAssertEqual(result, "hello\ngoodbye")
    }

    func testAppendEvent_whitespaceNormalization() {
        let result = TextMergingAlgorithms.appendToCurrentDictationEvent(segment: "  world  ", existingText: "  hello  ")
        XCTAssertEqual(result, "hello\nworld")
    }

    // MARK: - normalizeTranscriptionFormatting

    func testNormalizeFormatting_compactsTokenizerSpacingArtifacts() {
        let input = "l'  homme  est  ici  -  maintenant"
        let normalized = TextMergingAlgorithms.normalizeTranscriptionFormatting(input)
        XCTAssertEqual(normalized, "l'homme est ici-maintenant")
    }

    func testNormalizeFormatting_punctuationSpacing() {
        let input = "hello , world ! ( test ) [ value ]"
        let normalized = TextMergingAlgorithms.normalizeTranscriptionFormatting(input)
        XCTAssertEqual(normalized, "hello, world! (test) [value]")
    }

    func testNormalizeFormatting_preservesNewlines() {
        let input = "hello\t\tworld\nfoo    bar"
        let normalized = TextMergingAlgorithms.normalizeTranscriptionFormatting(input)
        XCTAssertEqual(normalized, "hello world\nfoo bar")
    }

    // MARK: - longestCommonPrefixLength

    func testCommonPrefix_emptyStrings() {
        XCTAssertEqual(TextMergingAlgorithms.longestCommonPrefixLength(lhs: "", rhs: ""), 0)
    }

    func testCommonPrefix_noCommon() {
        XCTAssertEqual(TextMergingAlgorithms.longestCommonPrefixLength(lhs: "abc", rhs: "xyz"), 0)
    }

    func testCommonPrefix_partial() {
        XCTAssertEqual(TextMergingAlgorithms.longestCommonPrefixLength(lhs: "hello world", rhs: "hello there"), 6)
    }

    func testCommonPrefix_fullMatch() {
        XCTAssertEqual(TextMergingAlgorithms.longestCommonPrefixLength(lhs: "abc", rhs: "abc"), 3)
    }

    func testCommonPrefix_unicode() {
        XCTAssertEqual(TextMergingAlgorithms.longestCommonPrefixLength(lhs: "café latte", rhs: "café mocha"), 5)
    }

    // MARK: - stableWordBoundaryLength

    func testWordBoundary_zeroLength() {
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello world", upTo: 0), 0)
    }

    func testWordBoundary_atWordEdge() {
        // "hello world" at length 6 → char before is ' ' (boundary char), so returns 6
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello world", upTo: 6), 6)
    }

    func testWordBoundary_midWord_snapsBack() {
        // "hello world" at length 8 → mid "wor|ld", snaps back to 6 (after space)
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello world", upTo: 8), 6)
    }

    func testWordBoundary_atEndOfString() {
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello", upTo: 5), 5)
    }

    func testWordBoundary_rawLengthExceedsText() {
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hi", upTo: 100), 2)
    }

    func testWordBoundary_negativeRawLength() {
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello", upTo: -5), 0)
    }

    func testWordBoundary_punctuationAsBoundary() {
        // "hello.world" at length 6 → char at index 5 is '.', which is boundary
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "hello.world", upTo: 6), 6)
    }

    func testWordBoundary_noWordBreakFound() {
        // Single long word, cut mid-word with no boundary → returns 0
        XCTAssertEqual(TextMergingAlgorithms.stableWordBoundaryLength(in: "abcdefghij", upTo: 5), 0)
    }

    // MARK: - isWordBoundaryCharacter

    func testIsWordBoundary_space() {
        XCTAssertTrue(TextMergingAlgorithms.isWordBoundaryCharacter(" "))
    }

    func testIsWordBoundary_tab() {
        XCTAssertTrue(TextMergingAlgorithms.isWordBoundaryCharacter("\t"))
    }

    func testIsWordBoundary_period() {
        XCTAssertTrue(TextMergingAlgorithms.isWordBoundaryCharacter("."))
    }

    func testIsWordBoundary_comma() {
        XCTAssertTrue(TextMergingAlgorithms.isWordBoundaryCharacter(","))
    }

    func testIsWordBoundary_letter() {
        XCTAssertFalse(TextMergingAlgorithms.isWordBoundaryCharacter("a"))
    }

    func testIsWordBoundary_digit() {
        XCTAssertFalse(TextMergingAlgorithms.isWordBoundaryCharacter("5"))
    }

    // MARK: - shouldAvoidLeadingSpace

    func testAvoidLeadingSpace_period() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "."))
    }

    func testAvoidLeadingSpace_comma() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: ","))
    }

    func testAvoidLeadingSpace_exclamation() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "!"))
    }

    func testAvoidLeadingSpace_question() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "?"))
    }

    func testAvoidLeadingSpace_closingParen() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: ")"))
    }

    func testAvoidLeadingSpace_closingBracket() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "]"))
    }

    func testAvoidLeadingSpace_hyphen() {
        XCTAssertTrue(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "-"))
    }

    func testAvoidLeadingSpace_letter() {
        XCTAssertFalse(TextMergingAlgorithms.shouldAvoidLeadingSpace(before: "a"))
    }

    // MARK: - appendWithTailOverlap

    func testTailOverlap_emptyIncoming() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello", incoming: "")
        XCTAssertEqual(result.merged, "hello")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testTailOverlap_emptyExisting() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "", incoming: "hello")
        XCTAssertEqual(result.merged, "hello")
        XCTAssertEqual(result.appendedDelta, "hello")
    }

    func testTailOverlap_existingSuffixesIncoming() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello world", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "")
    }

    func testTailOverlap_overlapPresent() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello wor", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "ld")
    }

    func testTailOverlap_noOverlap_spaceInserted() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, " world")
    }

    func testTailOverlap_noOverlap_avoidLeadingSpace() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello", incoming: ".")
        XCTAssertEqual(result.merged, "hello.")
        XCTAssertEqual(result.appendedDelta, ".")
    }

    func testTailOverlap_noOverlap_hyphenNoSpace() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "Est", incoming: "-ce")
        XCTAssertEqual(result.merged, "Est-ce")
        XCTAssertEqual(result.appendedDelta, "-ce")
    }

    func testTailOverlap_noOverlap_existingEndsWithWhitespace() {
        let result = TextMergingAlgorithms.appendWithTailOverlap(existing: "hello ", incoming: "world")
        XCTAssertEqual(result.merged, "hello world")
        XCTAssertEqual(result.appendedDelta, "world")
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
}
