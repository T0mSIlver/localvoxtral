import AppKit
import Synchronization
import XCTest
@testable import localvoxtral

/// The one-shot-per-terminal Automation consent pre-warm. What matters here is
/// the shape, not the Apple event (which tests must never send): it fires
/// exactly once per terminal, only while that terminal is actually running (a
/// pre-warm that LAUNCHES the terminal would be worse than the freeze it
/// prevents), and it arms a launch observer instead when the terminal is not
/// there yet.
@MainActor
final class TerminalAutomationConsentPrewarmTests: XCTestCase {
    private let ghostty = TerminalScreenAllowlist.ghosttyBundleID
    private let iterm2 = TerminalScreenAllowlist.iterm2BundleID
    private let appleTerminal = TerminalScreenAllowlist.appleTerminalBundleID

    override func setUp() async throws {
        try await super.setUp()
        TerminalAutomationConsentPrewarm.debugReset()
    }

    override func tearDown() async throws {
        TerminalAutomationConsentPrewarm.debugReset()
        try await super.tearDown()
    }

    /// Deterministic quiescence: the pre-warm enqueues its `execute` on a
    /// `Task { @MainActor in … }` synchronously inside
    /// `fireOnceWhenTerminalIsAvailable`, so any such Task is already on the
    /// main actor's serial queue AHEAD of the barrier this awaits.
    /// Same-priority jobs run FIFO, so when the barrier resumes, every
    /// pre-warm Task enqueued before it has run — including a buggy SECOND
    /// one, which is exactly what "did not fire again" must catch.
    private func drainMainActorQueue() async {
        await Task { @MainActor in }.value
    }

    func testFiresExactlyOnceWhenTerminalIsRunning() async {
        let executions = Mutex(0)
        let (executed, signal) = AsyncStream.makeStream(of: Void.self)
        let execute: @MainActor @Sendable () async -> Void = {
            executions.withLock { $0 += 1 }
            signal.yield()
        }
        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
            bundleID: ghostty,
            isTerminalRunning: { true },
            execute: execute,
            notificationCenter: NotificationCenter()
        )
        // A second call (a second broker start, a settings change) must not
        // send a second event.
        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
            bundleID: ghostty,
            isTerminalRunning: { true },
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

    func testDoesNotFireWhileTerminalIsNotRunning() async {
        let executions = Mutex(0)
        let center = NotificationCenter()
        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
            bundleID: iterm2,
            isTerminalRunning: { false },
            execute: { executions.withLock { $0 += 1 } },
            notificationCenter: center
        )
        // An unrelated app launching (iTerm2 still absent) must not fire —
        // firing would LAUNCH iTerm2 via the tell.
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await drainMainActorQueue()
        XCTAssertEqual(executions.withLock { $0 }, 0)
    }

    func testFiresWhenTerminalLaunchesLater() async {
        let executions = Mutex(0)
        let (executed, signal) = AsyncStream.makeStream(of: Void.self)
        let running = Mutex(false)
        let center = NotificationCenter()
        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
            bundleID: appleTerminal,
            isTerminalRunning: { running.withLock { $0 } },
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
        // The observer is one-shot: another launch notification (the terminal
        // relaunching) must not re-fire.
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await drainMainActorQueue()
        XCTAssertEqual(executions.withLock { $0 }, 1)
    }

    /// The one-shot state is PER TERMINAL: Ghostty having fired must not
    /// swallow iTerm2's or Terminal.app's pre-warm (each terminal is its own
    /// TCC consent pair), and a not-yet-running terminal arms its own launch
    /// observer independently of the ones that already fired.
    func testOneShotStateIsPerTerminal() async {
        let fired = Mutex<[String]>([])
        let (executed, signal) = AsyncStream.makeStream(of: Void.self)
        let center = NotificationCenter()
        for bundleID in [ghostty, iterm2] {
            TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
                bundleID: bundleID,
                isTerminalRunning: { true },
                execute: {
                    fired.withLock { $0.append(bundleID) }
                    signal.yield()
                },
                notificationCenter: center
            )
        }
        let appleTerminal = self.appleTerminal
        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
            bundleID: appleTerminal,
            isTerminalRunning: { true },
            execute: {
                fired.withLock { $0.append(appleTerminal) }
                signal.yield()
            },
            notificationCenter: center
        )
        var iterator = executed.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        await drainMainActorQueue()
        XCTAssertEqual(
            fired.withLock { Set($0) },
            [ghostty, iterm2, appleTerminal],
            "each terminal pre-warms independently, exactly once"
        )
        XCTAssertEqual(fired.withLock { $0.count }, 3)
    }

    func testSettingsOffToOnTransitionPrewarmsOnlyOncePerAppRun() async {
        let suiteName = "localvoxtral.TerminalPrewarmSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        let executions = Mutex(0)
        let observer = TerminalAutomationConsentPrewarmSettingsObserver(settings: settings) {
            TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
                bundleID: TerminalScreenAllowlist.ghosttyBundleID,
                isTerminalRunning: { true },
                execute: { executions.withLock { $0 += 1 } },
                notificationCenter: NotificationCenter()
            )
        }
        observer.start()

        settings.terminalScreenContextEnabled = true
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(
            executions.withLock { $0 }, 1,
            "enabling a context setting after launch must pre-warm before dictation"
        )

        settings.terminalScreenContextEnabled = false
        settings.terminalScreenContextEnabled = true
        settings.claudeRepoContextEnabled = true
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(
            executions.withLock { $0 }, 1,
            "a successful pre-warm must remain at-most-once for the app run"
        )
        _ = observer
    }
}
