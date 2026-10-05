import Foundation
import Synchronization
import localvoxtralCore

// The edit-signal doubles `EditSignalTests`, `DiagnosticRecordWiringTests` and
// `AddressedSendWiringTests` share.

/// A key source the watcher can be driven from without an event stream, an
/// Accessibility grant, or the host's keyboard.
///
/// `stop()` deliberately KEEPS the handler: the watcher's own generation/result
/// guard is what must reject a late signal, and a double that forgot the handler
/// would pass those tests without the guard existing.
@MainActor
package final class EditSignalTestMonitor: EditKeyMonitoring {
    package init() {}

    package private(set) var startCount = 0
    package private(set) var stopCount = 0
    package private(set) var isInstalled = false
    /// Every `stop()`, for a test that waits on a teardown it cannot await.
    package let stops = EventCount()
    /// Set false to stand in for the untrusted-Accessibility case, where the
    /// real monitor never goes up.
    package var canInstall = true
    private var handler: (@MainActor (EditSignal) -> Void)?

    package func start(_ handler: @escaping @MainActor (EditSignal) -> Void) -> Bool {
        startCount += 1
        guard canInstall else { return false }
        isInstalled = true
        self.handler = handler
        return true
    }

    package func stop() {
        stopCount += 1
        isInstalled = false
        stops.increment()
    }

    package func send(_ signal: EditSignal) {
        handler?(signal)
    }
}

/// A `sleepFor` seam the test decides the duration of. No wall-clock: the window
/// elapses when `fireAll()` says it does (AGENTS.md forbids real sleeps here).
///
/// `fireAll()` LATCHES. The watcher starts its window inside a `Task`, which
/// does not necessarily reach the sleep before the test's next statement runs —
/// an un-latched fire would resume nobody and the window would then wait
/// forever, hanging the suite rather than failing it.
package final class EditSignalManualSleeper: Sendable {
    private struct State {
        var requested: [Duration] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var fired = false
    }

    private let state = Mutex(State())

    package init() {}

    /// Returns once a window has actually reached the sleep.
    ///
    /// `Task.yield()` is NOT enough: the window runs in a `Task` the main actor
    /// is free to schedule after the test's next statement, which made asserting
    /// the requested duration flaky (observed on the build host, 2026-07-27).
    package func waitForSleepRequest() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                guard current.requested.isEmpty else { return true }
                current.arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    package func sleep(_ duration: Duration) async {
        let (alreadyFired, arrivals) = state.withLock { current -> (Bool, [CheckedContinuation<Void, Never>]) in
            current.requested.append(duration)
            let arrivals = current.arrivalWaiters
            current.arrivalWaiters = []
            return (current.fired, arrivals)
        }
        for arrival in arrivals { arrival.resume() }
        guard !alreadyFired else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                guard !current.fired else { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    package var requestedDurations: [Duration] { state.withLock { $0.requested } }

    package func fireAll() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.fired = true
            let waiters = current.waiters + current.arrivalWaiters
            current.waiters = []
            current.arrivalWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Injected clock, mirroring `CaptureTestClock` in the store suite.
package final class EditSignalTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    package init() {}

    package func now() -> Date { value.withLock { $0 } }
    package func advance(_ seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
