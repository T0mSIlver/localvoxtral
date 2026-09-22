import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// A `SessionClock` a test advances by hand. A sleep returns when `advance`
/// moves `now` to its deadline, or at once when the sleeping task is
/// cancelled, as `try? Task.sleep` does. Nothing here reads the wall clock.
///
/// A woken task runs when the test next suspends, so a test waits for what
/// it woke: the task's own `value`, or the next timer it arms
/// (`waitForSleepers`).
final class ManualSessionClock: Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// A cancellation that landed before its sleep registered. One that
        /// lands after `advance` already resumed the sleep also stays here;
        /// ids are never reused, so it can match nothing later.
        var cancelledBeforeSuspending: Set<UInt64> = []
        var countWaiters: [CountWaiter] = []

        mutating func takeSatisfiedCountWaiters() -> [CheckedContinuation<Void, Never>] {
            let satisfied = countWaiters.filter { $0.count <= sleepers.count }
            countWaiters.removeAll { $0.count <= sleepers.count }
            return satisfied.map(\.continuation)
        }
    }

    private let state: Mutex<State>

    init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        state = Mutex(State(now: now))
    }

    var clock: SessionClock {
        SessionClock(
            sleep: { [self] duration in await self.sleep(duration) },
            now: { [self] in self.now }
        )
    }

    var now: Date { state.withLock { $0.now } }

    /// Sleeps in progress: timers armed and not yet due.
    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(_ duration: Duration) async {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (cancelled, satisfied) = self.state.withLock { state in
                    if state.cancelledBeforeSuspending.remove(id) != nil {
                        return (true, [CheckedContinuation<Void, Never>]())
                    }
                    state.sleepers.append(Sleeper(
                        id: id,
                        deadline: state.now.addingTimeInterval(seconds),
                        continuation: continuation
                    ))
                    return (false, state.takeSatisfiedCountWaiters())
                }
                if cancelled { continuation.resume() }
                satisfied.forEach { $0.resume() }
            }
        } onCancel: {
            let continuation = self.state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index).continuation
                }
                state.cancelledBeforeSuspending.insert(id)
                return nil
            }
            continuation?.resume()
        }
    }

    /// Moves `now` forward and wakes every sleeper whose deadline has come,
    /// earliest first. A deadline within a nanosecond counts as reached, so a
    /// test that gets there in two steps is not left a rounding error short.
    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.now = state.now.addingTimeInterval(seconds)
            let reached = state.now.addingTimeInterval(1e-9)
            let due = state.sleepers.filter { $0.deadline <= reached }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= reached }
            return due.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Returns once at least `count` timers are armed: how a test knows the
    /// task it woke has reached its next sleep. Only wait for a timer the
    /// code under test is certain to arm. If it never arms one, the test
    /// fails after `failAfter` seconds of wall time instead of hanging the
    /// suite: a bound on a failure, never a wait a passing test relies on.
    func waitForSleepers(
        _ count: Int,
        failAfter: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let armed = XCTestExpectation(description: "\(count) timer(s) armed on the session clock")
        let waiting = Task {
            await self.untilSleepers(count)
            armed.fulfill()
        }
        let result = await XCTWaiter().fulfillment(of: [armed], timeout: failAfter)
        if result != .completed {
            waiting.cancel()
            XCTFail(
                "no \(count) timer(s) were ever armed on the session clock",
                file: file,
                line: line
            )
        }
    }

    private func untilSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = self.state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.countWaiters.append(CountWaiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
