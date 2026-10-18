import Foundation
import Synchronization
import XCTest
import localvoxtralTestSupport

@MainActor
final class ManualSessionClockTests: XCTestCase {
    /// The spoken-stop race (#1863): another timer meets a count of one
    /// first, but a wait for the timer due in 3 s returns only once that one
    /// is armed.
    func testAWaitForADeadlineIgnoresTimersDueAtOtherTimes() async {
        let clock = ManualSessionClock()
        let returned = Mutex(false)
        let waiter = Task { @MainActor in
            await clock.waitForSleeper(dueIn: 3)
            returned.withLock { $0 = true }
        }
        await Task.yield()

        let other = Task { await clock.sleep(.seconds(10)) }
        await clock.waitForSleepers(1)
        await Task.yield()
        await Task.yield()
        let returnedEarly = returned.withLock { $0 }

        let stop = Task { await clock.sleep(.seconds(3)) }
        await waiter.value
        XCTAssertTrue(returned.withLock { $0 })

        // Cancelled, not advanced past: a cancelled sleep ends whether or
        // not it registered yet.
        stop.cancel()
        other.cancel()
        await stop.value
        await other.value
        XCTAssertFalse(returnedEarly, "returned on the 10 s timer")
    }
}
