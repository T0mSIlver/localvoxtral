import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
/// Wire-level contract for `MistralRealtimeWebSocketClient`: exact outbound
/// frames, request construction, event mapping, and terminal-error cleanup.
/// No networking and no wall clock — every frame is read back from the
/// client's debug recorder and every inbound event is injected as JSON.
final class MistralRealtimeClientTests: XCTestCase {
    private final class LockedInts: @unchecked Sendable {
        private var values: [Int] = []
        private let lock = NSLock()

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class EventCollector: @unchecked Sendable {
        private var events: [RealtimeEvent] = []
        private let lock = NSLock()

        func append(_ event: RealtimeEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [RealtimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func makeWebSocketTask() -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "ws://127.0.0.1:65535/test")!
        let task = session.webSocketTask(with: url)
        return (session, task)
    }

    private func makeConfiguration(
        endpoint: URL = MistralRealtimeWebSocketClient.defaultEndpoint,
        apiKey: String = "test-key",
        model: String = ""
    ) -> RealtimeSessionConfiguration {
        RealtimeSessionConfiguration(endpoint: endpoint, apiKey: apiKey, model: model)
    }

    // MARK: - Static defaults

    func testDefaultsMatchTheHostedMistralRealtimeAPI() {
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.defaultEndpoint.absoluteString,
            "wss://api.mistral.ai/v1/audio/transcriptions/realtime"
        )
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.defaultModel,
            "voxtral-mini-transcribe-realtime-2602"
        )
    }

    func testPeriodicCommitIsUnsupported() {
        // Mistral streams deltas continuously — there is no partial commit, so
        // the session coordinator must not schedule one.
        XCTAssertFalse(MistralRealtimeWebSocketClient().supportsPeriodicCommit)
    }

    // MARK: - Request URL building

    func testRequestURLAddsModelQueryItemWhenAbsent() throws {
        let url = try MistralRealtimeWebSocketClient.requestURL(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            model: "voxtral-mini-transcribe-realtime-2602"
        )
        XCTAssertEqual(
            url.absoluteString,
            "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-2602"
        )
    }

    func testRequestURLFallsBackToDefaultModelForEmptyModel() throws {
        let url = try MistralRealtimeWebSocketClient.requestURL(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            model: "   "
        )
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "model" })?
                .value,
            MistralRealtimeWebSocketClient.defaultModel
        )
    }

    func testRequestURLReplacesExistingModelInPlaceAndPreservesOtherQueryItems() throws {
        let endpoint = URL(string: "wss://example.test/realtime?a=1&model=stale&b=2")!
        let url = try MistralRealtimeWebSocketClient.requestURL(
            endpoint: endpoint, model: "fresh-model")

        XCTAssertEqual(url.absoluteString, "wss://example.test/realtime?a=1&model=fresh-model&b=2")
    }

    func testRequestURLCollapsesDuplicateModelQueryItems() throws {
        let endpoint = URL(string: "wss://example.test/realtime?model=one&model=two")!
        let url = try MistralRealtimeWebSocketClient.requestURL(
            endpoint: endpoint, model: "fresh-model")

        XCTAssertEqual(url.absoluteString, "wss://example.test/realtime?model=fresh-model")
    }

    func testConnectRequestCarriesBearerAuthorizationHeader() throws {
        let client = MistralRealtimeWebSocketClient()
        let request = try client.makeConnectRequest(
            configuration: makeConfiguration(apiKey: "  sk-mistral-123  "))

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-mistral-123")
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model="
                + MistralRealtimeWebSocketClient.defaultModel
        )
    }

    func testConnectRequestRejectsNonWebSocketScheme() {
        let client = MistralRealtimeWebSocketClient()
        let endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions/realtime")!

        XCTAssertThrowsError(
            try client.makeConnectRequest(configuration: makeConfiguration(endpoint: endpoint))
        ) { error in
            XCTAssertTrue(
                (error as NSError).localizedDescription.contains("ws://"),
                "Expected a scheme-validation message, got \((error as NSError).localizedDescription)"
            )
        }
    }

    func testConnectRequestRejectsEmptyAPIKeyWithADescriptiveError() {
        let client = MistralRealtimeWebSocketClient()

        XCTAssertThrowsError(
            try client.makeConnectRequest(configuration: makeConfiguration(apiKey: "   "))
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, MistralRealtimeWebSocketClient.errorDomain)
            XCTAssertTrue(
                nsError.localizedDescription.contains("Mistral API key is missing"),
                "Expected a missing-key message, got \(nsError.localizedDescription)"
            )
        }
    }

    func testConnectThrowsForEmptyAPIKeyBeforeOpeningASocket() {
        let client = MistralRealtimeWebSocketClient()
        client.debugSkipSocketCreationForTesting()

        XCTAssertThrowsError(try client.connect(configuration: makeConfiguration(apiKey: "")))
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Outbound frames

    private func makeFrameRecordingClient(
        targetStreamingDelayMilliseconds: Int? = nil
    ) -> (MistralRealtimeWebSocketClient, URLSession, URLSessionWebSocketTask) {
        let client = MistralRealtimeWebSocketClient(
            targetStreamingDelayMilliseconds: targetStreamingDelayMilliseconds)
        let (session, task) = makeWebSocketTask()
        // Connected but pre-session.created: every frame is encoded and
        // recorded, then queued locally instead of hitting a socket.
        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugClearRecordedFrames()
        return (client, session, task)
    }

    /// The DEBUG frame recorder is a bounded ring: a DEBUG app build streams a
    /// ~4 KB audio frame every 100 ms, and an unbounded buffer nobody but the
    /// unit suite reads would grow by ~150 MB per hour of dictation.
    func testDebugFrameRecorderKeepsOnlyTheMostRecentFrames() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let limit = MistralRealtimeWebSocketClient.debugRecordedFrameLimit

        for index in 0..<(limit + 40) {
            client.sendAudioChunk(Data([UInt8(index & 0xFF), 0x00]))
        }

        let frames = client.debugRecordedFrames()
        XCTAssertEqual(frames.count, limit)
        // The ring drops the OLDEST frames: the last chunk sent is the last frame kept.
        let lastChunk = Data([UInt8((limit + 39) & 0xFF), 0x00]).base64EncodedString()
        XCTAssertEqual(frames.last, #"{"audio":"\#(lastChunk)","type":"input_audio.append"}"#)
    }

    func testAudioChunkIsSentAsInputAudioAppendWithBase64Payload() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendAudioChunk(Data([0x01, 0x02, 0x03, 0x04]))
        // 0xFF base64s to "/w==" — the slash must reach the wire unescaped
        // rather than as JSONSerialization's default "\/".
        client.sendAudioChunk(Data([0xFF]))

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [
                #"{"audio":"AQIDBA==","type":"input_audio.append"}"#,
                #"{"audio":"/w==","type":"input_audio.append"}"#,
            ]
        )
    }

    func testEmptyAudioChunkIsDropped() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendAudioChunk(Data())

        XCTAssertTrue(client.debugRecordedFrames().isEmpty)
    }

    func testNonFinalCommitIsANoOp() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendCommit(final: false)

        XCTAssertTrue(client.debugRecordedFrames().isEmpty)
        XCTAssertFalse(client.debugStateSnapshot().isAwaitingFinalCommitDone)
    }

    func testFinalCommitSendsFlushThenEndExactlyOncePerSession() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendCommit(final: true)
        client.sendCommit(final: true)

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [#"{"type":"input_audio.flush"}"#, #"{"type":"input_audio.end"}"#]
        )
        XCTAssertTrue(client.debugStateSnapshot().hasRequestedFinalCommit)
    }

    func testFinalCommitIsDroppedWhileDisconnected() {
        let client = MistralRealtimeWebSocketClient()
        client.sendCommit(final: true)

        XCTAssertTrue(client.debugRecordedFrames().isEmpty)
    }

    func testSessionCreatedSendsSessionUpdateThenFlushesQueuedFrames() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let collector = EventCollector()
        // How many frames had been encoded for the wire at the moment the
        // "Session ready." status reached the consumer: the live lane starts
        // streaming synchronously inside that callback, so its audio must land
        // BEHIND session.update and the replayed queue, never ahead of them.
        let framesEncodedAtStatus = LockedInts()
        client.setEventHandler { event in
            if case .status = event {
                framesEncodedAtStatus.append(client.debugRecordedFrames().count)
            }
            collector.append(event)
        }

        client.sendAudioChunk(Data([0xFF]))
        XCTAssertEqual(
            client.debugStateSnapshot().pendingMessageCount,
            2,
            "Priming queues one placeholder; the audio frame must queue behind it"
        )

        client.handle(json: ["type": "session.created", "session": ["model": "m"]])

        XCTAssertEqual(
            framesEncodedAtStatus.snapshot(), [2],
            "session.update and the queued audio are on the wire before the status is emitted"
        )

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [
                #"{"audio":"/w==","type":"input_audio.append"}"#,
                #"{"session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000}},"type":"session.update"}"#,
            ]
        )
        XCTAssertTrue(client.debugStateSnapshot().hasReceivedSessionCreated)
        XCTAssertEqual(client.debugStateSnapshot().pendingMessageCount, 0)

        guard case .status(let status) = collector.snapshot().first else {
            XCTFail("Expected a status event for session.created")
            return
        }
        XCTAssertEqual(status, "Session ready.")
    }

    /// Field freeze 2026-09-19: deltas stopped mid-dictation with no error.
    /// The client must name the server's silence, with the request id Mistral
    /// can look up, while audio is still going out.
    func testServerSilenceWhileStreamingIsReportedWithTheRequestID() {
        let clock = ManualSeconds()
        let client = MistralRealtimeWebSocketClient(now: { clock.value })
        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        client.debugPrimeConnectedStateForTesting(task: task)
        client.handle(json: ["type": "session.created", "session": ["request_id": "ws-abc"]])

        for tick in 1...40 {
            clock.value = Double(tick) / 10
            client.sendAudioChunk(Data(repeating: 0, count: 3_200))
        }
        client.handle(json: ["type": "transcription.text.delta", "text": "Look"])
        XCTAssertTrue(client.debugStallReportsForTesting().isEmpty, "4 s of silence is speech")

        for tick in 41...120 {
            clock.value = Double(tick) / 10
            client.sendAudioChunk(Data(repeating: 0, count: 3_200))
        }
        let reports = client.debugStallReportsForTesting()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.requestID, "ws-abc")
        XCTAssertEqual(reports.first?.silentFor ?? 0, 5.0, accuracy: 1e-9)
    }

    func testSessionUpdateCarriesTargetStreamingDelayWhenConfigured() {
        let (client, session, task) = makeFrameRecordingClient(
            targetStreamingDelayMilliseconds: 1_000)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.handle(json: ["type": "session.created"])

        XCTAssertEqual(
            client.debugRecordedFrames(),
            [
                #"{"session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000},"target_streaming_delay_ms":1000},"type":"session.update"}"#
            ]
        )
    }

    func testDuplicateSessionCreatedDoesNotResendSessionUpdate() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.handle(json: ["type": "session.created"])
        client.debugClearRecordedFrames()
        client.handle(json: ["type": "session.created"])

        XCTAssertTrue(client.debugRecordedFrames().isEmpty)
    }

    // MARK: - Inbound events

    private func collectEvents(
        client: MistralRealtimeWebSocketClient = MistralRealtimeWebSocketClient(),
        _ frames: [[String: Any]]
    ) -> [RealtimeEvent] {
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }
        for frame in frames {
            client.handle(json: frame)
        }
        return collector.snapshot()
    }

    func testTextDeltaBecomesPartialTranscript() {
        let events = collectEvents([
            ["type": "transcription.text.delta", "text": " hello"]
        ])

        XCTAssertEqual(events.count, 1)
        guard case .partialTranscript(let delta) = events[0] else {
            XCTFail("Expected .partialTranscript")
            return
        }
        XCTAssertEqual(delta, " hello")
    }

    func testEmptyTextDeltaIsIgnored() {
        XCTAssertTrue(collectEvents([["type": "transcription.text.delta", "text": ""]]).isEmpty)
    }

    func testSessionUpdatedBecomesStatus() {
        let events = collectEvents([["type": "session.updated", "session": [:] as [String: Any]]])

        XCTAssertEqual(events.count, 1)
        guard case .status(let status) = events[0] else {
            XCTFail("Expected .status")
            return
        }
        XCTAssertEqual(status, "Session updated.")
    }

    func testLanguageSegmentAndUnknownFramesAreIgnored() {
        let events = collectEvents([
            ["type": "transcription.language", "language": "en"],
            ["type": "transcription.segment", "text": "segment text", "start": 0.0],
            ["type": "transcription.definitely_new_thing", "text": "future"],
            ["text": "no type at all"],
        ])

        XCTAssertTrue(
            events.isEmpty,
            "Unhandled frames must be ignored for forward compatibility, got \(events)"
        )
    }

    func testDoneWithoutRequestedFinalCommitEmitsFinalTranscriptOnly() {
        let events = collectEvents([
            ["type": "transcription.done", "text": "full transcript"]
        ])

        XCTAssertEqual(events.count, 1)
        guard case .finalTranscript(let text) = events[0] else {
            XCTFail("Expected .finalTranscript")
            return
        }
        XCTAssertEqual(text, "full transcript")
    }

    func testDoneAfterFinalCommitEmitsFinalTranscriptThenTranscriptionFinalized() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let collector = EventCollector()

        client.sendCommit(final: true)
        client.setEventHandler { collector.append($0) }
        client.handle(json: ["type": "transcription.done", "text": "final text"])

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .finalTranscript(let text) = events[0] else {
            XCTFail("Expected first event to be .finalTranscript")
            return
        }
        XCTAssertEqual(text, "final text")
        guard case .transcriptionFinalized = events[1] else {
            XCTFail("Expected second event to be .transcriptionFinalized")
            return
        }
    }

    func testRepeatedDoneFinalizesExactlyOnce() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let collector = EventCollector()

        client.sendCommit(final: true)
        client.setEventHandler { collector.append($0) }
        client.handle(json: ["type": "transcription.done", "text": "final text"])
        client.handle(json: ["type": "transcription.done", "text": "final text"])

        let finalizedCount = collector.snapshot().filter { event in
            if case .transcriptionFinalized = event { return true }
            return false
        }.count
        XCTAssertEqual(finalizedCount, 1)
    }

    func testDoneWithEmptyTextStillFinalizes() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let collector = EventCollector()

        client.sendCommit(final: true)
        client.setEventHandler { collector.append($0) }
        client.handle(json: ["type": "transcription.done", "text": ""])

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .transcriptionFinalized = events[0] else {
            XCTFail("Expected .transcriptionFinalized")
            return
        }
    }

    // MARK: - Error frames

    func testErrorFrameWithStringMessage() {
        let events = collectEvents([
            ["type": "error", "error": ["message": "audio too long"] as [String: Any]]
        ])

        XCTAssertEqual(events.count, 1)
        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error")
            return
        }
        XCTAssertEqual(message, "audio too long")
    }

    func testErrorFrameWithNestedDetailMessage() {
        let events = collectEvents([
            [
                "type": "error",
                "error": ["message": ["detail": "field required"] as [String: Any]]
                    as [String: Any],
            ]
        ])

        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error")
            return
        }
        XCTAssertEqual(message, "field required")
    }

    func testErrorFrameAppendsCodeAndType() {
        let message = MistralRealtimeWebSocketClient.errorMessage(
            from: [
                "type": "error",
                "error": [
                    "message": "invalid api key",
                    "code": 401,
                    "type": "authentication_error",
                ] as [String: Any],
            ]
        )

        XCTAssertEqual(message, "invalid api key [code=401, type=authentication_error]")
    }

    func testErrorFrameWithoutAUsableMessageFallsBack() {
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.errorMessage(from: ["type": "error"]),
            "Mistral realtime error."
        )
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.errorMessage(
                from: ["type": "error", "error": ["message": "  "] as [String: Any]]
            ),
            "Mistral realtime error."
        )
    }

    func testErrorFrameClearsTheFinalizationGate() {
        let (client, session, task) = makeFrameRecordingClient()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.sendCommit(final: true)
        XCTAssertTrue(client.debugStateSnapshot().isAwaitingFinalCommitDone)

        client.handle(json: ["type": "error", "error": ["message": "boom"] as [String: Any]])

        XCTAssertFalse(
            client.debugStateSnapshot().isAwaitingFinalCommitDone,
            "A server error must not leave the stop-finalization gate armed"
        )
    }

    // MARK: - HTTP-level upgrade rejections

    func testTerminalErrorMessageNamesTheHTTPStatusOfARejectedUpgrade() {
        let raw = "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1011]"

        let unauthorized = MistralRealtimeWebSocketClient.terminalErrorMessage(
            errorMessage: raw, httpStatusCode: 401)
        XCTAssertEqual(
            unauthorized,
            "Mistral rejected the connection (HTTP 401): check the API key. \(raw)"
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: unauthorized),
            .unauthorized
        )

        let rateLimited = MistralRealtimeWebSocketClient.terminalErrorMessage(
            errorMessage: raw, httpStatusCode: 429)
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: rateLimited),
            .rateLimited
        )

        let billing = MistralRealtimeWebSocketClient.terminalErrorMessage(
            errorMessage: raw, httpStatusCode: 402)
        XCTAssertTrue(billing?.contains("HTTP 402") == true)
    }

    func testTerminalErrorMessageIsUntouchedWithoutAnHTTPResponse() {
        let raw = "WebSocket failed: Could not connect. [NSURLErrorDomain:-1004]"
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.terminalErrorMessage(
                errorMessage: raw, httpStatusCode: nil),
            raw
        )
        XCTAssertEqual(
            MistralRealtimeWebSocketClient.terminalErrorMessage(
                errorMessage: raw, httpStatusCode: 101),
            raw
        )
        XCTAssertNil(
            MistralRealtimeWebSocketClient.terminalErrorMessage(
                errorMessage: nil, httpStatusCode: 401)
        )
    }

    // MARK: - Lifecycle cleanup

    func testTerminalErrorCleansSubclassStateAndEmitsErrorThenDisconnected() {
        let client = MistralRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.sendCommit(final: true)

        let before = client.debugStateSnapshot()
        XCTAssertTrue(before.isConnected)
        XCTAssertTrue(before.hasPingTimer)
        XCTAssertEqual(before.pendingMessageCount, 3)
        XCTAssertTrue(before.hasRequestedFinalCommit)
        XCTAssertTrue(before.isAwaitingFinalCommitDone)

        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let after = client.debugStateSnapshot()
        XCTAssertFalse(after.isConnected)
        XCTAssertFalse(after.hasPingTimer)
        XCTAssertEqual(after.pendingMessageCount, 0)
        XCTAssertFalse(after.hasReceivedSessionCreated)
        XCTAssertFalse(after.hasRequestedFinalCommit)
        XCTAssertFalse(after.isAwaitingFinalCommitDone)

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

    func testTerminalErrorSuppressesErrorForUserInitiatedDisconnect() {
        let client = MistralRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task, isUserInitiatedDisconnect: true)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "socket failed")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .disconnected = events[0] else {
            XCTFail("Expected only .disconnected for user-initiated disconnect")
            return
        }
    }

    func testTerminalErrorWithStaleTaskIsNoOp() {
        let client = MistralRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session1, task1) = makeWebSocketTask()
        let (session2, task2) = makeWebSocketTask()
        defer {
            task1.cancel(); session1.invalidateAndCancel()
            task2.cancel(); session2.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task1)
        client.debugHandleTerminalSocketErrorForTesting(task: task2, errorMessage: "stale error")

        XCTAssertTrue(client.debugStateSnapshot().isConnected)
        XCTAssertTrue(client.debugStateSnapshot().hasPingTimer)
        XCTAssertTrue(collector.snapshot().isEmpty)
    }

    func testDoubleTerminalErrorIsNoOp() {
        let client = MistralRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "first error")
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "second error")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case .error(let message) = events[0] else {
            XCTFail("Expected .error")
            return
        }
        XCTAssertEqual(message, "first error")
    }

    func testDisconnectEmitsDisconnectedOnceAndClearsState() {
        let client = MistralRealtimeWebSocketClient()
        let collector = EventCollector()
        client.setEventHandler { collector.append($0) }

        let (session, task) = makeWebSocketTask()
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        client.debugPrimeConnectedStateForTesting(task: task)
        client.disconnect()
        client.disconnect()

        XCTAssertEqual(collector.snapshot().count, 1)
        XCTAssertFalse(client.debugStateSnapshot().isConnected)
        XCTAssertFalse(client.debugStateSnapshot().hasPingTimer)
    }
}
#endif

private final class ManualSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
