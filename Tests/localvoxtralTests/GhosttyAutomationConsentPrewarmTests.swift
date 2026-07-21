import AppKit
import Synchronization
import XCTest
@testable import localvoxtral

/// The one-shot Automation consent pre-warm. What matters here is the shape,
/// not the Apple event (which tests must never send): it fires exactly once,
/// only while Ghostty is actually running (a pre-warm that LAUNCHES Ghostty
/// would be worse than the freeze it prevents), and it arms a launch observer
/// instead when Ghostty is not there yet.
@MainActor
final class GhosttyAutomationConsentPrewarmTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        GhosttyAutomationConsentPrewarm.debugReset()
    }

    override func tearDown() async throws {
        GhosttyAutomationConsentPrewarm.debugReset()
        try await super.tearDown()
    }

    /// Deterministic quiescence: the pre-warm enqueues its `execute` on a
    /// `Task { @MainActor in … }` synchronously inside `fireOnceWhenGhosttyIsAvailable`,
    /// so any such Task is already on the main actor's serial queue AHEAD of the
    /// barrier this awaits. Same-priority jobs run FIFO, so when the barrier
    /// resumes, every pre-warm Task enqueued before it has run — including a
    /// buggy SECOND one, which is exactly what "did not fire again" must catch.
    /// Replaces a fixed `for _ in 0..<100 { await Task.yield() }` burst that only
    /// hoped to outlast the enqueue.
    ///
    /// NOTE: the stronger form — the production seam signalling a continuation
    /// after its decision point — needs a change to `GhosttyAutomationConsentPrewarm`,
    /// which another worker owns concurrently; that is deferred to them. This
    /// barrier is the deterministic improvement available from the test alone.
    private func drainMainActorQueue() async {
        await Task { @MainActor in }.value
    }

    func testFiresExactlyOnceWhenGhosttyIsRunning() async {
        let executions = Mutex(0)
        let (executed, signal) = AsyncStream.makeStream(of: Void.self)
        let execute: @MainActor @Sendable () -> Void = {
            executions.withLock { $0 += 1 }
            signal.yield()
        }
        GhosttyAutomationConsentPrewarm.fireOnceWhenGhosttyIsAvailable(
            isGhosttyRunning: { true },
            execute: execute,
            notificationCenter: NotificationCenter()
        )
        // A second call (a second broker start, a settings change) must not
        // send a second event.
        GhosttyAutomationConsentPrewarm.fireOnceWhenGhosttyIsAvailable(
            isGhosttyRunning: { true },
            execute: execute,
            notificationCenter: NotificationCenter()
        )
        var iterator = executed.makeAsyncIterator()
        _ = await iterator.next()
        // Drain any (incorrect) second execution deterministically: the fire
        // path enqueues on the main actor ahead of this barrier, so once the
        // barrier resumes anything pending has run.
        await drainMainActorQueue()
        XCTAssertEqual(executions.withLock { $0 }, 1)
    }

    func testDoesNotFireWhileGhosttyIsNotRunning() async {
        let executions = Mutex(0)
        let center = NotificationCenter()
        GhosttyAutomationConsentPrewarm.fireOnceWhenGhosttyIsAvailable(
            isGhosttyRunning: { false },
            execute: { executions.withLock { $0 += 1 } },
            notificationCenter: center
        )
        // An unrelated app launching (Ghostty still absent) must not fire —
        // firing would LAUNCH Ghostty via the tell.
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await drainMainActorQueue()
        XCTAssertEqual(executions.withLock { $0 }, 0)
    }

    func testFiresWhenGhosttyLaunchesLater() async {
        let executions = Mutex(0)
        let (executed, signal) = AsyncStream.makeStream(of: Void.self)
        let running = Mutex(false)
        let center = NotificationCenter()
        GhosttyAutomationConsentPrewarm.fireOnceWhenGhosttyIsAvailable(
            isGhosttyRunning: { running.withLock { $0 } },
            execute: {
                executions.withLock { $0 += 1 }
                signal.yield()
            },
            notificationCenter: center
        )
        XCTAssertEqual(executions.withLock { $0 }, 0, "precondition: nothing fires before launch")

        running.withLock { $0 = true }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        var iterator = executed.makeAsyncIterator()
        _ = await iterator.next()
        // The observer is one-shot: another launch notification (Ghostty
        // relaunching) must not re-fire.
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await drainMainActorQueue()
        XCTAssertEqual(executions.withLock { $0 }, 1)
    }
}
