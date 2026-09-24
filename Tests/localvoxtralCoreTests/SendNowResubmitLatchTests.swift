import XCTest
@testable import localvoxtralCore

final class SendNowResubmitLatchTests: XCTestCase {
    func testDuplicateFinalCannotResubmit() {
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "run the focused test send now"))
        XCTAssertFalse(latch.claimSubmission(of: "run the focused test send now"))
        XCTAssertFalse(latch.claimSubmission(of: "Run the focused test, send now."))
    }

    func testLatchIsSetByTheClaimItself() {
        // The caller claims BEFORE inserting and pressing Return. If the Return
        // then fails, nothing else touches the latch, and a duplicate final
        // must still be refused rather than retrying the irreversible action.
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
        XCTAssertEqual(latch.lastSubmittedSegment, "send it")
        XCTAssertFalse(latch.claimSubmission(of: "send it"))
    }

    /// The accepted cost of a rule that cannot double-submit: the same
    /// submitting phrase twice in a row presses Return once. Partials cannot
    /// tell the user saying it again from a straggler of the first utterance
    /// (Codex review of #494).
    func testSamePhraseTwiceInARowSubmitsOnce() {
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
        XCTAssertFalse(latch.claimSubmission(of: "Send it."))
    }

    func testDifferentSegmentSubmits() {
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "fix it send it"))
        XCTAssertTrue(latch.claimSubmission(of: "now run it send it"))
    }

    func testNonSubmittingFinalClearsLatch() {
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
        latch.noteNonSubmittingFinal()
        XCTAssertNil(latch.lastSubmittedSegment)
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
    }

    func testReset() {
        var latch = SendNowResubmitLatch()
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
        latch.reset()
        XCTAssertEqual(latch, SendNowResubmitLatch())
        XCTAssertTrue(latch.claimSubmission(of: "send it"))
    }
}
