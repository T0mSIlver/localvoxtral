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
    ) -> (DictationViewModel, MockOverlayCoordinator) {
        let overlay = MockOverlayCoordinator()
        let settings = makeSettings(outputMode: outputMode)
        settings.overlayBufferSilenceAutoStop = silenceAutoStop
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(clock: clock.clock)
        )
        retainForTestProcessLifetime(viewModel)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        viewModel.session.activeRealtimeClient = client
        viewModel.session.sessionOutputMode = outputMode
        viewModel.isDictating = true
        return (viewModel, overlay)
    }

    func testTextThatKeepsArrivingKeepsTheSessionRunning() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay) = makeLiveOverlaySession(clock: clock)
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
        let (viewModel, overlay) = makeLiveOverlaySession(clock: clock)
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

    func testSettingOffNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _) = makeLiveOverlaySession(clock: clock, silenceAutoStop: .off)
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
        XCTAssertTrue(viewModel.isDictating)
    }

    func testPushToTalkHoldSessionNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _) = makeLiveOverlaySession(clock: clock)
        viewModel.shortcuts.hasActivePushToTalkShortcutSession = true
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask, "a held shortcut stops on release")
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testModifierHoldSessionNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _) = makeLiveOverlaySession(clock: clock)
        viewModel.shortcuts.isModifierOnlyHoldActive = true
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testLiveAutoPasteNeverArms() {
        let clock = ManualSessionClock()
        let (viewModel, _) = makeLiveOverlaySession(clock: clock, outputMode: .liveAutoPaste)
        viewModel.session.armSilenceAutoStopIfEnabled()

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testAManualStopDisarmsTheWatch() async {
        let clock = ManualSessionClock()
        let (viewModel, overlay) = makeLiveOverlaySession(clock: clock)
        viewModel.session.armSilenceAutoStopIfEnabled()
        let watch = viewModel.session.silenceAutoStopTask
        await clock.waitForSleepers(1)

        viewModel.session.stopDictation(reason: "manual toggle")
        await watch?.value

        XCTAssertNil(viewModel.session.silenceAutoStopTask)
        XCTAssertEqual(overlay.beginFinalizingCalls.count, 1, "only the manual stop ran")
    }

    func testSettingPersistsAndDefaultsOff() {
        let defaults = makeSettingsDefaults()
        XCTAssertEqual(makeSettings(defaults: defaults).overlayBufferSilenceAutoStop, .off)
        makeSettings(defaults: defaults).overlayBufferSilenceAutoStop = .after15
        XCTAssertEqual(makeSettings(defaults: defaults).overlayBufferSilenceAutoStop, .after15)
    }
}
