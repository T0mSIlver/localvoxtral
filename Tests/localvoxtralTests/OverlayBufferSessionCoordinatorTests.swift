import CoreGraphics
import XCTest
@testable import localvoxtral

@MainActor
final class OverlayBufferSessionCoordinatorTests: XCTestCase {
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
            displayBufferText: "copy me",
            commitBufferText: "copy me"
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: true)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy me")
    }

    func testCommitWithAutoCopyDisabledDoesNotCopyToPasteboard() {
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
            displayBufferText: "do not copy",
            commitBufferText: "do not copy"
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let changeCount = pasteboard.changeCount

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
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
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )

        coordinator.dismissAfterHold(minimumVisibility: 0.05)
        XCTAssertEqual(renderer.hideCallCount, 0)

        let didHide = await waitUntil(timeout: .milliseconds(300)) {
            renderer.hideCallCount == 1
        }
        XCTAssertTrue(didHide)
        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    func testDismissAfterHoldIsImmediateWhenTextWasAlreadyStaleBeforeFinalizing() async {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )

        coordinator.startSession()
        coordinator.refresh(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        try? await Task.sleep(for: .milliseconds(80))

        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        coordinator.dismissAfterHold(minimumVisibility: 0.05)

        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    func testDismissAfterHoldUnchangedFinalizingRefreshDoesNotExtendHold() async {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        try? await Task.sleep(for: .milliseconds(80))

        coordinator.refresh(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        coordinator.dismissAfterHold(minimumVisibility: 0.05)

        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    func testDismissAfterHoldChangedFinalizingRefreshExtendsHold() async {
        let renderer = MockOverlayRenderer()
        let anchorResolver = MockOverlayAnchorResolver()
        let coordinator = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: anchorResolver
        )

        coordinator.startSession()
        coordinator.beginFinalizing(
            displayBufferText: "hello",
            commitBufferText: "hello"
        )
        coordinator.refresh(
            displayBufferText: "hello world",
            commitBufferText: "hello world"
        )

        coordinator.dismissAfterHold(minimumVisibility: 0.05)
        XCTAssertEqual(renderer.hideCallCount, 0)

        let didHide = await waitUntil(timeout: .milliseconds(300)) {
            renderer.hideCallCount == 1
        }
        XCTAssertTrue(didHide)
        XCTAssertEqual(renderer.hideCallCount, 1)
    }

    private func waitUntil(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }

        return true
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
