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

final class SendNowPlanTests: XCTestCase {
    func testStepsTable() {
        let cases: [(action: SendNowCommandAction, pid: Int32?, expected: [SendNowStep], line: UInt)] = [
            (.none, 123, [], #line),
            (.insertText("hi"), 123, [.insert("hi", pid: 123)], #line),
            (.insertText("hi"), nil, [.insert("hi", pid: nil)], #line),
            (.pressReturn, 123, [.pressReturn(pid: 123)], #line),
            (.insertTextAndPressReturn("hi"), 123,
             [.insert("hi", pid: 123), .pressReturn(pid: 123)], #line),
            // No pinned PID: never a Return that could land in whatever app
            // has focus.
            (.pressReturn, nil, [], #line),
            (.insertTextAndPressReturn("hi"), nil, [.insert("hi", pid: nil)], #line),
        ]
        for testCase in cases {
            XCTAssertEqual(
                SendNowPlan.steps(for: testCase.action, targetPID: testCase.pid),
                testCase.expected,
                line: testCase.line
            )
        }
    }

    func testEveryStepCarriesTheSamePID() {
        let steps = SendNowPlan.steps(
            for: .insertTextAndPressReturn("run the tests"),
            targetPID: 4242
        )
        let pids: [Int32?] = steps.map {
            switch $0 {
            case .insert(_, let pid): pid
            case .pressReturn(let pid): pid
            }
        }
        XCTAssertEqual(pids, [4242, 4242])
    }
}
