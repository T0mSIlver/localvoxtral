import Foundation
import Synchronization
import XCTest

import localvoxtralTestSupport
@testable import localvoxtral

/// Mid-dictation reconnect (#380): a realtime socket that drops on its own
/// retries on a bounded backoff instead of ending the dictation.
///
/// Every run here is driven through the injected sleep seam
/// (`dependencies.reconnectSleep`), so the suite waits on no wall clock and a
/// stop can be landed at an exact point inside an attempt.
@MainActor
final class RealtimeReconnectTests: XCTestCase {
    // MARK: - Policy

    func testBackoffGrowsAndIsCapped() {
        let policy = RealtimeReconnectPolicy.default
        let waits = (1...policy.maxAttempts).map { policy.backoff(beforeAttempt: $0) }

        XCTAssertEqual(waits.first, policy.initialBackoff)
        for (earlier, later) in zip(waits, waits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier, "backoff must not shrink")
        }
        XCTAssertTrue(
            waits.allSatisfy { $0 <= policy.maxBackoff },
            "no wait may exceed the cap, got \(waits)"
        )
    }

    func testTheAudioBufferOutlastsTheWorstCaseRun() {
        // The replay promise only holds if the gap fits in the buffer: a run
        // that reconnects within its cap must never have dropped audio.
        XCTAssertGreaterThan(
            Double(AudioChunkBuffer.maxRetainedSeconds),
            RealtimeReconnectPolicy.default.worstCaseDuration
        )
    }

    // MARK: - Audio buffer retention

    func testBufferKeepsTheMostRecentAudioWhenItOverflows() {
        let buffer = AudioChunkBuffer(maxRetainedBytes: 8)
        buffer.append(Data([1, 2, 3, 4, 5, 6]))
        buffer.append(Data([7, 8, 9, 10, 11, 12]))

        XCTAssertEqual(buffer.bufferedByteCount, 8)
        XCTAssertEqual(Array(buffer.takeAll()), [5, 6, 7, 8, 9, 10, 11, 12])
    }

    func testBufferTrimsOnSampleBoundariesSoPCM16DoesNotShift() {
        // An odd retention limit must round DOWN to an even byte count, or
        // every sample after a trim is read a byte out of phase.
        let buffer = AudioChunkBuffer(maxRetainedBytes: 5)
        buffer.append(Data([1, 2, 3, 4, 5, 6, 7, 8]))

        XCTAssertEqual(buffer.bufferedByteCount, 4)
        XCTAssertEqual(Array(buffer.takeAll()), [5, 6, 7, 8])
    }

    // MARK: - Reconnect succeeds

    func testDropMidDictationReconnectsAndDictationContinues() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.transcript.currentDictationEventText = "hello"
        viewModel.transcript.pendingSegmentText = "world"
        viewModel.transcript.livePartialText = "world"
        // Audio the user spoke that the send loop had not drained yet.
        viewModel.audio.audioChunkBuffer.append(Data(count: 3_200))

        // The socket opens on the first poll of the first attempt.
        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }

        viewModel.session.handle(event: .disconnected)

        XCTAssertTrue(viewModel.isDictating, "the session must survive the drop")
        XCTAssertTrue(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)

        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertTrue(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Listening...")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .connected)
        XCTAssertEqual(client.connectCount, 1)
        XCTAssertNotNil(viewModel.audio.audioSendTask, "the audio send loop must resume")
        XCTAssertNotNil(viewModel.audio.commitTask, "the periodic commit must resume")
        XCTAssertEqual(
            viewModel.audio.audioChunkBuffer.bufferedByteCount, 3_200,
            "the audio spoken into the gap waits for the restarted send loop to replay it"
        )
        XCTAssertEqual(
            viewModel.transcript.currentDictationEventText, "hello world",
            "the transcript must carry across the gap, dangling partial included"
        )
        XCTAssertTrue(viewModel.transcript.pendingSegmentText.isEmpty)
    }

    func testReconnectDialsTheConfigurationTheSessionStartedOn() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let started = viewModel.session.sessionRealtimeConfiguration
        // Settings move on mid-dictation. The reconnect must ignore them, or a
        // backend flip would send this session's audio — and its bearer token —
        // somewhere it never agreed to go.
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:9/elsewhere"

        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectConfigurations.count, 1)
        XCTAssertEqual(client.connectConfigurations.first?.endpoint, started?.endpoint)
        XCTAssertEqual(client.connectConfigurations.first?.model, started?.model)
        XCTAssertEqual(client.connectConfigurations.first?.apiKey, started?.apiKey)
    }

    func testReconnectNeverCommitsAcrossTheGap() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(
            client.commits, [],
            "a reconnect must not commit — the far side has no audio buffer to commit"
        )
    }

    func testReconnectInLiveAutoPasteDoesNotRetypeWhatWasAlreadyTyped() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { [weak self] chunk in
                self?.insertedChunks.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        // "hello" is finalized; "world" is a partial the live path already
        // typed and the dying session will never finalize.
        viewModel.session.handle(event: .partialTranscript("hello"))
        viewModel.session.handle(event: .finalTranscript("hello"))
        viewModel.session.handle(event: .partialTranscript(" world"))
        XCTAssertEqual(insertedChunks, ["hello", " world"])

        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(insertedChunks, ["hello", " world"], "the reconnect itself types nothing")
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "hello world")
        XCTAssertTrue(viewModel.transcript.pendingSegmentText.isEmpty)
        XCTAssertTrue(viewModel.transcript.livePartialText.isEmpty)

        // The reconnected backend starts with an empty transcript of its own,
        // so its stream is new text and lands exactly once.
        viewModel.session.handle(event: .partialTranscript(" again"))
        viewModel.session.handle(event: .finalTranscript(" again"))

        XCTAssertEqual(insertedChunks, ["hello", " world", " again"])
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "hello world again")
    }

    /// The reconnected backend starts a fresh transcript, whose first word
    /// carries no space: typed as is, it would run into the last one (#1364).
    func testReconnectAddsBoundaryBeforeUnprefixedNewSentence() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        recordInsertions(into: viewModel)

        viewModel.session.handle(event: .partialTranscript("First sentence."))
        viewModel.session.handle(event: .finalTranscript("First sentence."))

        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        viewModel.session.handle(event: .partialTranscript("Second"))
        viewModel.session.handle(event: .partialTranscript(" sentence."))
        viewModel.session.handle(event: .finalTranscript("Second sentence."))

        XCTAssertEqual(insertedChunks, ["First sentence.", " Second", " sentence."])
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "First sentence. Second sentence.")
    }

    /// The same boundary when the new session's first text is a final with
    /// no partial before it (#1218).
    func testReconnectAddsBoundaryBeforeAFinalOnlyNewSentence() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        recordInsertions(into: viewModel)

        viewModel.session.handle(event: .partialTranscript("First sentence."))
        viewModel.session.handle(event: .finalTranscript("First sentence."))

        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        viewModel.session.handle(event: .finalTranscript("Second sentence."))

        XCTAssertEqual(insertedChunks, ["First sentence.", " Second sentence."])
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "First sentence. Second sentence.")
    }

    func testAttemptsRetryUntilOneConnects() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        // Fail the first two attempts the way a refused socket does, then let
        // the third one open.
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel else { return }
            if client.connectCount >= 3 {
                client.setConnected(true)
            } else if client.connectCount > 0 {
                viewModel.session.handle(event: .error("WebSocket failed: refused"))
            }
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, 3)
        XCTAssertTrue(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Listening...")
    }

    // MARK: - Audio ducking across the gap (#375 x #415)

    func testAReconnectKeepsOtherAudioDucked() async {
        // The whole point of reconnecting is that the user never notices the
        // blip. Fading their music back up mid-sentence and down again would
        // announce it louder than the dropout did.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let volume = await duckedVolumeControl(for: viewModel)
        volume.clearWrites()
        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }

        viewModel.session.handle(event: .disconnected)
        XCTAssertTrue(viewModel.session.isReconnectingRealtimeSession)
        await viewModel.session.reconnectTask?.value
        await viewModel.audio.audioDucking.debugFadeTask?.value

        XCTAssertTrue(viewModel.isDictating, "precondition: the session survived")
        XCTAssertTrue(
            volume.writes.isEmpty,
            "a session that keeps going keeps its duck — no volume moved across the gap")
        XCTAssertNotNil(
            viewModel.audio.audioDucking.debugDuckedOutput,
            "and the way back is still held for the eventual stop")
    }

    func testAnExhaustedReconnectRestoresOtherAudio() async throws {
        // The end of the line. This is the teardown that must not leave the
        // user at a fifth of their volume with no dictation running.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let volume = await duckedVolumeControl(for: viewModel)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value
        await viewModel.audio.audioDucking.debugFadeTask?.value

        XCTAssertFalse(viewModel.isDictating, "precondition: the run gave up")
        let restored = try XCTUnwrap(volume.volume(of: "device-a"))
        XCTAssertEqual(
            restored, 0.8, accuracy: 0.0001,
            "the volume the user set comes back when the reconnect does not")
    }

    /// Swaps in a ducking controller over a fake output device and ducks it,
    /// standing in for the duck a real session takes when capture starts.
    /// Fades collapse to a single write: what is under test here is whether a
    /// path restores, not the fade's shape.
    private func duckedVolumeControl(
        for viewModel: DictationViewModel
    ) async -> FakeOutputVolumeControl {
        let volume = FakeOutputVolumeControl(volume: 0.8)
        let pinnedNow = Date(timeIntervalSince1970: 1_000)
        viewModel.audio.audioDucking = AudioDuckingController(
            volumeControl: volume,
            isEnabled: { true },
            fadeDuration: { 0 },
            now: { pinnedNow },
            sleepFor: { _ in }
        )
        viewModel.audio.audioDucking.duckForSessionStart()
        await viewModel.audio.audioDucking.debugFadeTask?.value
        return volume
    }

    // MARK: - Reconnect exhausts

    func testExhaustedReconnectLandsOnTodaysConnectionLostBehavior() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.transcript.currentDictationEventText = "hello"
        let escapeStopsBefore = EscapeCancelHandler.stopCallCount
        // Every attempt's socket reports back a failure.
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
        XCTAssertEqual(viewModel.lastError, DictationViewModel.connectionLostMessage)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertGreaterThan(
            client.disconnectCount, 0,
            "the last half-open socket must be closed, not left to open into a dead session"
        )
        XCTAssertGreaterThan(
            EscapeCancelHandler.stopCallCount, escapeStopsBefore,
            "the exhaustion teardown must disarm the Escape hotkey like every other teardown"
        )
    }

    /// A socket that never comes back ends the dictation, and what it had
    /// transcribed, the partial in flight included, reaches History and
    /// "Copy last dictation" (#526).
    func testAnExhaustedReconnectKeepsWhatWasTranscribed() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        var records: [DictationSessionRecord] = []
        viewModel.dependencies.onSessionRecord = { records.append($0) }
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }
        viewModel.session.handle(event: .finalTranscript("the first half "))
        viewModel.session.handle(event: .partialTranscript("and the"))

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(records.count, 1)
        let copied = viewModel.session.lastDictation?.textToCopy ?? ""
        XCTAssertTrue(copied.hasPrefix("the first half"), copied)
        XCTAssertTrue(copied.hasSuffix("and the"), "the partial in flight survives: \(copied)")
    }

    func testAnExhaustedRunsOwnClosingSocketDoesNotClearTheFailureIndicator() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        // The `disconnect()` the exhaustion fired reaches the handler late.
        viewModel.session.handle(event: .disconnected)

        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testDropWithNoLatchedConfigurationStopsImmediately() {
        // Nothing to dial: this drop is not recoverable, so the session takes
        // the pre-#380 path in one step.
        let (viewModel, _) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.session.sessionRealtimeConfiguration = nil

        viewModel.session.handle(event: .disconnected)

        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertNil(viewModel.session.reconnectTask)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
    }

    // MARK: - The user stops during a reconnect

    /// A stop that skips finalization (a lost network) has no use for the
    /// gap, so it ends the run where it stands.
    func testAStopWithoutFinalizationDuringAReconnectEndsItAndStopsDialing() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, viewModel.isDictating else { return }
            viewModel.stopDictation(reason: "network lost", finalizeRemainingAudio: false)
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertEqual(client.connectCount, 0, "a stopped run must not dial again")
        XCTAssertNotEqual(viewModel.statusText, "Listening...")
    }

    /// The user stops while speechd restarts. The run goes on dialling, the
    /// speech captured since the crash reaches the new server session once,
    /// and the stop's final commit turns it into the end of the dictation
    /// (#1582).
    func testAStopDuringAReconnectReplaysTheGapAndFinalizesIt() async {
        let clock = ManualSessionClock()
        let records = RecordedSessions()
        let (viewModel, client) = makeDictatingViewModel(
            outputMode: .overlayBuffer, clock: clock, records: records)
        viewModel.transcript.currentDictationEventText = "before the crash"
        let gap = Data(repeating: 7, count: 3_200)
        viewModel.audio.audioChunkBuffer.append(gap)
        // No socket takes audio until the reconnect opens one.
        client.setRefusesAudio(true)
        client.setOnCommit { [weak viewModel] final in
            guard final else { return }
            MainActor.assumeIsolated {
                viewModel?.session.handle(event: .finalTranscript("in the gap"))
                viewModel?.session.handle(event: .transcriptionFinalized)
            }
        }
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel else { return }
            if viewModel.isDictating {
                viewModel.stopDictation(reason: "manual toggle")
            } else if client.connectCount > 0 {
                client.setRefusesAudio(false)
                client.setConnected(true)
            }
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value
        await viewModel.session.stopFinalizationTask?.value
        await awaitStoppedSessionCommit(viewModel)

        XCTAssertEqual(client.connectCount, 1, "the stop let the run dial")
        XCTAssertEqual(client.sentAudioBytes, gap.count, "the gap reaches the new session once")
        XCTAssertEqual(client.commits, [true], "one final commit, after the replay")
        XCTAssertEqual(records.all.map(\.rawText), ["before the crash in the gap"])
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    /// The helper never comes back: the stop finishes with the text received
    /// before the crash and says its end may be missing (#1582).
    func testAStopDuringAReconnectThatNeverSucceedsSaysTheEndMayBeMissing() async {
        let clock = ManualSessionClock()
        let records = RecordedSessions()
        let (viewModel, client) = makeDictatingViewModel(
            outputMode: .overlayBuffer, clock: clock, records: records)
        viewModel.transcript.currentDictationEventText = "before the crash"
        viewModel.audio.audioChunkBuffer.append(Data(count: 3_200))
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel else { return }
            if viewModel.isDictating {
                viewModel.stopDictation(reason: "manual toggle")
            } else if client.connectCount > 0 {
                viewModel.session.handle(event: .error("WebSocket failed: refused"))
            }
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value
        await awaitStoppedSessionCommit(viewModel)

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertEqual(records.all.map(\.rawText), ["before the crash"])
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
        XCTAssertEqual(viewModel.lastError, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
    }

    /// The stop waits on the reconnect no longer than a finalization may
    /// take: past it, the stop finishes with what arrived (#1582).
    func testAStopDuringAReconnectGivesUpAtTheFinalizationTimeout() async {
        let clock = ManualSessionClock()
        let records = RecordedSessions()
        let (viewModel, client) = makeDictatingViewModel(
            outputMode: .overlayBuffer, clock: clock, records: records)
        viewModel.transcript.currentDictationEventText = "before the crash"
        // Every attempt hangs: the run outlives the stop's bound.
        let held = BoundedWait()
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel else { return }
            if viewModel.isDictating {
                viewModel.stopDictation(reason: "manual toggle")
                return
            }
            _ = await held.value(failAfter: 10)
        }

        viewModel.session.handle(event: .disconnected)
        // The stop's watchdog is the only timer left on the clock.
        await clock.waitForSleepers(1)
        let watchdog = viewModel.session.finalizationWatchdogTask
        clock.advance(by: TimingConstants.stopFinalizationTimeout)
        await watchdog?.value
        await awaitStoppedSessionCommit(viewModel)
        held.resolve()
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.commits, [])
        XCTAssertEqual(records.all.map(\.rawText), ["before the crash"])
        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
    }

    // MARK: - The bundled helper reloads (#1583)

    /// speechd crashed and takes eight seconds to load its model again, so
    /// every connect meanwhile is refused at once. The run waits on the
    /// helper instead of spending its attempts, and the dictation recovers
    /// with the gap intact.
    func testAReconnectWaitsOutTheBundledHelpersReloadWithoutSpendingAttempts() async {
        let helper = OnboardingTestBackendManager()
        helper.speechdStatus = .starting
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer, backendManager: helper)
        viewModel.session.sessionUsesManagedSpeechHelper = true
        viewModel.audio.audioChunkBuffer.append(Data(count: 3_200))
        let elapsed = VirtualSeconds()
        viewModel.dependencies.reconnectSleep = { [weak viewModel] duration in
            guard let viewModel else { return }
            elapsed.value += duration
            if elapsed.value >= 8 { helper.speechdStatus = .ready }
            guard client.connectCount > 0 else { return }
            if helper.speechdStatus == .ready {
                client.setConnected(true)
            } else {
                viewModel.session.handle(event: .error("WebSocket failed: refused"))
            }
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertTrue(viewModel.isDictating, "the dictation outlives the reload")
        XCTAssertEqual(viewModel.statusText, "Listening...")
        XCTAssertLessThanOrEqual(client.connectCount, 2, "attempts are not spent while the helper starts")
        XCTAssertEqual(
            viewModel.audio.audioChunkBuffer.bufferedByteCount, 3_200,
            "the gap waits for the restarted send loop")
    }

    /// The wait on the helper is bounded: a helper that keeps starting does
    /// not hold the dictation past what the audio buffer can replay.
    func testAReconnectStopsWaitingOnAHelperThatNeverFinishesStarting() async {
        let helper = OnboardingTestBackendManager()
        helper.speechdStatus = .starting
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer, backendManager: helper)
        viewModel.session.sessionUsesManagedSpeechHelper = true
        let elapsed = VirtualSeconds()
        viewModel.dependencies.reconnectSleep = { [weak viewModel] duration in
            guard let viewModel else { return }
            elapsed.value += duration
            guard client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
        XCTAssertLessThan(
            elapsed.value, Double(AudioChunkBuffer.maxRetainedSeconds),
            "the run gives up before the buffer would drop the gap's start")
    }

    /// External URL mode keeps its policy: a server's status is not ours to
    /// wait on.
    func testAnExternalServerReconnectDoesNotWaitOnTheHelper() async {
        let helper = OnboardingTestBackendManager()
        helper.speechdStatus = .starting
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer, backendManager: helper)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.session.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertFalse(viewModel.isDictating)
    }

    func testASocketThatOpensAfterTheUserCancelledDoesNotResurrectTheSession() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        // Escape lands inside the first attempt; the socket opens a moment too
        // late. The run must notice it no longer owns the session.
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel else { return }
            if viewModel.isDictating {
                viewModel.cancelDictation()
            }
            client.setConnected(true)
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating, "a cancelled session must stay cancelled")
        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertNotEqual(viewModel.statusText, "Listening...")
        XCTAssertNil(viewModel.audio.audioSendTask, "no audio may resume after the cancel")
        XCTAssertEqual(client.commits, [], "the cancel must not commit the gap audio")
    }

    func testCancellingARunStopsItBeforeItDials() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { _ in }

        viewModel.session.handle(event: .disconnected)
        XCTAssertTrue(viewModel.session.isReconnectingRealtimeSession)
        let task = viewModel.session.reconnectTask

        viewModel.session.cancelRealtimeReconnect()
        await task?.value

        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession)
        XCTAssertEqual(client.connectCount, 0)
    }

    // MARK: - Nothing outlives the run (Codex review of #415)

    func testCancellingARunClosesTheSocketItsAttemptOpened() async {
        // The task cancel does not cancel the socket. Left open, an attempt
        // still in `connecting` could open after the stop and transmit the
        // audio the stop flushed into its pending queue.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, viewModel.isDictating, client.connectCount > 0 else { return }
            viewModel.stopDictation(reason: "network lost", finalizeRemainingAudio: false)
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, 1, "sanity: an attempt had dialled")
        XCTAssertGreaterThan(
            client.disconnectCount, 0,
            "the cancel must close the socket the attempt left in flight"
        )
    }

    func testAnAttemptWhoseSocketErrorsIsNotCountedAsSuccess() async {
        // A server can accept the upgrade and then reject the session on an
        // open socket: `isConnected` is true on a session that will never
        // transcribe, so the failure signal has to win.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            client.setConnected(true)
            viewModel.session.handle(event: .error("session rejected while the socket stayed open"))
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
    }

    // MARK: - Connection identity (#417)

    func testATranscriptFromTheSocketTheRunLeftBehindIsRefusedWhileItDials() async {
        // The socket's receive callback can pass its own state check and emit
        // a final AFTER the drop was handled and its partial promoted. Typed
        // again, it would duplicate in the field — there are no backspaces.
        let (viewModel, _) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        recordInsertions(into: viewModel)
        let dyingSocket = viewModel.session.sessionConnectionGeneration

        viewModel.session.handle(event: .partialTranscript("hello world"), from: dyingSocket)
        XCTAssertEqual(insertedChunks, ["hello world"])

        viewModel.dependencies.reconnectSleep = { _ in }
        viewModel.session.handle(event: .disconnected, from: dyingSocket)
        let task = viewModel.session.reconnectTask

        XCTAssertEqual(
            viewModel.session.sessionConnectionGeneration, .none,
            "a session whose socket died is on no connection until the next dial"
        )

        // The straggler: the same words, arriving as a final after promotion.
        viewModel.session.handle(event: .finalTranscript("hello world"), from: dyingSocket)

        XCTAssertEqual(insertedChunks, ["hello world"], "the straggler must not be typed again")
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "hello world")
        XCTAssertEqual(viewModel.transcript.transcriptText, "hello world")

        viewModel.session.cancelRealtimeReconnect()
        await task?.value
    }

    func testATranscriptFromTheRetiredSocketIsRefusedOnceTheRunHasReconnected() async {
        // The residual no state-based guard could reach: the run has completed,
        // so its flag is clear, `isDictating` is true and the live client
        // reports connected — every guard that stood in for identity says
        // accept. Only the socket's own name tells the straggler apart.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        recordInsertions(into: viewModel)
        let retiredSocket = viewModel.session.sessionConnectionGeneration

        viewModel.session.handle(event: .partialTranscript("hello world"), from: retiredSocket)
        XCTAssertEqual(insertedChunks, ["hello world"])

        viewModel.dependencies.reconnectSleep = { _ in client.setConnected(true) }
        viewModel.session.handle(event: .disconnected, from: retiredSocket)
        await viewModel.session.reconnectTask?.value

        XCTAssertFalse(viewModel.session.isReconnectingRealtimeSession, "sanity: the run completed")
        XCTAssertTrue(viewModel.isDictating, "sanity: the session is live")
        XCTAssertTrue(client.isConnected, "sanity: so is its socket")
        XCTAssertNotEqual(viewModel.session.sessionConnectionGeneration, retiredSocket)

        viewModel.session.handle(event: .finalTranscript("hello world"), from: retiredSocket)

        XCTAssertEqual(insertedChunks, ["hello world"], "the straggler must not be typed again")
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "hello world")
        XCTAssertEqual(viewModel.transcript.transcriptText, "hello world")

        // And the socket the session IS on is still heard.
        viewModel.session.handle(
            event: .partialTranscript("and on"), from: viewModel.session.sessionConnectionGeneration)
        // Its first word gets the space the fresh transcript lacks (#1364).
        XCTAssertEqual(insertedChunks, ["hello world", " and on"])
    }

    func testADropReportedByARetiredSocketLeavesALiveSessionAlone() {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let retiredSocket = viewModel.session.sessionConnectionGeneration
        viewModel.session.sessionConnectionGeneration = client.stampNewConnection()
        client.setConnected(true)

        viewModel.session.handle(event: .disconnected, from: retiredSocket)

        XCTAssertTrue(viewModel.isDictating, "a live session must not be torn down")
        XCTAssertFalse(
            viewModel.session.isReconnectingRealtimeSession,
            "nor reconnected — its socket is up"
        )
        XCTAssertNil(viewModel.session.reconnectTask)
    }

    // MARK: - Status line ownership

    func testTheReconnectingStatusStandsWhateverTheNewSocketSays() async {
        // The socket an attempt opens is the live connection, so the stamp
        // admits what it says. The run still owns the status line until it ends.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0,
                viewModel.session.isReconnectingRealtimeSession
            else { return }
            viewModel.session.handle(
                event: .status("session.created"), from: viewModel.session.sessionConnectionGeneration)
            XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)
            viewModel.session.cancelRealtimeReconnect()
        }

        viewModel.session.handle(event: .disconnected)
        await viewModel.session.reconnectTask?.value

        XCTAssertEqual(client.connectCount, 1, "sanity: an attempt had dialled")
    }

    func testTheSocketErrorBehindTheDropIsNotLeftStandingAsAnError() async {
        let (viewModel, _) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.dependencies.reconnectSleep = { _ in }

        viewModel.session.handle(event: .error("WebSocket receive failed: [NSPOSIXErrorDomain:57]"))
        viewModel.session.handle(event: .disconnected)
        let task = viewModel.session.reconnectTask

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)

        viewModel.session.cancelRealtimeReconnect()
        await task?.value
    }

    // MARK: - Fixtures

    private var insertedChunks: [String] = []

    /// Route Live Auto-Paste through the test sink instead of the real poster.
    private func recordInsertions(into viewModel: DictationViewModel) {
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { [weak self] chunk in
                self?.insertedChunks.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
    }

    private func makeDictatingViewModel(
        outputMode: DictationOutputMode,
        backendManager: (any ManagedBackendManaging)? = nil,
        clock: ManualSessionClock? = nil,
        records: RecordedSessions? = nil
    ) -> (DictationViewModel, FakeRealtimeClient) {
        let suiteName = "localvoxtral.RealtimeReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        settings.dictationOutputMode = outputMode
        settings.llmPolishingEnabled = false
        settings.realtimeAPIEndpointURL = "ws://127.0.0.1:8000/v1/realtime"

        var dependencies = DictationViewModel.Dependencies()
        if let clock { dependencies.clock = clock.clock }
        if let records { dependencies.onSessionRecord = { records.all.append($0) } }
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: backendManager,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: dependencies
        )
        // Session start reads config through the store — never the real config
        // directory.
        viewModel.appConfigStore = MockAppConfigStore()
        // Any test reaching a session teardown arms the real connect-timeout
        // alert on a process-retained view model; suppress it or it fires
        // inside whatever test runs ~10 s later.
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let client = FakeRealtimeClient()
        viewModel.session.activeRealtimeClient = client
        viewModel.isDictating = true
        // The session starts where a real one does: on the socket its connect
        // opened, with the client and the view model naming the same one.
        viewModel.session.sessionConnectionGeneration = client.stampNewConnection()
        viewModel.session.sessionOutputMode = outputMode
        viewModel.session.sessionRealtimeConfiguration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://127.0.0.1:8000/v1/realtime")!,
            apiKey: "session-key",
            model: "session-model"
        )
        return (viewModel, client)
    }
}

/// Virtual time a test's reconnect sleep seam has handed out.
@MainActor
private final class VirtualSeconds {
    var value: TimeInterval = 0
}

/// Every record the sessions wrote, in order.
@MainActor
private final class RecordedSessions {
    var all: [DictationSessionRecord] = []
}
