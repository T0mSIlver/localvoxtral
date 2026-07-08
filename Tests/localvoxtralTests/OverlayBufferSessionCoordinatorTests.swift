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
            copyToPasteboard: { copiedTexts.append($0) }
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

        guard case .failed(let message) = outcome else {
            return XCTFail("commit must report failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("copied"), "message tells the user where the text went")
        XCTAssertTrue(
            committer.insertedTexts.isEmpty && committer.pastedTexts.isEmpty,
            "synthetic insertion is never attempted — it would be swallowed while reporting success"
        )
        XCTAssertEqual(copiedTexts, ["secret words"])
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
            copyToPasteboard: { copiedTexts.append($0) }
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

        XCTAssertEqual(renderer.snapshots.compactMap { $0 }.last?.phase, .buffering)
        XCTAssertNotNil(
            renderer.snapshots.compactMap { $0 }.last?.errorMessage,
            "the warning must be visible in the overlay panel, not only the closed popover"
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
            copyToPasteboard: { copiedTexts.append($0) }
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
            copyToPasteboard: { copiedTexts.append($0) }
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
