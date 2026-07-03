import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

@MainActor
final class EscapeCancelHandlerTests: XCTestCase {
    // Held so tearDown can stop any handler this test started. When start()
    // registers the real Carbon hotkey, bare Escape is consumed system-wide
    // until stop() unregisters it.
    private var startedHandlers: [EscapeCancelHandler] = []

    override func setUp() async throws {
        try await super.setUp()
        EscapeCancelHandler.resetDebugState()
    }

    override func tearDown() async throws {
        for handler in startedHandlers { handler.stop() }
        startedHandlers.removeAll()
        EscapeCancelHandler.resetDebugState()
        try await super.tearDown()
    }

    private func makeStartedHandler() -> EscapeCancelHandler {
        let handler = EscapeCancelHandler()
        startedHandlers.append(handler)
        return handler
    }

    // Regression for "Escape does nothing in the packaged app": start() must
    // record a deterministic outcome instead of silently swallowing setup
    // failures. The exact result can vary by host depending on whether bare
    // Escape is already reserved.
    func testStartRecordsOutcomeInsteadOfSilentlyNoOping() {
        let handler = makeStartedHandler()

        handler.start()

        XCTAssertEqual(EscapeCancelHandler.startCallCount, 1)
        XCTAssertNotEqual(
            EscapeCancelHandler.lastStartOutcome,
            .none,
            "start() must always record an outcome; a silent no-op is the bug we're fixing."
        )
        switch EscapeCancelHandler.lastStartOutcome {
        case .registered, .handlerInstallFailed, .registrationFailed:
            break
        case .none:
            XCTFail("unexpected start outcome: \(EscapeCancelHandler.lastStartOutcome)")
        }
    }

    func testDoubleStartDoesNotDoubleRegister() {
        EscapeCancelHandler.debugConfigureRegistration(status: noErr)
        let handler = makeStartedHandler()

        handler.start()
        handler.start()

        XCTAssertEqual(EscapeCancelHandler.startCallCount, 2)
        XCTAssertEqual(EscapeCancelHandler.registrationCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.lastStartOutcome, .registered)
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

    func testStopUnregistersOnceWhenCalledRepeatedly() {
        EscapeCancelHandler.debugConfigureRegistration(status: noErr)
        let handler = makeStartedHandler()

        handler.start()
        handler.stop()
        handler.stop()

        XCTAssertEqual(EscapeCancelHandler.unregistrationCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.stopCallCount, 2)
    }

    func testRegistrationFailureOutcomeRecorded() {
        let status = OSStatus(-9878)
        EscapeCancelHandler.debugConfigureRegistration(status: status)
        let handler = makeStartedHandler()

        handler.start()

        XCTAssertEqual(EscapeCancelHandler.startCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.registrationCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.lastStartOutcome, .registrationFailed(status))
        XCTAssertEqual(EscapeCancelHandler.unregistrationCallCount, 0)
    }

    // start() is followed by stop() on every session end; the counters must
    // advance and an outcome must be recorded so diagnostic state is never left
    // stale or misleading.
    func testStartThenStopAdvancesCounters() {
        EscapeCancelHandler.debugConfigureRegistration(status: noErr)
        let handler = makeStartedHandler()

        handler.start()
        let outcomeAfterStart = EscapeCancelHandler.lastStartOutcome
        handler.stop()

        XCTAssertEqual(EscapeCancelHandler.startCallCount, 1)
        XCTAssertEqual(EscapeCancelHandler.stopCallCount, 1)
        XCTAssertEqual(outcomeAfterStart, .registered)
    }
}
