import XCTest
@testable import localvoxtralCore

/// The batch text keeps a run of realtime words it dropped outright (#1649),
/// and wins everywhere else.
final class StopSecondPassRealtimeRunsTests: XCTestCase {
    private func reconciled(_ realtime: String, _ secondPass: String) -> StopSecondPass.Reconciled {
        StopSecondPass.keepingDroppedRealtimeRuns(realtime: realtime, secondPass: secondPass)
    }

    func testASentenceTheBatchTextDroppedGoesBackWhereItWas() {
        let result = reconciled(
            "Close the old issues tonight. Then archive every session because the cache goes cold. Start fresh tomorrow.",
            "Close the old issues tonight. Start fresh tomorrow."
        )
        XCTAssertEqual(
            result.text,
            "Close the old issues tonight. Then archive every session because the cache goes cold. Start fresh tomorrow."
        )
        XCTAssertEqual(result.restoredWords, 9)
    }

    func testARunDroppedAtEitherEdgeGoesBack() {
        XCTAssertEqual(
            reconciled("Ship it today. Then tell the whole team.", "Ship it today.").text,
            "Ship it today. Then tell the whole team."
        )
        XCTAssertEqual(
            reconciled("Before anything else today, rebase the branch now.", "Rebase the branch now.").text,
            "Before anything else today, Rebase the branch now."
        )
    }

    func testARestartTheBatchTextCleanedUpStaysDropped() {
        let batch = "It should still look good on two lines."
        let result = reconciled("it should still look good on the on two on two lines", batch)
        XCTAssertEqual(result.text, batch)
        XCTAssertEqual(result.restoredWords, 0)
    }

    func testARunShorterThanTheMinimumStaysDropped() {
        let batch = "Open the settings pane."
        XCTAssertEqual(reconciled("Open the settings pane, you know what.", batch).text, batch)
    }

    func testARewordingKeepsTheBatchText() {
        let batch = "Why is localvoxtral codesign identity not picked up?"
        XCTAssertEqual(
            reconciled("why is local vogue's codesign identity not picked up", batch).text, batch)
    }

    func testWordsOnlyTheBatchTextHasStay() {
        let batch = "The limits reset in an hour and twenty minutes, so wait until then."
        XCTAssertEqual(
            reconciled("The limits reset in an hour so wait until then.", batch).text, batch)
    }
}
