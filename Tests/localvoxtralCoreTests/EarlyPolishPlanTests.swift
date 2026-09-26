import XCTest
@testable import localvoxtralCore

final class EarlyPolishPlanTests: XCTestCase {
    private func words(_ count: Int, from start: Int = 0) -> String {
        (start..<start + count).map { "w\($0)" }.joined(separator: " ")
    }

    func testAPieceIsWholeSentencesUntilTheyReachTheMinimum() throws {
        let first = words(20) + "."
        let second = words(15, from: 20) + "."
        let open = words(5, from: 35)
        let settled = "\(first) \(second) \(open)"

        let next = try XCTUnwrap(EarlyPolishPlan.nextPiece(settledText: settled, consumedPrefix: ""))

        XCTAssertEqual(next.piece, "\(first) \(second)")
        XCTAssertEqual(next.consumedPrefix, "\(first) \(second)")
        XCTAssertNil(EarlyPolishPlan.nextPiece(settledText: settled, consumedPrefix: next.consumedPrefix))
    }

    func testNoPieceUntilASentenceEndsPastTheMinimum() {
        XCTAssertNil(EarlyPolishPlan.nextPiece(settledText: words(40), consumedPrefix: ""))
        XCTAssertNil(EarlyPolishPlan.nextPiece(settledText: words(10) + ".", consumedPrefix: ""))
    }

    func testTheNextPieceStartsAfterTheConsumedPrefix() throws {
        let first = words(30) + "."
        let second = words(30, from: 30) + "?"
        let next = try XCTUnwrap(EarlyPolishPlan.nextPiece(
            settledText: "\(first) \(second) tail", consumedPrefix: first))

        XCTAssertEqual(next.piece, second)
        XCTAssertEqual(next.consumedPrefix, "\(first) \(second)")
    }

    func testSettledTextThatNoLongerStartsWithThePiecesGivesNoPiece() {
        XCTAssertNil(EarlyPolishPlan.nextPiece(
            settledText: words(40) + ".", consumedPrefix: "something else."))
    }

    // The study's first cut split a spoken numbered list after "1." and a URL
    // after "HTTPS 2.", and a piece must not end inside "e.g." or "v1.2.".
    func testAPeriodAfterANumberALetterOrInsideADottedTokenEndsNoSentence() {
        let lead = words(30)
        for ending in ["step 1. next", "HTTPS 2. //api", "option b. then", "e.g. this", "v1.2. more"] {
            XCTAssertNil(
                EarlyPolishPlan.nextPiece(settledText: "\(lead) \(ending)", consumedPrefix: ""),
                ending
            )
        }
        XCTAssertNotNil(EarlyPolishPlan.nextPiece(settledText: "\(lead) done. next", consumedPrefix: ""))
        XCTAssertNotNil(EarlyPolishPlan.nextPiece(settledText: "\(lead) vraiment ! ensuite", consumedPrefix: ""))
    }

    func testAPeriodGluedToTheNextCharacterEndsNoSentence() {
        XCTAssertNil(EarlyPolishPlan.nextPiece(settledText: words(30) + " file.swift is open", consumedPrefix: ""))
    }

    func testTheTailIsWhatFollowsThePieces() {
        XCTAssertEqual(
            EarlyPolishPlan.tail(workingText: "One two. Three four", consumedPrefix: "One two."),
            "Three four"
        )
        XCTAssertEqual(EarlyPolishPlan.tail(workingText: "One two.", consumedPrefix: "One two."), "")
    }

    func testNoTailWhenTheStopTextChangedThePieces() {
        XCTAssertNil(EarlyPolishPlan.tail(workingText: "One too. Three", consumedPrefix: "One two."))
        XCTAssertNil(EarlyPolishPlan.tail(workingText: "One two.5 more", consumedPrefix: "One two."))
        XCTAssertNil(EarlyPolishPlan.tail(workingText: "anything", consumedPrefix: ""))
    }

    func testPartsJoinWithOneSpaceAndSkipBlanks() {
        XCTAssertEqual(EarlyPolishPlan.joined(["A b.", " C d. ", "", "E"]), "A b. C d. E")
    }
}
