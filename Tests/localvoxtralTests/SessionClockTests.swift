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
        clock.advance(by: TimingConstants.microphonePermissionPromptTimeout - 0.1)
        XCTAssertEqual(clock.pendingSleepers, 1)
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission)

        clock.advance(by: 0.1)
        await promptTimeout?.value

        XCTAssertFalse(viewModel.isAwaitingMicrophonePermission)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    /// Push-to-talk held on first use, released while the prompt is up, and
    /// the prompt left unanswered past its timeout: the attempt is over, so
    /// a grant that lands afterwards must not start a session the user is
    /// no longer holding the key for.
    func testAGrantAfterThePromptTimedOutStartsNothing() async {
        let clock = ManualSessionClock()
        let microphone = FakeMicrophoneCaptureService()
        microphone.authorization = .notDetermined
        let viewModel = makeViewModel(clock: clock, microphone: microphone)
        viewModel.settings.dictationShortcutMode = .pushToTalk

        viewModel.shortcuts.handleDictationShortcutPress()
        viewModel.shortcuts.handleDictationShortcutRelease()
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission)
        let promptTimeout = viewModel.session.microphonePermissionTimeoutTask

        await clock.waitForSleepers(1)
        clock.advance(by: TimingConstants.microphonePermissionPromptTimeout)
        await promptTimeout?.value
        XCTAssertFalse(viewModel.isAwaitingMicrophonePermission, "the prompt timed out")

        microphone.resolvePendingAccess(granted: true)
        // The grant queues its main-actor hop before this barrier, and
        // same-priority jobs run FIFO: once the barrier runs, the hop has.
        await Task { @MainActor in }.value

        XCTAssertFalse(viewModel.isConnectingRealtimeSession, "the expired attempt must not connect")
        XCTAssertNil(viewModel.session.managedStartupTask, "nor begin startup")
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(microphone.startCount, 0, "nor capture audio")
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    /// A second prompt cancels the first prompt's timeout, and a cancelled
    /// sleep returns at once: that timeout must not then clear the second
    /// prompt's flag (GLM's review of this step).
    func testACancelledPromptTimeoutLeavesTheNewerPromptAlone() async {
        let clock = ManualSessionClock()
        let microphone = FakeMicrophoneCaptureService()
        microphone.authorization = .notDetermined
        let viewModel = makeViewModel(clock: clock, microphone: microphone)

        viewModel.startDictation()
        let firstTimeout = viewModel.session.microphonePermissionTimeoutTask
        await clock.waitForSleepers(1)
        // Declined: the flag drops, and the authorization stays notDetermined.
        await awaitNextWrite(of: { viewModel.statusText }) {
            microphone.resolvePendingAccess(granted: false)
        }
        XCTAssertFalse(viewModel.isAwaitingMicrophonePermission)

        viewModel.startDictation()
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission, "a second prompt is up")
        await firstTimeout?.value

        XCTAssertTrue(
            viewModel.isAwaitingMicrophonePermission,
            "the first prompt's cancelled timeout must not clear the second prompt"
        )
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.requestingMicrophonePermission)
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

    /// Only the bundled helper serves one connection at a time.
    func testOnlyAMemoOnTheBundledHelperYieldsToADictationThere() {
        XCTAssertTrue(DictationViewModel.voiceMemoSharesTheEngine(memo: .managedLocal, dictation: .managedLocal))
        XCTAssertFalse(DictationViewModel.voiceMemoSharesTheEngine(memo: .managedLocal, dictation: .mistralAPI))
        XCTAssertFalse(DictationViewModel.voiceMemoSharesTheEngine(memo: .externalURL, dictation: .managedLocal))
        XCTAssertFalse(DictationViewModel.voiceMemoSharesTheEngine(memo: .externalURL, dictation: .externalURL))
        XCTAssertFalse(DictationViewModel.voiceMemoSharesTheEngine(memo: nil, dictation: .managedLocal))
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

    /// The managed helper gets 90 ms, then 80 ms appends, each sent once the
    /// mic has captured it, whatever the mic's buffer size (#1670).
    func testAlignedSendLoopCutsTheAudioOnTheHelpersStepBoundaries() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        let buffer = viewModel.audio.audioChunkBuffer

        viewModel.audio.restartAudioSendTask(
            client: client, debugLoggingEnabled: false,
            alignedToSpeechHelperSteps: true, sleep: clock.clock.sleep
        )
        // 512 frames at 48 kHz come out as about 171 samples (342 bytes).
        var sends: [Int] = []
        for _ in 0..<16 {
            await clock.waitForSleepers(1)
            buffer.append(Data(count: 342))
            clock.advance(by: 0.0107)
            await clock.waitForSleepers(1)
            if client.sentAudioBytes > sends.reduce(0, +) {
                sends.append(client.sentAudioBytes - sends.reduce(0, +))
            }
        }

        XCTAssertEqual(sends, [2_880, 2_560], "90 ms, then 80 ms")
        viewModel.audio.cancelSendAndCommitTasks()
    }

    /// A socket that dies after the tick read it connected drops the chunk;
    /// the chunk stays buffered, ahead of later audio, for the reconnect to
    /// replay (#1458).
    func testAChunkTheClientDropsStaysBufferedAheadOfLaterAudio() async {
        let clock = ManualSessionClock()
        let viewModel = makeViewModel(clock: clock)
        let client = FakeRealtimeClient()
        client.setConnected(true)
        client.setRefusesAudio(true)
        let buffer = viewModel.audio.audioChunkBuffer
        buffer.append(Data(repeating: 1, count: 320))

        viewModel.audio.restartAudioSendTask(
            client: client, debugLoggingEnabled: false, sleep: clock.clock.sleep
        )
        await clock.waitForSleepers(1)
        clock.advance(by: TimingConstants.audioSendInterval)
        await clock.waitForSleepers(1)
        viewModel.audio.cancelSendAndCommitTasks()
        buffer.append(Data(repeating: 2, count: 320))

        XCTAssertEqual(client.sentAudioBytes, 0)
        XCTAssertEqual(
            buffer.takeAll(), Data(repeating: 1, count: 320) + Data(repeating: 2, count: 320),
            "the dropped chunk was lost")
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
