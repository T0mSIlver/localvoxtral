import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if DEBUG
final class WebSocketClientLifecycleTests: XCTestCase {
    private final class EventCollector: @unchecked Sendable {
        private var events: [(event: RealtimeEvent, generation: RealtimeConnectionGeneration)] = []
        private let lock = NSLock()

        func append(_ event: RealtimeEvent, from generation: RealtimeConnectionGeneration) {
            lock.lock()
            events.append((event, generation))
            lock.unlock()
        }

        func snapshot() -> [RealtimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events.map(\.event)
        }

        /// The socket each collected event named, in the same order.
        func generations() -> [RealtimeConnectionGeneration] {
            lock.lock()
            defer { lock.unlock() }
            return events.map(\.generation)
        }
    }

    private func makeWebSocketTask() -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "ws://127.0.0.1:65535/test")!
        let task = session.webSocketTask(with: url)
        return (session, task)
    }

    func testRealtimeTerminalErrorCleansSubclassStateAndEmitsErrorThenDisconnected() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        let before = client.debugStateSnapshot()
        XCTAssertTrue(before.isConnected)
        XCTAssertTrue(before.hasPingTimer)
        XCTAssertTrue(before.hasSessionReadyTimer)
        XCTAssertEqual(before.pendingMessageCount, 1)
        XCTAssertTrue(before.hasUncommittedAudio)
        XCTAssertTrue(before.isGenerationInProgress)

        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertFalse(after.hasPingTimer)
        XCTAssertFalse(after.hasSessionReadyTimer)
        XCTAssertEqual(after.pendingMessageCount, 0)
        XCTAssertFalse(after.hasUncommittedAudio)
        XCTAssertFalse(after.isGenerationInProgress)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .error(let message) = events[0] else {
            XCTFail("Expected first event to be .error")
            return
        }
        XCTAssertEqual(message, "socket failed")
        guard case .disconnected = events[1] else {
            XCTFail("Expected second event to be .disconnected")
            return
        }
    }

    func testRealtimeTerminalErrorSuppressesErrorForUserInitiatedDisconnect() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task, isUserInitiatedDisconnect: true)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertFalse(after.hasPingTimer)
        XCTAssertFalse(after.hasSessionReadyTimer)
        XCTAssertEqual(after.pendingMessageCount, 0)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .disconnected = events[0] else {
            XCTFail("Expected only .disconnected for user-initiated disconnect")
            return
        }
    }

    // MARK: - Connection Identity (#417)

    func testConnectStampsAFreshGenerationEvenBeforeASocketOpens() throws {
        // The session reads the stamp back the instant `connect` returns, so it
        // has to be set by then — including on the socketless test path, which
        // is the only way a unit suite ever reaches this call.
        let client = RealtimeAPIWebSocketClient()
        client.debugSkipSocketCreationForTesting()
        XCTAssertEqual(client.connectionGeneration, .none)

        let configuration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://127.0.0.1:65535/v1/realtime")!,
            apiKey: "k",
            model: "m"
        )
        try client.connect(configuration: configuration)
        let first = client.connectionGeneration
        XCTAssertNotEqual(first, .none)

        try client.connect(configuration: configuration)
        XCTAssertNotEqual(client.connectionGeneration, first, "a redial is a new connection")
    }

    func testTheTwoClientsNeverShareAGeneration() throws {
        // Both report into one handler, so a mode switch must not leave the
        // idle client's retired socket able to answer to the live one's name.
        let realtime = RealtimeAPIWebSocketClient()
        realtime.debugSkipSocketCreationForTesting()
        let mistral = MistralRealtimeWebSocketClient()
        mistral.debugSkipSocketCreationForTesting()

        try realtime.connect(
            configuration: RealtimeSessionConfiguration(
                endpoint: URL(string: "ws://127.0.0.1:65535/v1/realtime")!, apiKey: "k", model: "m"))
        try mistral.connect(
            configuration: RealtimeSessionConfiguration(
                endpoint: URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!,
                apiKey: "k", model: "m"))

        XCTAssertNotEqual(realtime.connectionGeneration, mistral.connectionGeneration)
    }

    func testEventsCarryTheSocketTheyCameFromAcrossASocketSwap() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task1)
        let first = client.connectionGeneration
        client.debugHandleFrameForTesting(
            json: ["type": "transcription.done", "text": "from the first socket"])

        client.debugPrimeConnectedStateForTesting(task: task2)
        let second = client.connectionGeneration
        XCTAssertNotEqual(first, second)
        client.debugHandleFrameForTesting(
            json: ["type": "transcription.done", "text": "from the second socket"])

        XCTAssertEqual(collector.generations(), [first, second])
    }

    func testAStaleSessionCreatedDoesNotHandTheNewSocketAHandshakeItNeverGot() {
        // Stamping the events is only half the job. `session.created` also
        // mutates handshake state and drains the pending queue onto the wire —
        // applied to the socket that replaced it, that sends the new socket's
        // queued audio ahead of its own session.update, which the emitted
        // status being dropped later does nothing about.
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task1)
        let retired = client.connectionGeneration

        // The swap: the socket the frame was read from is gone, its
        // replacement is up and has its own queued frame, unsent.
        client.debugPrimeConnectedStateForTesting(task: task2)
        XCTAssertNotEqual(client.connectionGeneration, retired)
        XCTAssertEqual(client.debugStateSnapshot().pendingMessageCount, 1)

        // The delayed handler for the retired socket's frame.
        client.debugHandleFrameForTesting(
            json: ["type": "session.created"], from: retired)

        let after = client.debugStateSnapshot()
        XCTAssertFalse(
            after.hasReceivedSessionCreated,
            "the new socket has not had its own session.created"
        )
        XCTAssertEqual(
            after.pendingMessageCount, 1,
            "and its queue must still be waiting for it"
        )
        XCTAssertTrue(
            after.hasSessionReadyTimer,
            "nor may the stale frame cancel the new socket's readiness gate"
        )
    }

    /// Every frame handed to a socket, in order, by the socket it went to.
    private final class Wire: @unchecked Sendable {
        private var frames: [(task: URLSessionWebSocketTask, text: String)] = []
        private let lock = NSLock()

        func append(_ task: URLSessionWebSocketTask, _ text: String) {
            lock.lock()
            frames.append((task, text))
            lock.unlock()
        }

        /// Each frame's JSON `type`, or its text when it is not JSON.
        func kinds(on task: URLSessionWebSocketTask) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return frames.filter { $0.task === task }.map { frame in
                let json = (try? JSONSerialization.jsonObject(with: Data(frame.text.utf8))) as? [String: Any]
                return json?["type"] as? String ?? frame.text
            }
        }
    }

    // The handshake opens the send gate and replays what queued before it
    // (#1058). Audio the send loop hands over during the replay goes out
    // behind it, never ahead of session.update or older audio; and a socket
    // that replaced this one mid-replay gets none of it.

    func testRealtimeAudioSentDuringTheHandshakeReplayGoesOutBehindIt() {
        let client = RealtimeAPIWebSocketClient()
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task, modelName: "model")
        client.debugSetBeforeHandshakeDrain { client.sendAudioChunk(Data([1, 2, 3, 4])) }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(
            wire.kinds(on: task), ["session.update", "pending-message", "input_audio_buffer.append"])
    }

    func testRealtimeSocketSwappedDuringTheHandshakeReplayGetsNoneOfIt() {
        let client = RealtimeAPIWebSocketClient()
        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task1, modelName: "model")
        client.debugSetBeforeHandshakeDrain { client.debugPrimeConnectedStateForTesting(task: task2) }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(wire.kinds(on: task2), [])
        XCTAssertEqual(
            client.debugStateSnapshot().pendingMessageCount, 1,
            "the new socket's queue holds its own frame and nothing of the old one's"
        )
    }

    func testRealtimeSessionCreatedAfterTheTimerOpenedTheGateStartsNoSecondReplay() {
        let client = RealtimeAPIWebSocketClient()
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task, modelName: "model")
        client.debugBypassSessionCreatedGateForTesting()
        XCTAssertEqual(wire.kinds(on: task), ["session.update", "pending-message"])

        let secondReplay = Wire()
        client.debugSetBeforeHandshakeDrain { secondReplay.append(task, "replay") }
        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(secondReplay.kinds(on: task), [], "the late handshake must not race the timer's replay")
        XCTAssertTrue(client.debugStateSnapshot().hasReceivedSessionCreated)
    }

    // The handshake fallback and the keepalive ping sleep on the session
    // clock the client was given, never on wall time (#1366).

    func testHandshakeFallbackFollowsInjectedClock() async {
        let clock = ManualSessionClock()
        let client = RealtimeAPIWebSocketClient(clock: clock.clock)
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        let wire = Wire()
        let replayed = expectation(description: "the queue is replayed")
        client.debugObserveTransmits { sentOn, text in
            wire.append(sentOn, text)
            if text == "pending-message" { replayed.fulfill() }
        }
        client.debugPrimeConnectedStateForTesting(task: task, modelName: "model")

        // No session.created: the fallback and the ping wait on the clock.
        await clock.waitForSleepers(2)
        let start = clock.now
        XCTAssertEqual(clock.pendingDeadlines, [start.addingTimeInterval(3), start.addingTimeInterval(30)])
        XCTAssertEqual(wire.kinds(on: task), [])

        clock.advance(by: 3)
        await fulfillment(of: [replayed], timeout: 10)
        clock.advance(by: 3)

        XCTAssertEqual(wire.kinds(on: task), ["session.update", "pending-message"], "replayed once")
        XCTAssertEqual(clock.pendingDeadlines, [start.addingTimeInterval(30)], "only the ping is left")
    }

    func testDisconnectCancelsTheHandshakeFallbackAndThePing() async {
        let clock = ManualSessionClock()
        let client = RealtimeAPIWebSocketClient(clock: clock.clock)
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task, modelName: "model")
        await clock.waitForSleepers(2)

        client.disconnect()
        XCTAssertEqual(clock.pendingSleepers, 0)
        clock.advance(by: 30)

        XCTAssertEqual(wire.kinds(on: task), [])
    }

    func testMistralKeepalivePingSleepsOnTheInjectedClock() async {
        let clock = ManualSessionClock()
        let client = MistralRealtimeWebSocketClient(clock: clock.clock)
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        client.debugPrimeConnectedStateForTesting(task: task)

        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.pendingDeadlines, [clock.now.addingTimeInterval(30)])

        client.disconnect()
        XCTAssertEqual(clock.pendingSleepers, 0)
    }

    func testMistralAudioSentDuringTheHandshakeReplayGoesOutBehindIt() {
        let client = MistralRealtimeWebSocketClient()
        let (session, task) = makeWebSocketTask()
        defer { task.cancel(); session.invalidateAndCancel() }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugSetBeforeHandshakeDrain { client.sendAudioChunk(Data([1, 2, 3, 4])) }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(wire.kinds(on: task), ["session.update", "pending-message", "input_audio.append"])
    }

    func testMistralSocketSwappedDuringTheHandshakeReplayGetsNoneOfIt() {
        let client = MistralRealtimeWebSocketClient()
        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }
        let wire = Wire()
        client.debugObserveTransmits { wire.append($0, $1) }
        client.debugPrimeConnectedStateForTesting(task: task1)
        client.debugSetBeforeHandshakeDrain { client.debugPrimeConnectedStateForTesting(task: task2) }

        client.debugHandleFrameForTesting(json: ["type": "session.created"])

        XCTAssertEqual(wire.kinds(on: task2), [])
        XCTAssertEqual(
            client.debugStateSnapshot().pendingMessageCount, 1,
            "the new socket's queue holds its own frame and nothing of the old one's"
        )
    }

    func testAStaleTranscriptionDoneDoesNotClearTheNewSocketsCommitGate() {
        // The stop path waits for `transcriptionFinalized` before it
        // disconnects. A `done` read off the retiring socket, applied here,
        // would close that gate and let the stop finish on a socket that has
        // not answered its final commit.
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task1)
        let retired = client.connectionGeneration

        client.debugPrimeConnectedStateForTesting(task: task2)
        client.debugPrimeFinalCommitGateForTesting()
        XCTAssertTrue(client.debugStateSnapshot().isAwaitingFinalCommitDone)

        client.debugHandleFrameForTesting(
            json: ["type": "transcription.done", "text": "from the retired socket"],
            from: retired
        )

        XCTAssertTrue(
            client.debugStateSnapshot().isAwaitingFinalCommitDone,
            "the live socket still owes its own transcription.done"
        )
        XCTAssertFalse(
            collector.snapshot().contains { if case .transcriptionFinalized = $0 { return true }
                return false },
            "and the stop must not be told finalization happened"
        )
    }

    // MARK: - Stale Task Identity

    func testRealtimeTerminalErrorWithStaleTaskIsNoOp() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        // Prime with task1, then send error for task2 (stale/wrong identity)
        client.debugPrimeConnectedStateForTesting(task: task1)
        client.debugHandleTerminalSocketErrorForTesting(task: task2, errorMessage: "stale error")

        let after = client.debugStateSnapshot()
        XCTAssertTrue(after.isConnected, "State should be unchanged for stale task")
        XCTAssertTrue(after.hasPingTimer)
        XCTAssertTrue(after.hasSessionReadyTimer)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 0, "No events should be emitted for stale task")
    }

    // MARK: - Double Disconnect

    func testRealtimeDoubleTerminalErrorIsNoOp() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "first error")
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "second error")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2, "Only first error+disconnected pair should be emitted")
        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error"); return
        }
        XCTAssertEqual(message, "first error")
        guard case .disconnected = events[1] else {
            XCTFail("Expected .disconnected"); return
        }
    }

    // MARK: - Transcription Stopped

    /// #314: the bundled helper reports an engine that stopped transcribing mid-dictation
    /// as an `error` frame with code `transcription_stopped`. The client must surface it as
    /// its own event, keep the connection, and leave every other error frame alone.
    func testRealtimeTranscriptionStoppedErrorCodeEmitsItsOwnEvent() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleFrameForTesting(json: [
            "type": "error",
            "code": "transcription_stopped",
            "message": "10-minute limit reached; start again.",
        ])
        client.debugHandleFrameForTesting(json: ["type": "error", "message": "Invalid PCM16 payload"])

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .transcriptionStopped(let stopMessage) = events[0] else {
            XCTFail("Expected .transcriptionStopped, got \(events[0])"); return
        }
        XCTAssertEqual(stopMessage, "10-minute limit reached; start again.")
        guard case .error(let errorMessage) = events[1] else {
            XCTFail("Expected .error for a frame without the code, got \(events[1])"); return
        }
        XCTAssertEqual(errorMessage, "Invalid PCM16 payload")
        XCTAssertTrue(client.debugStateSnapshot().isConnected, "a stop must not drop the socket")
    }

    // MARK: - Transcription Finalization

    func testRealtimeDoneAfterFinalCommitEmitsFinalTranscriptThenFinalizedAcrossTrackingStates() {
        let cases: [
            (label: String, hasUncommittedAudio: Bool, isGenerationInProgress: Bool)
        ] = [
            ("uncommitted audio, generation complete", true, false),
            ("uncommitted audio, generation in flight", true, true),
            ("no uncommitted audio, generation in flight", false, true),
        ]

        for testCase in cases {
            let client = RealtimeAPIWebSocketClient()
            let collector = EventCollector()
            client.setEventHandler { collector.append($0, from: $1) }

            let (session, task) = makeWebSocketTask()
            defer {
                task.cancel()
                session.invalidateAndCancel()
            }

            client.debugPrimeConnectedStateForTesting(task: task)
            client.debugSetGenerationTrackingState(
                hasUncommittedAudio: testCase.hasUncommittedAudio,
                isGenerationInProgress: testCase.isGenerationInProgress
            )

            client.sendCommit(final: true)
            client.debugHandleFrameForTesting(json: ["type": "transcription.done", "text": "final text"])

            let events = collector.snapshot()
            XCTAssertEqual(events.count, 2, testCase.label)
            guard case .finalTranscript(let text) = events[0] else {
                XCTFail("\(testCase.label): expected first event to be .finalTranscript")
                return
            }
            XCTAssertEqual(text, "final text", testCase.label)
            guard case .transcriptionFinalized = events[1] else {
                XCTFail("\(testCase.label): expected second event to be .transcriptionFinalized")
                return
            }
        }
    }

    func testRealtimeDoneWithoutFinalCommitDoesNotEmitTranscriptionFinalized() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleFrameForTesting(json: ["type": "transcription.done"])

        XCTAssertTrue(collector.snapshot().isEmpty)
    }

    func testRealtimeTranscriptionFinalizedEmitsOnlyOnceForRepeatedDone() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugSetGenerationTrackingState(hasUncommittedAudio: true, isGenerationInProgress: false)
        client.sendCommit(final: true)
        client.debugHandleFrameForTesting(json: ["type": "transcription.done"])
        client.debugHandleFrameForTesting(json: ["type": "transcription.done"])

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .transcriptionFinalized = events[0] else {
            XCTFail("Expected only .transcriptionFinalized")
            return
        }
    }

    func testFinalCommitWithNoPendingAudioOrGenerationWaitsForDoneToFinalize() {
        let client = RealtimeAPIWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0, from: $1) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugSetGenerationTrackingState(hasUncommittedAudio: false, isGenerationInProgress: false)

        client.sendCommit(final: true)
        XCTAssertTrue(collector.snapshot().isEmpty)

        client.debugHandleFrameForTesting(json: ["type": "transcription.done"])

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .transcriptionFinalized = events[0] else {
            XCTFail("Expected .transcriptionFinalized after done")
            return
        }
    }
}
#endif
