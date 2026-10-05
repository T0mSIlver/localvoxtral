import XCTest
@testable import localvoxtralCore

final class TranscriptDiffTests: XCTestCase {
    private func words(_ ranges: [Range<String.Index>], in text: String) -> [String] {
        ranges.map { String(text[$0]) }
    }

    func testIdenticalTextsHaveNoDifference() {
        XCTAssertTrue(TranscriptDiff.words(from: "same words here", to: "same words here").isEmpty)
        XCTAssertTrue(TranscriptDiff.words(from: "", to: "").isEmpty)
    }

    func testAReplacedWordIsRemovedOnOneSideAndAddedOnTheOther() {
        let before = "restart the quen server now"
        let after = "restart the Qwen server now"
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["quen"])
        XCTAssertEqual(words(diff.added, in: after), ["Qwen"])
    }

    func testDroppedFillersAndAddedPunctuationAreEachMarkedOnTheirOwnSide() {
        let before = "um so we should uh ship it today"
        let after = "So we should ship it today."
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["um", "so", "uh", "today"])
        XCTAssertEqual(words(diff.added, in: after), ["So", "today."])
    }

    func testRangesPointIntoTheOriginalStringsAcrossLineBreaks() {
        let before = "first line\nsecond lin"
        let after = "first line\n\nsecond line"
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["lin"])
        XCTAssertEqual(words(diff.added, in: after), ["line"])
    }

    func testEverythingAddedOrEverythingRemoved() {
        let text = "brand new text"
        XCTAssertEqual(words(TranscriptDiff.words(from: "", to: text).added, in: text).count, 3)
        XCTAssertEqual(words(TranscriptDiff.words(from: text, to: "").removed, in: text).count, 3)
    }

    func testARewriteLargerThanTheTableMarksTheWholeMiddleAndKeepsTheSharedEnds() {
        let middleBefore = (0...TranscriptDiff.maxComparedWords).map { "b\($0)" }
        let middleAfter = (0...TranscriptDiff.maxComparedWords).map { "a\($0)" }
        let before = (["start"] + middleBefore + ["end"]).joined(separator: " ")
        let after = (["start"] + middleAfter + ["end"]).joined(separator: " ")

        let diff = TranscriptDiff.words(from: before, to: after)

        XCTAssertEqual(words(diff.removed, in: before), middleBefore)
        XCTAssertEqual(words(diff.added, in: after), middleAfter)
    }
}

final class TranscriptDiffHunkTests: XCTestCase {
    func testHunksPairWhatWasRemovedWithWhatReplacedItInReadingOrder() {
        let before = "um restart the quen server uh now"
        let after = "Restart the Qwen server now"

        let hunks = TranscriptDiff.hunks(from: before, to: after).map { hunk in
            (hunk.removed.map { String(before[$0]) }, hunk.added.map { String(after[$0]) })
        }

        XCTAssertEqual(hunks.map(\.0), [["um", "restart"], ["quen"], ["uh"]])
        XCTAssertEqual(hunks.map(\.1), [["Restart"], ["Qwen"], []])
    }
}
