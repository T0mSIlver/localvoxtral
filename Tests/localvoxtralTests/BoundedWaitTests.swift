import XCTest
@testable import localvoxtral

/// The bound that stops a test helper's wait from hanging the suite. Every
/// bound here is zero seconds, so no test in this file waits on the wall
/// clock.
@MainActor
final class BoundedWaitTests: XCTestCase {
    func testAResolutionBeforeTheWaitEndsItAtOnce() async {
        let wait = BoundedWait()
        wait.resolve()
        let resolved = await wait.value(failAfter: 600)
        XCTAssertTrue(resolved)
    }

    func testTheBoundEndsAWaitNothingResolvesAndALateResolutionIsIgnored() async {
        let wait = BoundedWait()
        let resolved = await wait.value(failAfter: 0)
        XCTAssertFalse(resolved)
        wait.resolve()
    }

    func testAWaitForATimerThatNeverArmsFailsAndLeavesTheClockUsable() async {
        let clock = ManualSessionClock()
        // Only the wait's own failure is expected; any other still fails.
        let onlyTheWait = XCTExpectedFailure.Options()
        onlyTheWait.issueMatcher = { $0.compactDescription.contains("were ever armed") }
        XCTExpectFailure("nothing arms a timer, so the wait must fail", options: onlyTheWait)
        await clock.waitForSleepers(1, failAfter: 0)

        let sleep = Task { await clock.sleep(.seconds(1)) }
        await clock.waitForSleepers(1)
        clock.advance(by: 1)
        await sleep.value
        XCTAssertEqual(clock.pendingSleepers, 0)
    }
}
