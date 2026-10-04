import Synchronization
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

/// The bound that stops a test helper's wait from hanging the suite. Every
/// bound here is zero seconds, so no test in this file waits on the wall
/// clock.
///
/// `ManualSessionClock.waitForSleepers`' failure branch (nothing ever arms
/// the timer) is asserted through the clock's injectable failure reporter
/// rather than an expected XCTest issue: the first issue a test process
/// records takes a symbolicated call stack, which cost 5.3 s per run. Every
/// consumer suite keeps the `XCTFail` default.
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

    /// A wait nothing satisfies must FAIL the test — recording "no N timer(s)
    /// were ever armed on the session clock" — instead of returning quietly,
    /// or every consumer suite that waits for a timer would pass silently
    /// when its timer never arms. The clock must also stay usable afterwards.
    /// The failure is captured through the clock's failure reporter, not
    /// expected as an issue: an expected failure pays seconds of XCTest issue
    /// symbolication per run.
    func testAWaitForATimerThatNeverArmsFailsAndLeavesTheClockUsable() async {
        let clock = ManualSessionClock()
        let failures = Mutex<[(message: String, file: String, line: UInt)]>([])
        clock.setWaitForSleepersFailureReporter { message, file, line in
            failures.withLock { $0.append((message: message, file: file.description, line: line)) }
        }

        let thisFile = #filePath
        let waitLine: UInt = #line
        await clock.waitForSleepers(1, failAfter: 0)

        let reported = failures.withLock { $0 }
        XCTAssertEqual(reported.count, 1, "the failed wait reports exactly one failure")
        XCTAssertEqual(
            reported[0].message,
            "no 1 timer(s) were ever armed on the session clock",
            "a wait nothing satisfies fails the test rather than returning quietly"
        )
        XCTAssertEqual(reported[0].file, thisFile.description, "the failure points at the waiting test file")
        XCTAssertEqual(reported[0].line, waitLine + 1, "the failure points at the waiting call")

        // The clock stays usable: the failed wait's cleanup leaves it able to
        // arm, advance and drain a sleeper. The default reporter is back, so
        // this wait failing would fail the test.
        clock.setWaitForSleepersFailureReporter()
        let sleeper = Task { await clock.sleep(.seconds(1)) }
        await clock.waitForSleepers(1)
        clock.advance(by: 1)
        await sleeper.value
        XCTAssertEqual(clock.pendingSleepers, 0, "the sleeper was drained, not left armed")
        XCTAssertEqual(
            clock.now, Date(timeIntervalSinceReferenceDate: 1),
            "advance still moves the clock after a failed wait"
        )
    }
}
