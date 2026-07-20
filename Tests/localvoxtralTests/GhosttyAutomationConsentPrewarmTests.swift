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
        // path enqueues on the main actor, so once we are running again after
        // the first signal, a bounded yield burst flushes anything pending.
        for _ in 0..<100 { await Task.yield() }
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
        for _ in 0..<100 { await Task.yield() }
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
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(executions.withLock { $0 }, 1)
    }
}
