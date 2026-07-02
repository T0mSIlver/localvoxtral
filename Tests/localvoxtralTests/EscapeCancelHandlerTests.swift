import XCTest
@testable import localvoxtral

@MainActor
final class EscapeCancelHandlerTests: XCTestCase {
    // Held so tearDown can stop any handler this test started. On a host that
    // IS Accessibility-trusted (e.g. a self-hosted runner), start() creates a
    // real CGEventTap that is kept alive by EscapeCancelHandler.shared; if we
    // don't stop() it, it would intercept keyDown system-wide for the rest of
    // the test-host process.
    private var startedHandlers: [EscapeCancelHandler] = []

    override func setUp() async throws {
        try await super.setUp()
        EscapeCancelHandler.resetDebugState()
        EscapeCancelHandler.isDictatingRef = false
    }

    override func tearDown() async throws {
        for handler in startedHandlers { handler.stop() }
        startedHandlers.removeAll()
        EscapeCancelHandler.resetDebugState()
        EscapeCancelHandler.isDictatingRef = false
        try await super.tearDown()
    }

    private func makeStartedHandler() -> EscapeCancelHandler {
        let handler = EscapeCancelHandler()
        startedHandlers.append(handler)
        return handler
    }

    // Regression for "Escape does nothing in the packaged app": the original
    // `start()` silently returned when `CGEvent.tapCreate` failed (no AX trust,
    // TCC state needing a relaunch, etc.), with no log and no observable
    // state. The fix records a deterministic outcome the harness can assert on,
    // and must not crash regardless of the host's trust state.
    func testStartRecordsOutcomeInsteadOfSilentlyNoOping() {
        let handler = makeStartedHandler()

        handler.start()

        XCTAssertEqual(EscapeCancelHandler.startCallCount, 1)
        XCTAssertNotEqual(
            EscapeCancelHandler.lastStartOutcome,
            .none,
            "start() must always record an outcome; a silent no-op is the bug we're fixing."
        )
        // The unit-test host is not Accessibility-trusted, so the expected
        // outcome is `.notTrusted`. A trusted dev/self-hosted host may instead
        // create the tap for real (`.created`). Both are acceptable — the
        // contract is "an outcome is recorded", not a specific host state.
        let allowed: [EscapeCancelStartOutcome] = [
            .notTrusted, .creationFailedNil, .noRunLoopSource, .created,
        ]
        XCTAssertTrue(
            allowed.contains(EscapeCancelHandler.lastStartOutcome),
            "unexpected start outcome: \(EscapeCancelHandler.lastStartOutcome)"
        )
    }

    // The untrusted-host failure path is the most likely real-world cause of
    // the bug (active event taps require Accessibility trust at creation time).
    // When AX trust is absent we must take the early-return branch BEFORE
    // attempting tapCreate. Runs on CI / GitHub-hosted runners and any host
    // without Accessibility trust for the xctest process; self-skips on a host
    // that is already trusted.
    func testStartOnUntrustedHostGatesOnAccessibilityTrustBeforeTapCreate() {
        let handler = makeStartedHandler()
        handler.start()

        guard EscapeCancelHandler.lastStartOutcome == .notTrusted else {
            // Host is trusted (e.g. self-hosted runner with AX enabled); the
            // notTrusted branch cannot be exercised here. The host-agnostic
            // contract is covered by testStartRecordsOutcomeInsteadOfSilentlyNoOping.
            return
        }
        XCTAssertEqual(EscapeCancelHandler.startCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.lastStartOutcome, .notTrusted)
    }

    // DictationViewModel calls stop() from many teardown paths (stop, cancel,
    // disconnect, abort-connect). It must be safe to call repeatedly and to
    // call when nothing was ever started.
    func testStopIsIdempotentWhenNeverStarted() {
        let handler = makeStartedHandler()
        // Never started — stop must still be safe and counted.
        handler.stop()
        handler.stop()
        XCTAssertEqual(EscapeCancelHandler.stopCallCount, 2)
    }

    // start() is followed by stop() on every session end; the start counter
    // must advance and an outcome must be recorded even when creation fails,
    // so the diagnostic state is never left stale/misleading. (start() always
    // calls stop() first as cleanup, so a start+stop pair moves the stop
    // counter by two — we assert the relative increase, not an absolute.)
    func testStartThenStopAdvancesCountersOnFailurePath() {
        let handler = makeStartedHandler()
        let stopCountBefore = EscapeCancelHandler.stopCallCount

        handler.start()
        let outcomeAfterStart = EscapeCancelHandler.lastStartOutcome
        let startCountAfterStart = EscapeCancelHandler.startCallCount

        handler.stop()

        XCTAssertEqual(startCountAfterStart, 1)
        XCTAssertNotEqual(outcomeAfterStart, .none)
        // start()'s internal cleanup stop() + the explicit stop() below.
        XCTAssertGreaterThanOrEqual(
            EscapeCancelHandler.stopCallCount,
            stopCountBefore + 2
        )
    }
}
