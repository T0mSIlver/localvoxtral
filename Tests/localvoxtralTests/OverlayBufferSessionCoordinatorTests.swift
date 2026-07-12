import CoreGraphics
import XCTest
@testable import localvoxtral

@MainActor
final class OverlayBufferSessionCoordinatorTests: XCTestCase {
    override func tearDown() async throws {
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    // MARK: - Secure Keyboard Entry at commit time (#89)

    func testCommitUnderSecureInputSkipsInsertionAndCopiesToClipboard() {
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var copiedTexts: [String] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            copyToPasteboard: { copiedTexts.append($0); return true }
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "secret words",
            commitBufferText: "secret words"
        )

        // Auto-copy OFF on purpose: under secure input the clipboard is the
        // only place the words can survive, so the copy must be unconditional.
        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        guard case .copiedToClipboard(let message) = outcome else {
            return XCTFail("commit must report the clipboard fallback, got \(outcome)")
        }
        XCTAssertTrue(message.contains("copied"), "message tells the user where the text went")
        XCTAssertTrue(
            committer.insertedTexts.isEmpty && committer.pastedTexts.isEmpty,
            "synthetic insertion is never attempted — it would be swallowed while reporting success"
        )
        XCTAssertEqual(copiedTexts, ["secret words"])
        XCTAssertEqual(renderer.snapshots.compactMap { $0 }.last?.phase, .commitFailed)
    }

    func testClipboardFallbackPanelDismissesAfterReadableHold() async {
        // Owner field feedback on #90: the fallback panel used to persist
        // like a real failure. It must hold the message readable, then hide.
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        let renderer = MockOverlayRenderer()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [Duration] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: MockOverlayAnchorResolver(),
            now: { currentDate },
            sleepFor: { requestedSleeps.append($0) },
            copyToPasteboard: { _ in true }
        )
        let committer = MockOverlayTextCommitter()

        coordinator.startSession()
        coordinator.beginFinalizing(displayBufferText: "words", commitBufferText: "words")

        // The user dictated a while ago; without re-anchoring the hold to the
        // fallback message render, the elapsed time would swallow the whole
        // visibility window and the message would flash away unread.
        currentDate = currentDate.addingTimeInterval(10)
        _ = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)
        XCTAssertEqual(renderer.hideCallCount, 0, "the fallback message is showing")

        coordinator.dismissAfterHold(
            minimumVisibility: TimingConstants.overlayClipboardFallbackVisibility
        )
        guard let dismissTask = coordinator.debugDismissTask else {
            XCTFail("expected a pending dismiss hold task — the fallback panel must not persist")
            return
        }
        await dismissTask.value

        XCTAssertEqual(
            requestedSleeps, [.seconds(TimingConstants.overlayClipboardFallbackVisibility)],
            "the full visibility window, anchored to the message render"
        )
        XCTAssertEqual(renderer.hideCallCount, 1, "panel dismisses once the hold elapses")
    }

    func testFailedClipboardWriteUnderSecureInputKeepsThePersistentPanel() {
        // Codex finding on #90 (round 7): a failed pasteboard write must not
        // claim "copied" and dismiss the transcript's only remaining copy.
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        let renderer = MockOverlayRenderer()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: MockOverlayAnchorResolver(),
            copyToPasteboard: { _ in false }
        )
        let committer = MockOverlayTextCommitter()

        coordinator.startSession()
        coordinator.beginFinalizing(displayBufferText: "words", commitBufferText: "words")
        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        guard case .failed(let message) = outcome else {
            return XCTFail("must report a real failure, got \(outcome)")
        }
        XCTAssertFalse(message.contains("paste it manually"), "must not claim the text was copied")
        XCTAssertTrue(committer.insertedTexts.isEmpty, "still no doomed synthetic attempts")
        XCTAssertEqual(renderer.snapshots.compactMap { $0 }.last?.phase, .commitFailed)
    }

    func testCommitProceedsNormallyWhenSecureInputOff() {
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var copiedTexts: [String] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            copyToPasteboard: { copiedTexts.append($0); return true }
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertedTexts, ["hello"])
        XCTAssertTrue(copiedTexts.isEmpty)
    }

    func testShowSecureInputWarningRendersInsideTheOverlayWhileBuffering() {
        let renderer = MockOverlayRenderer()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: MockOverlayAnchorResolver()
        )

        coordinator.startSession()
        coordinator.showSecureInputWarning()

        let rendered = renderer.snapshots.compactMap { $0 }.last
        XCTAssertEqual(rendered?.phase, .buffering)
        XCTAssertEqual(
            rendered?.secureInputActive, true,
            "the marker must be visible in the overlay panel, not only the closed popover"
        )
        XCTAssertNil(
            rendered?.errorMessage,
            "no separate warning sentence — the phase title carries it (owner feedback on #90)"
        )
    }

    func testMarkPolishedRendersBadgeIntoSnapshotAndResetClearsIt() {
        let renderer = MockOverlayRenderer()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: MockOverlayAnchorResolver()
        )

        coordinator.startSession()
        coordinator.beginFinalizing(displayBufferText: "Hello world.", commitBufferText: "Hello world.")
        coordinator.markPolished(true)

        let rendered = renderer.snapshots.compactMap { $0 }.last
        XCTAssertEqual(rendered?.phase, .finalizing)
        XCTAssertEqual(
            rendered?.polished, true,
            "the badge must reach the rendered snapshot, not just the state machine"
        )

        // Clearing the flag re-renders without the badge (no lingering annotation).
        coordinator.markPolished(false)
        XCTAssertEqual(renderer.snapshots.compactMap { $0 }.last?.polished, false)

        // A fresh session (reset precedes startSession in the real flow) is clean.
        coordinator.markPolished(true)
        coordinator.reset()
        coordinator.startSession()
        coordinator.beginFinalizing(displayBufferText: "next", commitBufferText: "next")
        XCTAssertEqual(
            renderer.snapshots.compactMap { $0 }.last?.polished, false,
            "a new session must not carry a stale badge"
        )
    }

    func testCommitUsesPIDCapturedAtStopTime() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        anchorResolver.focusedPID = 222
        coordinator.refresh(
            displayBufferText: "hello again",
            commitBufferText: "hello again"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertPreferredPIDs.count, 1)
        XCTAssertEqual(committer.insertPreferredPIDs.first ?? nil, 111)
    }

    func testCommitWithAutoCopyCopiesTextToPasteboard() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var copiedTexts: [String] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            copyToPasteboard: { copiedTexts.append($0); return true }
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "copy me",
            commitBufferText: "copy me"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: true)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(copiedTexts, ["copy me"])
    }

    func testCommitWithAutoCopyDisabledDoesNotCopyToPasteboard() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var copiedTexts: [String] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            copyToPasteboard: { copiedTexts.append($0); return true }
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "do not copy",
            commitBufferText: "do not copy"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(copiedTexts.isEmpty)
    }

    func testResetHidesRenderer() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )

        coordinator.startSession()
        coordinator.reset()

        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    func testCommitFailureRendersCommitFailedSnapshot() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .failed
        committer.pasteResult = false
        committer.isAccessibilityTrusted = true

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(
            outcome,
            .failed(message: "Unable to insert buffered text into the focused app.")
        )
        let latestSnapshot = renderer.snapshots.last ?? nil
        XCTAssertEqual(latestSnapshot?.phase, .commitFailed)
    }

    func testCommitUsesLastKnownLivePIDWhenFocusTemporarilyUnavailableAtStop() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.refresh(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        anchorResolver.focusedPID = nil
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertPreferredPIDs.first ?? nil, 111)
    }

    func testCommitUsesDedicatedCommitBufferTextInsteadOfDisplayBufferText() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByAccessibility

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "display hello world",
            commitBufferText: "commit\nhello\nworld"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertedTexts.first ?? "", "commit\nhello\nworld")
    }

    func testCommitSucceedsWhenKeyboardPrimaryPathSucceeds() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .insertedByKeyboardFallback
        committer.pasteResult = false

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertedTexts.count, 1)
        XCTAssertTrue(committer.pastedTexts.isEmpty)
    }

    func testCommitFallsBackToCommandVWhenPrimaryInsertionFails() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )
        let committer = MockOverlayTextCommitter()
        committer.insertResult = .failed
        committer.pasteResult = true

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertedTexts.count, 1)
        XCTAssertEqual(committer.pastedTexts.count, 1)
    }

    func testDismissAfterHoldWaitsFromBeginFinalizingWhenNoFinalRefreshArrives() async {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let currentDate = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [Duration] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            now: { currentDate },
            sleepFor: { requestedSleeps.append($0) }
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        coordinator.dismissAfterHold(minimumVisibility: 0.05)
        XCTAssertEqual(renderer.hideCallCount, 0)

        guard let dismissTask = coordinator.debugDismissTask else {
            XCTFail("expected a pending dismiss hold task")
            return
        }
        await dismissTask.value

        XCTAssertEqual(requestedSleeps, [.seconds(0.05)])
        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    func testDismissAfterHoldIsImmediateWhenTextWasAlreadyStaleBeforeFinalizing() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [Duration] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            now: { currentDate },
            sleepFor: { requestedSleeps.append($0) }
        )

        coordinator.startSession()
        coordinator.refresh(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        currentDate.addTimeInterval(0.08)

        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        coordinator.dismissAfterHold(minimumVisibility: 0.05)

        XCTAssertEqual(renderer.hideCallCount, 1)
        XCTAssertTrue(requestedSleeps.isEmpty)
        XCTAssertNil(coordinator.debugDismissTask)
    }

    func testDismissAfterHoldUnchangedFinalizingRefreshDoesNotExtendHold() {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [Duration] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            now: { currentDate },
            sleepFor: { requestedSleeps.append($0) }
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        currentDate.addTimeInterval(0.08)

        coordinator.refresh(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        coordinator.dismissAfterHold(minimumVisibility: 0.05)

        XCTAssertEqual(renderer.hideCallCount, 1)
        XCTAssertTrue(requestedSleeps.isEmpty)
        XCTAssertNil(coordinator.debugDismissTask)
    }

    func testDismissAfterHoldChangedFinalizingRefreshExtendsHold() async {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [Duration] = []
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver,
            now: { currentDate },
            sleepFor: { requestedSleeps.append($0) }
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        // Even when the hold from beginFinalizing has already elapsed, a
        // finalizing refresh that changes the visible text restarts the hold.
        currentDate.addTimeInterval(0.08)
        coordinator.refresh(
            displayBufferText: "hello world",
            commitBufferText: "hello world"
        )

        coordinator.dismissAfterHold(minimumVisibility: 0.05)
        XCTAssertEqual(renderer.hideCallCount, 0)

        guard let dismissTask = coordinator.debugDismissTask else {
            XCTFail("expected a pending dismiss hold task")
            return
        }
        await dismissTask.value

        XCTAssertEqual(requestedSleeps, [.seconds(0.05)])
        XCTAssertEqual(renderer.hideCallCount, 1)
    }
}

@MainActor
private final class MockOverlayRenderer: OverlayBufferRendering {
    var snapshots: [OverlayBufferStateMachine.Snapshot?] = []
    var hideCallCount = 0

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        snapshots.append(snapshot)
    }

    func hide() {
        hideCallCount += 1
    }
}

@MainActor
private final class MockOverlayAnchorResolver: OverlayAnchorResolving {
    var focusedPID: pid_t?
    var anchor = OverlayAnchor(
        targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
        source: .windowCenter
    )

    func resolveAnchor() -> OverlayAnchor {
        anchor
    }

    func resolveFrontmostAppPID() -> pid_t? {
        focusedPID
    }
}

@MainActor
private final class MockOverlayTextCommitter: OverlayTextCommitting {
    var isAccessibilityTrusted = true
    var insertResult: TextInsertResult = .failed
    var pasteResult = false

    var insertedTexts: [String] = []
    var pastedTexts: [String] = []
    var insertPreferredPIDs: [pid_t?] = []
    var pastePreferredPIDs: [pid_t?] = []

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult {
        insertedTexts.append(text)
        insertPreferredPIDs.append(preferredAppPID)
        return insertResult
    }

    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t?) -> Bool {
        pastedTexts.append(text)
        pastePreferredPIDs.append(preferredAppPID)
        return pasteResult
    }
}
