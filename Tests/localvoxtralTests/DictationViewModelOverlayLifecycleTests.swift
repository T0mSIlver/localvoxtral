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
        XCTAssertEqual(overlayCoordinator.dismissAfterHoldCallCount, 1)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
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

    func testTranscriptionFinalizedDisconnectsImmediatelyDuringFinalization() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        viewModel.activeClientSource = .realtimeAPI
        viewModel.isFinalizingStop = true
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.realtimeAPIClient.debugPrimeConnectedStateForTesting(task: task)

        viewModel.handle(event: .transcriptionFinalized, source: .realtimeAPI)

        let timeoutAt = Date().addingTimeInterval(1.0)
        while viewModel.isFinalizingStop, Date() < timeoutAt {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertNil(viewModel.activeClientSource)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.dismissAfterHoldCallCount, 1)
        XCTAssertEqual(
            overlayCoordinator.lastDismissAfterHoldMinimumVisibility,
            TimingConstants.overlayFinalWordVisibilityMinimum
        )
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertFalse(viewModel.realtimeAPIClient.isConnected)
    }

    func testPushToTalkReleaseWhileConnectingStillSurfacesTimeoutFailure() async {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.dictationShortcutMode = .pushToTalk
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        // Prevent NSAlert from blocking test execution when the timeout path presents.
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        viewModel.debugSetPushToTalkShortcutStateForTesting(isHeld: true, hasActiveSession: true)
        viewModel.scheduleConnectTimeout()

        viewModel.debugHandleDictationShortcutReleaseForTesting()

        XCTAssertTrue(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connecting to realtime backend...")

        let timeoutAt = Date().addingTimeInterval(TimingConstants.connectTimeout + 1.0)
        while viewModel.isConnectingRealtimeSession, Date() < timeoutAt {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connection timed out.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertTrue(
            viewModel.lastError?.contains(
                "No connection response received in \(Int(TimingConstants.connectTimeout)) seconds"
            ) == true
        )
    }

    func testPushToTalkReleaseBeforeConnectSkipsDictationStartOnConnectedEvent() {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.dictationShortcutMode = .pushToTalk
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.activeClientSource = .realtimeAPI
        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        viewModel.debugSetPushToTalkShortcutStateForTesting(isHeld: true, hasActiveSession: true)

        viewModel.debugHandleDictationShortcutReleaseForTesting()
        viewModel.handle(event: .connected, source: .realtimeAPI)

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertNil(viewModel.activeClientSource)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
    }

    func testCancelPolishingForNewSessionIfNeededResetsFinalizationState() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.statusText = "Polishing..."
        let polishTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        viewModel.polishAndCommitTask = polishTask

        let cancelled = viewModel.cancelPolishingForNewSessionIfNeeded()

        XCTAssertTrue(cancelled)
        XCTAssertTrue(polishTask.isCancelled)
        XCTAssertNil(viewModel.polishAndCommitTask)
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertNil(viewModel.sessionOutputMode)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(overlayCoordinator.resetCallCount, 1)
    }

    func testFinishStoppedSessionClearsStalePolishingTaskReference() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"
        viewModel.polishAndCommitTask = Task<Void, Never> {}

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertNil(viewModel.polishAndCommitTask)
        XCTAssertFalse(viewModel.isFinalizingStop)
    }

    func testFinishStoppedSessionIgnoresDuplicateCallsWhilePolishingIsInFlight() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = BlockingMockLLMPolishingService()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello world"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let firstCallDeadline = ContinuousClock.now + .seconds(1)
        while await polishingService.callCount() < 1, ContinuousClock.now < firstCallDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let initialCallCount = await polishingService.callCount()
        XCTAssertEqual(initialCallCount, 1)
        XCTAssertTrue(viewModel.isCompletingStoppedSession)

        viewModel.finishStoppedSession(promotePendingSegment: false)
        viewModel.finishStoppedSession(promotePendingSegment: false)

        let duplicateCallCount = await polishingService.callCount()
        XCTAssertEqual(duplicateCallCount, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 0)

        await polishingService.resumePendingRequest()

        let finishDeadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < finishDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let finalCallCount = await polishingService.callCount()
        XCTAssertFalse(viewModel.isCompletingStoppedSession)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
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

private actor BlockingMockLLMPolishingService: LLMPolishingServicing {
    private var requests = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func polish(
        text: String,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return LLMPolishingResult(
            rawText: text,
            polishedText: "Hello world.",
            durationSeconds: 0.01
        )
    }

    func callCount() -> Int {
        requests
    }

    func resumePendingRequest() {
        continuation?.resume()
        continuation = nil
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
    var dismissAfterHoldCallCount = 0
    var lastDismissAfterHoldMinimumVisibility: TimeInterval?
    var resetCallCount = 0
    var commitTargetAppPID: pid_t? = nil

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

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissAfterHoldCallCount += 1
        lastDismissAfterHoldMinimumVisibility = minimumVisibility
    }

    func reset() {
        resetCallCount += 1
    }
}
