import Foundation
import Synchronization
import XCTest

/// Counts something the code under test does, and lets a test wait until it
/// has happened `count` times: how a test waits on the writer itself instead
/// of yielding a fixed number of times and hoping it ran (#1522).
///
/// Only wait for a count the code under test is certain to reach. If it never
/// does, the wait fails after `failAfter` seconds of wall time instead of
/// hanging the suite: a bound on a failure, never a wait a passing test
/// relies on.
package final class EventCount: Sendable {
    private struct Waiter {
        let count: Int
        let wait: BoundedWait
    }

    private struct State {
        var value = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    package init() {}

    package var value: Int { state.withLock { $0.value } }

    package func increment() {
        let reached = state.withLock { state -> [BoundedWait] in
            state.value += 1
            let value = state.value
            let reached = state.waiters.filter { $0.count <= value }.map(\.wait)
            state.waiters.removeAll { $0.count <= value }
            return reached
        }
        reached.forEach { $0.resolve() }
    }

    package func waitFor(
        _ count: Int,
        failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let wait = BoundedWait()
        let ready = state.withLock { state -> Bool in
            if state.value >= count { return true }
            state.waiters.append(Waiter(count: count, wait: wait))
            return false
        }
        if ready { return }
        if await wait.value(failAfter: failAfter) { return }
        let value = state.withLock { state -> Int in
            state.waiters.removeAll { $0.wait === wait }
            return state.value
        }
        XCTFail("waited for \(count) event(s), saw \(value)", file: file, line: line)
    }
}
