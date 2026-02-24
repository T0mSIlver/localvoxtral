import XCTest
@testable import localvoxtral

@MainActor
final class MlxHypothesisStabilizerTests: XCTestCase {

    func testPartialThenFinal_commitsStableTextAndCallsRealtimeInsertion() {
        let stabilizer = MlxHypothesisStabilizer()
        var realtimeInserted: [String] = []
        stabilizer.onRealtimeInsertion = { delta in
            realtimeInserted.append(delta)
        }

        let first = stabilizer.commitHypothesis(
            "hello wor",
            isFinal: false,
            insertionMode: .realtime
        )
        XCTAssertEqual(first.appendedDelta, "")
        XCTAssertEqual(first.unstableTail, "hello wor")
        XCTAssertEqual(stabilizer.committedEventText, "")

        let second = stabilizer.commitHypothesis(
            "hello world",
            isFinal: false,
            insertionMode: .realtime
        )
        XCTAssertEqual(second.appendedDelta, "hello ")
        XCTAssertEqual(second.unstableTail, "world")
        XCTAssertEqual(stabilizer.committedEventText, "hello ")

        let final = stabilizer.commitHypothesis(
            "hello world",
            isFinal: true,
            insertionMode: .realtime
        )
        XCTAssertEqual(final.appendedDelta, "world")
        XCTAssertEqual(final.unstableTail, "")
        XCTAssertEqual(stabilizer.committedEventText, "hello world")
        XCTAssertEqual(realtimeInserted, ["hello ", "world"])
    }

    func testFinalMismatch_doesNotAppendUnsafeDelta() {
        let stabilizer = MlxHypothesisStabilizer()
        var finalizedInserted: [String] = []
        stabilizer.onFinalizedInsertion = { delta in
            finalizedInserted.append(delta)
        }

        _ = stabilizer.commitHypothesis(
            "hello world",
            isFinal: false,
            insertionMode: .none
        )
        _ = stabilizer.commitHypothesis(
            "hello world now",
            isFinal: false,
            insertionMode: .none
        )
        XCTAssertEqual(stabilizer.committedEventText, "hello world")

        let mismatch = stabilizer.commitHypothesis(
            "hello there now",
            isFinal: true,
            insertionMode: .finalized
        )
        XCTAssertEqual(mismatch.appendedDelta, "")
        XCTAssertEqual(mismatch.unstableTail, "")
        XCTAssertEqual(stabilizer.committedEventText, "hello world")
        XCTAssertEqual(finalizedInserted, [])
    }

    func testPromotePendingText_returnsOnlyUninsertedTail() {
        let stabilizer = MlxHypothesisStabilizer()

        _ = stabilizer.commitHypothesis(
            "hello world",
            isFinal: false,
            insertionMode: .none
        )
        _ = stabilizer.commitHypothesis(
            "hello world there",
            isFinal: false,
            insertionMode: .none
        )

        let promoted = stabilizer.promotePendingText()
        XCTAssertEqual(promoted.allCommitted, "hello world there")
        XCTAssertEqual(promoted.newlyPromotedTail, "there")
        XCTAssertEqual(stabilizer.committedEventText, "hello world there")
    }
}
