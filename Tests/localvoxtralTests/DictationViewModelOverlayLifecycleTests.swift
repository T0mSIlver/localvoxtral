import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationViewModelOverlayLifecycleTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test instances
    // for the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    func testSessionOutputModeIsLatchedWhileSessionIsActive() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        settings.dictationOutputMode = .liveAutoPaste

        XCTAssertTrue(viewModel.isOverlayBufferModeEnabled)
        XCTAssertFalse(viewModel.isLiveAutoPasteModeEnabled)

        viewModel.sessionOutputMode = nil

        XCTAssertFalse(viewModel.isOverlayBufferModeEnabled)
        XCTAssertTrue(viewModel.isLiveAutoPasteModeEnabled)
    }

    func testStopWithoutFinalizationStillCommitsOverlayUsingLatchedSessionMode() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        settings.dictationOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = " world"

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)

        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 1)
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "hello world")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.commitText, "hello\nworld")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertNil(viewModel.sessionOutputMode)
    }

    func testFinishStoppedSessionCommitFailureKeepsOverlayVisible() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        overlayCoordinator.commitOutcome = .failed(message: "Unable to insert buffered text into the focused app.")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertEqual(viewModel.statusText, "Insert failed.")
        XCTAssertEqual(viewModel.lastError, "Unable to insert buffered text into the focused app.")
        XCTAssertNil(viewModel.sessionOutputMode)
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName = "localvoxtral.DictationViewModelOverlayLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        return settings
    }

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
    }
}

private struct BufferCall {
    let displayText: String
    let commitText: String
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded

    var startSessionAnchors: [OverlayAnchor?] = []
    var beginFinalizingCalls: [BufferCall] = []
    var refreshCalls: [BufferCall] = []
    var commitCallCount = 0
    var resetCallCount = 0

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor: OverlayAnchor?) {
        startSessionAnchors.append(preResolvedAnchor)
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        beginFinalizingCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        refreshCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        return commitOutcome
    }

    func reset() {
        resetCallCount += 1
    }
}
