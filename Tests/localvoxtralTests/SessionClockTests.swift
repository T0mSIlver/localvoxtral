import XCTest
@testable import localvoxtral

/// Every timer a session arms sleeps on `Dependencies.clock`. Each test here
/// advances a `ManualSessionClock` to just short of a deadline, sees nothing
/// happen, then to the deadline, and sees the timer fire. No test in this
/// file waits on the wall clock.
@MainActor
final class SessionClockTests: XCTestCase {
    private func makeViewModel(
        clock: ManualSessionClock,
        presenter: RecordingConnectionFailurePresenter = RecordingConnectionFailurePresenter(),
        microphone: FakeMicrophoneCaptureService? = nil
    ) -> DictationViewModel {
        let viewModel = DictationViewModel(
            settings: makeSettings(outputMode: .overlayBuffer),
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(
                microphone: microphone.map { microphone in { microphone } },
                connectionFailurePresenter: presenter,
                clock: clock.clock
            )
        )
        retainForTestProcessLifetime(viewModel)
        return viewModel
    }

    func testConnectTimeoutWaitsForTheClockThenTheSocketErrorGrace() async {
        let clock = ManualSessionClock()
        let presenter = RecordingConnectionFailurePresenter()
        let viewModel = makeViewModel(clock: clock, presenter: presenter)
        viewModel.isConnectingRealtimeSession = true
        viewModel.session.scheduleConnectTimeout()
        let timeoutTask = viewModel.session.connectTimeoutTask

        await clock.waitForSleepers(1)
        clock.advance(by: TimingConstants.connectTimeout - 0.01)
        XCTAssertEqual(clock.pendingSleepers, 1, "one hundredth short, the timeout has not fired")
        XCTAssertTrue(viewModel.isConnectingRealtimeSession)

        clock.advance(by: 0.01)
        await clock.waitForSleepers(1)
        XCTAssertTrue(
            viewModel.isConnectingRealtimeSession,
            "the timeout first waits out the socket-error grace, on the same clock"
        )

        clock.advance(by: TimingConstants.connectTimeoutSocketErrorGrace)
        await timeoutTask?.value

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connection timed out.")
        XCTAssertEqual(presenter.presented.count, 1, "the failure reaches the presenter")
    }

    func testMicrophonePromptTimeoutRunsOnTheClock() async {
        let clock = ManualSessionClock()
        let microphone = FakeMicrophoneCaptureService()
        microphone.authorization = .notDetermined
        let viewModel = makeViewModel(clock: clock, microphone: microphone)

        viewModel.startDictation()
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission)
        XCTAssertEqual(microphone.pendingAccessRequestCount, 1, "the prompt is up and nobody answers")
        let promptTimeout = viewModel.session.microphonePermissionTimeoutTask

        await clock.waitForSleepers(1)
        clock.advance(by: 119.9)
        XCTAssertEqual(clock.pendingSleepers, 1)
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission)

        clock.advance(by: 0.1)
        await promptTimeout?.value

        XCTAssertFalse(viewModel.isAwaitingMicrophonePermission)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    func testRecentFailureIndicatorResetsWhenTheClockSaysSo() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)

        viewModel.session.markRecentConnectionFailureIndicator()
        let resetTask = viewModel.session.recentFailureResetTask
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)

        await clock.waitForSleepers(1)
        clock.advance(by: TimingConstants.recentFailureIndicatorDuration - 0.01)
        XCTAssertEqual(clock.pendingSleepers, 1)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)

        clock.advance(by: 0.01)
        await resetTask?.value

        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
    }

    func testFinalizationWatchdogPollsOnTheClock() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        viewModel.isFinalizingStop = true
        viewModel.session.sessionOutputMode = .liveAutoPaste

        viewModel.session.startStopFinalizationWatchdog()
        let watchdog = viewModel.session.finalizationWatchdogTask

        await clock.waitForSleepers(1)
        XCTAssertTrue(viewModel.isFinalizingStop, "no poll has run before the first interval")

        clock.advance(by: TimingConstants.finalizationPollInterval)
        await watchdog?.value

        XCTAssertFalse(
            viewModel.isFinalizingStop,
            "the first poll finds no socket and finishes the stop"
        )
    }

    func testStopFinalizationClosesAnIdleSocketOnTheClock() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        viewModel.session.activeRealtimeClient = client
        viewModel.isFinalizingStop = true
        viewModel.session.sessionOutputMode = .liveAutoPaste

        viewModel.session.scheduleStopFinalization()
        let finalization = viewModel.session.stopFinalizationTask

        // The socket stays silent, so the poll closes it at the first poll
        // that finds it open for the minimum AND idle for the threshold.
        // Counted the way the clock adds time, one interval at a time, so the
        // count carries the same floating-point sums the production check sees.
        var elapsed: TimeInterval = 0
        var polls = 0
        repeat {
            polls += 1
            elapsed += TimingConstants.finalizationPollInterval
        } while elapsed < TimingConstants.finalizationMinimumOpen
            || elapsed < TimingConstants.finalizationInactivityThreshold
        for _ in 0..<(polls - 1) {
            await clock.waitForSleepers(1)
            clock.advance(by: TimingConstants.finalizationPollInterval)
        }
        await clock.waitForSleepers(1)
        XCTAssertEqual(client.disconnectCount, 0, "one poll short, the socket is still open")
        XCTAssertTrue(viewModel.isFinalizingStop)

        clock.advance(by: TimingConstants.finalizationPollInterval)
        await finalization?.value

        XCTAssertEqual(client.commits, [true], "the final commit went out once, at the start")
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertFalse(viewModel.isFinalizingStop)
    }

    func testAudioSendLoopDrainsTheBufferOnTheClock() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        viewModel.audio.audioChunkBuffer.append(Data(count: 320))

        viewModel.audio.restartAudioSendTask(
            client: client, debugLoggingEnabled: false, sleep: clock.clock.sleep
        )
        await clock.waitForSleepers(1)
        XCTAssertEqual(client.sentAudioBytes, 0)

        clock.advance(by: TimingConstants.audioSendInterval)
        await clock.waitForSleepers(1)
        XCTAssertEqual(client.sentAudioBytes, 320, "one tick sends what was buffered")

        viewModel.audio.cancelSendAndCommitTasks()
    }

    func testPeriodicCommitLoopCommitsOnTheClock() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        let client = FakeRealtimeClient()

        viewModel.audio.restartCommitTask(client: client, sleep: clock.clock.sleep)
        await clock.waitForSleepers(1)
        clock.advance(by: TimingConstants.commitInterval - 0.01)
        XCTAssertEqual(client.commits, [])

        clock.advance(by: 0.01)
        await clock.waitForSleepers(1)
        XCTAssertEqual(client.commits, [false], "one interval, one partial commit")

        viewModel.audio.cancelSendAndCommitTasks()
    }
}
