import XCTest
@testable import localvoxtral

/// Silence auto-stop (#318) on a `ManualSessionClock`: an Overlay Buffer tap
/// session stops once no new text has arrived for the chosen time, through
/// the normal stop path. No test here waits on the wall clock.
@MainActor
final class SilenceAutoStopTests: XCTestCase {
    private func makeLiveOverlaySession(
        clock: ManualSessionClock,
        silenceAutoStop: SilenceAutoStop = .after8,
        outputMode: DictationOutputMode = .overlayBuffer
    ) -> (DictationViewModel, MockOverlayCoordinator, FakeRealtimeClient) {
        let overlay = MockOverlayCoordinator()
        let settings = makeSettings(outputMode: outputMode)
        settings.overlayBufferSilenceAutoStop = silenceAutoStop
        settings.llmPolishingEnabled = false
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(clock: clock.clock)
        )
        viewModel.appConfigStore = MockAppConfigStore()
        // A stop or a lost connection reaches the session teardown, which can
        // arm the real connect-timeout alert on this retained view model.
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        viewModel.session.activeRealtimeClient = client
        viewModel.session.sessionConnectionGeneration = client.stampNewConnection()
        viewModel.session.sessionOutputMode = outputMode
        viewModel.session.sessionRealtimeConfiguration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://127.0.0.1:8000/v1/realtime")!,
            apiKey: "session-key",
            model: "session-model"
        )
        viewModel.isDictating = true
        return (viewModel, overlay, client)
    }

    func testTextThatKeepsArrivingKeepsTheSessionRunning() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()

        // A word every 5 s for 40 s: never 8 s of quiet.
        for _ in 0..<8 {
            await clock.waitForSleepers(1)
            clock.advance(by: 5)
            viewModel.session.handle(event: .partialTranscript("word "))
        }
        await clock.waitForSleepers(1)

        XCTAssertTrue(viewModel.isDictating)
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertTrue(overlay.beginFinalizingCalls.isEmpty)
        XCTAssertNotNil(viewModel.session.silenceAutoStopTask)
    }

    func testSilencePastTheThresholdStopsOnceThroughTheNormalStop() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        let watch = viewModel.session.silenceAutoStopTask

        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        viewModel.session.handle(event: .finalTranscript("hello there"))
        // The first sleep ends at 8 s; text at 3 s moves the stop to 11 s.
        clock.advance(by: 5)
        await clock.waitForSleepers(1)
        XCTAssertTrue(viewModel.isDictating, "only 5 s since the last text")

        clock.advance(by: 3 - 0.01)
        XCTAssertTrue(viewModel.isDictating, "one hundredth short, still dictating")

        clock.advance(by: 0.01)
        await watch?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertTrue(viewModel.isFinalizingStop, "the stop finalizes like a tapped stop")
        XCTAssertEqual(overlay.beginFinalizingCalls.count, 1, "the overlay finalizes once")
        XCTAssertNil(viewModel.session.silenceAutoStopTask, "the watch ended with its one stop")
    }

    func testAFinalThatRepeatsThePartialIsNotNewText() async {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        let watch = viewModel.session.silenceAutoStopTask

        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        viewModel.session.handle(event: .partialTranscript("hello there"))
        clock.advance(by: 4.9)
        // The final only confirms the partial: the quiet still counts from 3 s.
        viewModel.session.handle(event: .finalTranscript("hello there"))
        await clock.waitForSleepers(1)
        clock.advance(by: 3.1)
        // A watch that counted the final sleeps on and never ends here; the
        // bound turns that into a failure instead of a hung suite.
        let ended = BoundedWait()
        Task { await watch?.value; ended.resolve() }
        let stopped = await ended.value(failAfter: 10)

        XCTAssertTrue(stopped, "8 s after the last new words, the watch stops the session")
        XCTAssertFalse(viewModel.isDictating)
    }

    func testAFinalWithNewWordsIsNewText() async {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()

        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        viewModel.session.handle(event: .partialTranscript("hello"))
        clock.advance(by: 4.9)
        viewModel.session.handle(event: .finalTranscript("hello there"))
        await clock.waitForSleepers(1)
        clock.advance(by: 3.1)
        await clock.waitForSleepers(1)

        XCTAssertTrue(viewModel.isDictating, "the final added a word at 7.9 s")
    }

    func testSettingOffNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock, silenceAutoStop: .off)
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
        XCTAssertTrue(viewModel.isDictating)
    }

    func testPushToTalkHoldSessionNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock)
        viewModel.shortcuts.hasActivePushToTalkShortcutSession = true
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask, "a held shortcut stops on release")
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testModifierHoldSessionNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock)
        viewModel.shortcuts.isModifierOnlyHoldActive = true
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testLiveAutoPasteNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _, _) = makeLiveOverlaySession(clock: clock, outputMode: .liveAutoPaste)
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testAManualStopDisarmsTheWatch() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        let watch = viewModel.session.silenceAutoStopTask
        await clock.waitForSleepers(1)

        viewModel.session.stopDictation(reason: "manual toggle")
        await watch?.value

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(overlay.beginFinalizingCalls.count, 1, "only the manual stop ran")
    }

    // MARK: - Reconnect (#380)

    /// Regression (Codex review of #498): the watch used to check only
    /// `isDictating`, which stays true through a reconnect run, so it could
    /// stop the session before the audio buffered in the gap was replayed.
    func testADropMidSessionStopsTheWatchWhileTheReconnectRuns() async {
        let clock = ManualSessionClock()
        let (viewModel, _, client) = makeLiveOverlaySession(clock: clock)
        // Every reconnect wait lasts an hour on the manual clock: the run is
        // still in flight for everything this test advances.
        viewModel.dependencies.reconnectSleep = { _ in await clock.sleep(.seconds(3600)) }
        viewModel.session.armSilenceAutoStopIfEnabled()
        let watch = viewModel.session.silenceAutoStopTask
        await clock.waitForSleepers(1)

        client.setConnected(false)
        viewModel.session.handle(event: .disconnected)
        XCTAssertTrue(viewModel.session.isReconnectingRealtimeSession)

        clock.advance(by: 20)
        await watch?.value

        XCTAssertTrue(viewModel.isDictating, "silence during a reconnect must not stop the session")
        XCTAssertTrue(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertNil(viewModel.session.silenceAutoStopTask, "no watch runs while the socket is down")

        viewModel.session.stopDictation(reason: "test cleanup")
    }

    func testTheWatchRestartsWhenTheReconnectedSocketIsLive() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay, client) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        let firstWatch = viewModel.session.silenceAutoStopTask
        await clock.waitForSleepers(1)

        // Dropped at 5 s, 3 s short of the first watch's stop.
        clock.advance(by: 5)
        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        client.setConnected(false)
        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertTrue(viewModel.isDictating)
        let secondWatch = viewModel.session.silenceAutoStopTask
        XCTAssertNotNil(secondWatch, "the watch re-arms on the new connection")
        XCTAssertNotEqual(secondWatch, firstWatch, "a new watch, counting from the reconnect")
        // The new watch, the restarted send loop and the restarted commit loop.
        await clock.waitForSleepers(3)

        // 8 s counts from the reconnect at 5 s, so the stop lands at 13 s.
        clock.advance(by: 8 - 0.01)
        XCTAssertTrue(viewModel.isDictating, "one hundredth short of 8 s since the reconnect")

        clock.advance(by: 0.01)
        await secondWatch?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(overlay.beginFinalizingCalls.count, 1)
    }

    // MARK: - The commit

    /// The Overlay Buffer commit a silence stop produces is the one a tapped
    /// stop produces, down to the server's end of the finalization.
    func testASilenceStopCommitsTheOverlayLikeATappedStop() async {
        let silence = await commitAfterStop { viewModel, clock in
            let watch = viewModel.session.silenceAutoStopTask
            clock.advance(by: 8)
            await watch?.value
        }
        let tapped = await commitAfterStop { viewModel, _ in
            viewModel.session.stopDictation(reason: "shortcut tap")
        }

        XCTAssertEqual(silence.commitCallCount, 1, "the silence stop reached the overlay commit")
        XCTAssertEqual(silence.commitCallCount, tapped.commitCallCount)
        XCTAssertEqual(silence.beginFinalizingCalls.map(\.commitText), ["hello there"])
        XCTAssertEqual(
            silence.beginFinalizingCalls.map(\.commitText),
            tapped.beginFinalizingCalls.map(\.commitText)
        )
        XCTAssertEqual(silence.refreshCalls.last?.commitText, "hello there")
        XCTAssertEqual(silence.refreshCalls.last?.commitText, tapped.refreshCalls.last?.commitText)
        XCTAssertEqual(silence.dismissHoldVisibilities, tapped.dismissHoldVisibilities)
        XCTAssertEqual(silence.resetCallCount, tapped.resetCallCount)
    }

    /// A live overlay session that hears "hello there", is stopped by `stop`,
    /// and then finalizes the way the server ends it: `transcription.done`,
    /// then the socket closing.
    private func commitAfterStop(
        _ stop: (DictationViewModel, ManualSessionClock) async -> Void
    ) async -> MockOverlayCoordinator {
        let clock = ManualSessionClock()
        let (viewModel, overlay, _) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        await clock.waitForSleepers(1)
        viewModel.session.handle(event: .finalTranscript("hello there"))

        await stop(viewModel, clock)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertTrue(viewModel.isFinalizingStop)

        viewModel.session.handle(event: .transcriptionFinalized)
        viewModel.session.handle(event: .disconnected)
        await awaitStoppedSessionCommit(viewModel)

        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertEqual(viewModel.statusText, "Ready")
        return overlay
    }

    func testSettingPersistsAndDefaultsOff() {
        let defaults = makeSettingsDefaults()
        XCTAssertEqual(makeSettings(defaults: defaults).overlayBufferSilenceAutoStop, .off)
        makeSettings(defaults: defaults).overlayBufferSilenceAutoStop = .after15
        XCTAssertEqual(makeSettings(defaults: defaults).overlayBufferSilenceAutoStop, .after15)
    }
}
