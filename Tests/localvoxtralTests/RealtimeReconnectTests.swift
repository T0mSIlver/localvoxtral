import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// Mid-dictation reconnect (#380): a realtime socket that drops on its own
/// retries on a bounded backoff instead of ending the dictation.
///
/// Every run here is driven through the injected sleep seam
/// (`debugReconnectSleepOverride`), so the suite waits on no wall clock and a
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
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = "world"
        viewModel.livePartialText = "world"
        // Audio the user spoke that the send loop had not drained yet.
        viewModel.audioChunkBuffer.append(Data(count: 3_200))

        // The socket opens on the first poll of the first attempt.
        viewModel.debugReconnectSleepOverride = { _ in client.setConnected(true) }

        viewModel.handle(event: .disconnected)

        XCTAssertTrue(viewModel.isDictating, "the session must survive the drop")
        XCTAssertTrue(viewModel.isReconnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)

        await viewModel.reconnectTask?.value

        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
        XCTAssertTrue(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Listening...")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .connected)
        XCTAssertEqual(client.connectCount, 1)
        XCTAssertNotNil(viewModel.audioSendTask, "the audio send loop must resume")
        XCTAssertNotNil(viewModel.commitTask, "the periodic commit must resume")
        XCTAssertEqual(
            viewModel.audioChunkBuffer.bufferedByteCount, 3_200,
            "the audio spoken into the gap waits for the restarted send loop to replay it"
        )
        XCTAssertEqual(
            viewModel.currentDictationEventText, "hello\nworld",
            "the transcript must carry across the gap, dangling partial included"
        )
        XCTAssertTrue(viewModel.pendingSegmentText.isEmpty)
    }

    func testReconnectDialsTheConfigurationTheSessionStartedOn() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let started = viewModel.sessionRealtimeConfiguration
        // Settings move on mid-dictation. The reconnect must ignore them, or a
        // backend flip would send this session's audio — and its bearer token —
        // somewhere it never agreed to go.
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:9/elsewhere"

        viewModel.debugReconnectSleepOverride = { _ in client.setConnected(true) }
        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertEqual(client.connectConfigurations.count, 1)
        XCTAssertEqual(client.connectConfigurations.first?.endpoint, started?.endpoint)
        XCTAssertEqual(client.connectConfigurations.first?.model, started?.model)
        XCTAssertEqual(client.connectConfigurations.first?.apiKey, started?.apiKey)
    }

    func testReconnectNeverCommitsAcrossTheGap() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { _ in client.setConnected(true) }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

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
        viewModel.handle(event: .partialTranscript("hello"))
        viewModel.handle(event: .finalTranscript("hello"))
        viewModel.handle(event: .partialTranscript(" world"))
        XCTAssertEqual(insertedChunks, ["hello", " world"])

        viewModel.debugReconnectSleepOverride = { _ in client.setConnected(true) }
        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertEqual(insertedChunks, ["hello", " world"], "the reconnect itself types nothing")
        XCTAssertEqual(viewModel.currentDictationEventText, "hello\nworld")
        XCTAssertTrue(viewModel.pendingSegmentText.isEmpty)
        XCTAssertTrue(viewModel.livePartialText.isEmpty)

        // The reconnected backend starts with an empty transcript of its own,
        // so its stream is new text and lands exactly once.
        viewModel.handle(event: .partialTranscript(" again"))
        viewModel.handle(event: .finalTranscript(" again"))

        XCTAssertEqual(insertedChunks, ["hello", " world", " again"])
        XCTAssertEqual(viewModel.currentDictationEventText, "hello\nworld\nagain")
    }

    func testAttemptsRetryUntilOneConnects() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        // Fail the first two attempts the way a refused socket does, then let
        // the third one open.
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel else { return }
            if client.connectCount >= 3 {
                client.setConnected(true)
            } else if client.connectCount > 0 {
                viewModel.handle(event: .error("WebSocket failed: refused"))
            }
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

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
        viewModel.debugReconnectSleepOverride = { _ in client.setConnected(true) }

        viewModel.handle(event: .disconnected)
        XCTAssertTrue(viewModel.isReconnectingRealtimeSession)
        await viewModel.reconnectTask?.value
        await viewModel.audioDucking.debugFadeTask?.value

        XCTAssertTrue(viewModel.isDictating, "precondition: the session survived")
        XCTAssertTrue(
            volume.writes.isEmpty,
            "a session that keeps going keeps its duck — no volume moved across the gap")
        XCTAssertNotNil(
            viewModel.audioDucking.debugDuckedOutput,
            "and the way back is still held for the eventual stop")
    }

    func testAnExhaustedReconnectRestoresOtherAudio() async throws {
        // The end of the line. This is the teardown that must not leave the
        // user at a fifth of their volume with no dictation running.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        let volume = await duckedVolumeControl(for: viewModel)
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value
        await viewModel.audioDucking.debugFadeTask?.value

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
        viewModel.audioDucking = AudioDuckingController(
            volumeControl: volume,
            isEnabled: { true },
            fadeDuration: { 0 },
            now: { pinnedNow },
            sleepFor: { _ in }
        )
        viewModel.audioDucking.duckForSessionStart()
        await viewModel.audioDucking.debugFadeTask?.value
        return volume
    }

    // MARK: - Reconnect exhausts

    func testExhaustedReconnectLandsOnTodaysConnectionLostBehavior() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.currentDictationEventText = "hello"
        let escapeStopsBefore = EscapeCancelHandler.stopCallCount
        // Every attempt's socket reports back a failure.
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
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

    func testAnExhaustedRunsOwnClosingSocketDoesNotClearTheFailureIndicator() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.handle(event: .error("WebSocket failed: refused"))
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        // The `disconnect()` the exhaustion fired reaches the handler late.
        viewModel.handle(event: .disconnected)

        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testDropWithNoLatchedConfigurationStopsImmediately() {
        // Nothing to dial: this drop is not recoverable, so the session takes
        // the pre-#380 path in one step.
        let (viewModel, _) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.sessionRealtimeConfiguration = nil

        viewModel.handle(event: .disconnected)

        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
        XCTAssertNil(viewModel.reconnectTask)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
    }

    // MARK: - The user stops during a reconnect

    func testStopDuringAReconnectEndsItAndStopsDialing() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, viewModel.isDictating else { return }
            viewModel.stopDictation(reason: "manual toggle")
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
        XCTAssertEqual(client.connectCount, 0, "a stopped run must not dial again")
        XCTAssertNotEqual(viewModel.statusText, "Listening...")
    }

    func testASocketThatOpensAfterTheUserCancelledDoesNotResurrectTheSession() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        // Escape lands inside the first attempt; the socket opens a moment too
        // late. The run must notice it no longer owns the session.
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel else { return }
            if viewModel.isDictating {
                viewModel.cancelDictation()
            }
            client.setConnected(true)
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertFalse(viewModel.isDictating, "a cancelled session must stay cancelled")
        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
        XCTAssertNotEqual(viewModel.statusText, "Listening...")
        XCTAssertNil(viewModel.audioSendTask, "no audio may resume after the cancel")
        XCTAssertEqual(client.commits, [], "the cancel must not commit the gap audio")
    }

    func testCancellingARunStopsItBeforeItDials() async {
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { _ in }

        viewModel.handle(event: .disconnected)
        XCTAssertTrue(viewModel.isReconnectingRealtimeSession)
        let task = viewModel.reconnectTask

        viewModel.cancelRealtimeReconnect()
        await task?.value

        XCTAssertFalse(viewModel.isReconnectingRealtimeSession)
        XCTAssertEqual(client.connectCount, 0)
    }

    // MARK: - Nothing outlives the run (Codex review of #415)

    func testCancellingARunClosesTheSocketItsAttemptOpened() async {
        // The task cancel does not cancel the socket. Left open, an attempt
        // still in `connecting` could open after the stop and transmit the
        // audio the stop flushed into its pending queue.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            viewModel.stopDictation(reason: "manual toggle")
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

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
        viewModel.debugReconnectSleepOverride = { [weak viewModel] _ in
            guard let viewModel, client.connectCount > 0 else { return }
            client.setConnected(true)
            viewModel.handle(event: .error("session rejected while the socket stayed open"))
        }

        viewModel.handle(event: .disconnected)
        await viewModel.reconnectTask?.value

        XCTAssertEqual(client.connectCount, RealtimeReconnectPolicy.default.maxAttempts)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.connectionLostMessage)
    }

    func testATranscriptFromTheDyingSocketIsNotTypedAgainDuringAReconnect() async {
        // The socket's receive callback can pass its own state check and emit
        // a final AFTER the drop was handled and its partial promoted. Typed
        // again, it would duplicate in the field — there are no backspaces.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .liveAutoPaste)
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { [weak self] chunk in
                self?.insertedChunks.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
        viewModel.handle(event: .partialTranscript("hello world"))
        XCTAssertEqual(insertedChunks, ["hello world"])

        viewModel.debugReconnectSleepOverride = { _ in }
        viewModel.handle(event: .disconnected)
        let task = viewModel.reconnectTask

        // The straggler: the same words, arriving as a final after promotion.
        viewModel.handle(event: .finalTranscript("hello world"))

        XCTAssertEqual(insertedChunks, ["hello world"], "the straggler must not be typed again")
        XCTAssertEqual(viewModel.currentDictationEventText, "hello world")
        XCTAssertEqual(viewModel.transcriptText, "hello world")

        viewModel.cancelRealtimeReconnect()
        await task?.value
    }

    func testADropReportedByARetiredSocketLeavesALiveSessionAlone() {
        // Events carry no connection identity, so a `.disconnected` from a
        // socket the session already replaced must be judged by the live
        // client's own state.
        let (viewModel, client) = makeDictatingViewModel(outputMode: .overlayBuffer)
        client.setConnected(true)

        viewModel.handle(event: .disconnected)

        XCTAssertTrue(viewModel.isDictating, "a live session must not be torn down")
        XCTAssertFalse(
            viewModel.isReconnectingRealtimeSession,
            "nor reconnected — its socket is up"
        )
        XCTAssertNil(viewModel.reconnectTask)
    }

    // MARK: - Status line ownership

    func testStatusAndTranscriptEventsDoNotClobberReconnectingText() async {
        let (viewModel, _) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { _ in }

        viewModel.handle(event: .disconnected)
        let task = viewModel.reconnectTask
        viewModel.handle(event: .status("session.created"))
        viewModel.handle(event: .partialTranscript("stray"))

        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)
        XCTAssertTrue(
            viewModel.pendingSegmentText.isEmpty,
            "a transcript arriving mid-run belongs to a socket the session left behind"
        )

        viewModel.cancelRealtimeReconnect()
        await task?.value
    }

    func testTheSocketErrorBehindTheDropIsNotLeftStandingAsAnError() async {
        let (viewModel, _) = makeDictatingViewModel(outputMode: .overlayBuffer)
        viewModel.debugReconnectSleepOverride = { _ in }

        viewModel.handle(event: .error("WebSocket receive failed: [NSPOSIXErrorDomain:57]"))
        viewModel.handle(event: .disconnected)
        let task = viewModel.reconnectTask

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.reconnecting)

        viewModel.cancelRealtimeReconnect()
        await task?.value
    }

    // MARK: - Fixtures

    private var insertedChunks: [String] = []

    private func makeDictatingViewModel(
        outputMode: DictationOutputMode
    ) -> (DictationViewModel, FakeReconnectRealtimeClient) {
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

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        // Session start reads config through the store — never the real config
        // directory.
        viewModel.appConfigStore = ReconnectHermeticConfigStore()
        // Any test reaching a session teardown arms the real connect-timeout
        // alert on a process-retained view model; suppress it or it fires
        // inside whatever test runs ~10 s later.
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let client = FakeReconnectRealtimeClient()
        viewModel.activeRealtimeClient = client
        viewModel.isDictating = true
        viewModel.sessionOutputMode = outputMode
        viewModel.sessionRealtimeConfiguration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://127.0.0.1:8000/v1/realtime")!,
            apiKey: "session-key",
            model: "session-model"
        )
        return (viewModel, client)
    }
}

/// A realtime client that opens no socket: every connect, commit and audio send
/// is recorded, and the test decides when `isConnected` flips.
private final class FakeReconnectRealtimeClient: RealtimeClient, @unchecked Sendable {
    private struct State {
        var isConnected = false
        var connectCount = 0
        var disconnectCount = 0
        var connectConfigurations: [RealtimeSessionConfiguration] = []
        var commits: [Bool] = []
        var sentAudioBytes = 0
        var handler: (@Sendable (RealtimeEvent) -> Void)?
    }

    private let state = Mutex(State())

    var supportsPeriodicCommit: Bool { true }
    var isConnected: Bool { state.withLock { $0.isConnected } }
    var connectCount: Int { state.withLock { $0.connectCount } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }
    var commits: [Bool] { state.withLock { $0.commits } }
    var sentAudioBytes: Int { state.withLock { $0.sentAudioBytes } }
    var connectConfigurations: [RealtimeSessionConfiguration] {
        state.withLock { $0.connectConfigurations }
    }

    func setConnected(_ connected: Bool) {
        state.withLock { $0.isConnected = connected }
    }

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeEvent) -> Void) {
        state.withLock { $0.handler = handler }
    }

    func connect(configuration: RealtimeSessionConfiguration) throws {
        state.withLock {
            $0.connectCount += 1
            $0.connectConfigurations.append(configuration)
        }
    }

    func disconnect() {
        state.withLock {
            $0.disconnectCount += 1
            $0.isConnected = false
        }
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        state.withLock { $0.sentAudioBytes += pcm16Data.count }
    }

    func sendCommit(final: Bool) {
        state.withLock { $0.commits.append(final) }
    }
}

private final class ReconnectHermeticConfigStore: AppConfigServing {
    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        ReplacementDictionary(entries: [])
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
    }
}
