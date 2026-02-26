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
        committer.insertResult = true

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(bufferText: "hello")

        anchorResolver.focusedPID = 222
        coordinator.refresh(bufferText: "hello again")

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(committer.insertPreferredPIDs.count, 1)
        XCTAssertEqual(committer.insertPreferredPIDs.first ?? nil, 111)
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
        committer.insertResult = false
        committer.pasteResult = false
        committer.isAccessibilityTrusted = true

        anchorResolver.focusedPID = 111
        coordinator.startSession()
        coordinator.beginFinalizing(bufferText: "hello")

        let outcome = coordinator.commitIfNeeded(using: committer, autoCopyEnabled: false)

        XCTAssertEqual(
            outcome,
            .failed(message: "Unable to insert buffered text into the focused app.")
        )
        let latestSnapshot = renderer.snapshots.last ?? nil
        XCTAssertEqual(latestSnapshot?.phase, .commitFailed)
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
        source: .focusedInput
    )

    func resolveAnchor() -> OverlayAnchor {
        anchor
    }

    func resolveFocusedInputAppPID() -> pid_t? {
        focusedPID
    }
}

@MainActor
private final class MockOverlayTextCommitter: OverlayTextCommitting {
    var isAccessibilityTrusted = true
    var insertResult = false
    var pasteResult = false

    var insertPreferredPIDs: [pid_t?] = []
    var pastePreferredPIDs: [pid_t?] = []

    func insertTextUsingAccessibilityOnly(_ text: String, preferredAppPID: pid_t?) -> Bool {
        insertPreferredPIDs.append(preferredAppPID)
        return insertResult
    }

    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t?) -> Bool {
        pastePreferredPIDs.append(preferredAppPID)
        return pasteResult
    }
}
