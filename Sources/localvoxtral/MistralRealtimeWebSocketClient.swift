import Foundation
import Synchronization
import os

/// Realtime transcription client for Mistral's hosted WebSocket API
/// (`wss://api.mistral.ai/v1/audio/transcriptions/realtime`).
///
/// Wire protocol differences from the OpenAI-Realtime sibling
/// (`RealtimeAPIWebSocketClient`) that drive the shape of this class:
///  - The model travels as a `model` query item on the upgrade request, not in
///    a `session.update` body.
///  - Audio frames are `input_audio.append`; there is no partial-commit
///    concept, so `supportsPeriodicCommit` is false and the stream is ended
///    once with `input_audio.flush` + `input_audio.end`.
///  - The server always speaks first (`session.created`), so outbound frames
///    are queued until it does — there is no compatibility bypass timer.
///  - The server closes the socket normally after `transcription.done`; the
///    base class maps a normal closure to a silent `.disconnected`.
final class MistralRealtimeWebSocketClient: BaseRealtimeWebSocketClient, @unchecked Sendable,
    RealtimeClient
{
    static let defaultEndpoint = URL(
        string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!
    static let defaultModel = "voxtral-mini-transcribe-realtime-2602"

    /// PCM encoding this client always produces (16 kHz mono little-endian S16).
    static let audioEncoding = "pcm_s16le"
    static let audioSampleRate = 16_000

    static let errorDomain = "localvoxtral.realtime.mistral"

    #if DEBUG
    /// Frames kept by the DEBUG recorder; the unit suite never needs more than
    /// the last handful.
    static let debugRecordedFrameLimit = 64
    #endif

    /// Tracks stop-finalization commit coordination so we only emit
    /// `.transcriptionFinalized` once the final commit's `transcription.done`
    /// arrives.
    private enum FinalCommitCompletionGate {
        /// No stop-finalization completion tracking is active.
        case idle
        /// `input_audio.end` has been sent and we are waiting for the
        /// matching `transcription.done` to emit `.transcriptionFinalized`.
        case awaitingFinalCommitTranscriptionDone
    }

    private struct State {
        var base = BaseState()
        var pingTimer: DispatchSourceTimer?
        var hasReceivedSessionCreated = false
        var hasRequestedFinalCommit = false
        var finalCommitCompletionGate: FinalCommitCompletionGate = .idle
        var pendingMessages: [PendingFrame] = []
        /// The model this socket was opened for, nil when none is open.
        var usageModel: String?
        /// PCM bytes of `input_audio.append` actually handed to the socket
        /// since it opened — what Mistral bills, as far as this Mac can tell.
        var sentAudioBytes = 0
        #if DEBUG
        var skipsSocketCreationForTesting = false
        var recordedFrames: [String] = []
        var lastConnectConfigurationForTesting: RealtimeSessionConfiguration?
        #endif
    }

    /// A frame held until `session.created`, with the PCM bytes it carries
    /// (zero for a control frame) so audio is counted only once it is sent.
    private struct PendingFrame {
        let text: String
        let audioBytes: Int
    }

    private let state = Mutex(State())
    private let usageRecorder = Mutex<(any MistralUsageRecording)?>(nil)

    /// Latency/accuracy knob (`target_streaming_delay_ms`). `nil` leaves the
    /// server default in place; a later PR surfaces this in Settings.
    let targetStreamingDelayMilliseconds: Int?

    let supportsPeriodicCommit = false

    var isConnected: Bool {
        state.withLock { $0.base.socketState == .connected }
    }

    init(targetStreamingDelayMilliseconds: Int? = nil) {
        self.targetStreamingDelayMilliseconds = targetStreamingDelayMilliseconds
        super.init()
    }

    /// Where each socket reports the audio it sent when it closes. Nil (the
    /// default) records nothing.
    func setUsageRecorder(_ recorder: (any MistralUsageRecording)?) {
        usageRecorder.withLock { $0 = recorder }
    }

    override var logger: Logger { Log.realtime }

    override func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        state.withLock { body(&$0.base) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeEvent) -> Void) {
        state.withLock { $0.base.onEvent = handler }
    }

    // MARK: - Request Building

    /// Resolves the model name actually sent on the wire.
    static func resolvedModel(_ model: String) -> String {
        let trimmed = model.trimmed
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Builds the upgrade request URL: `configuration.endpoint` with the
    /// `model` query item set (replacing an existing one in place, preserving
    /// every other query item).
    static func requestURL(endpoint: URL, model: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Mistral realtime endpoint could not be parsed as a URL."
                ]
            )
        }

        let modelItem = URLQueryItem(name: "model", value: resolvedModel(model))
        var items = components.queryItems ?? []
        if let existingIndex = items.firstIndex(where: { $0.name == "model" }) {
            // Replace in place so unrelated query items keep their order, and
            // drop any duplicate `model=` items behind it.
            items[existingIndex] = modelItem
            items = items.enumerated()
                .filter { $0.offset == existingIndex || $0.element.name != "model" }
                .map(\.element)
        } else {
            items.append(modelItem)
        }
        components.queryItems = items

        guard let url = components.url else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Mistral realtime endpoint could not be rebuilt with a model query item."
                ]
            )
        }
        return url
    }

    /// Builds the full upgrade request (URL + `Authorization` header).
    ///
    /// Throws for a non-ws/wss endpoint and for an empty API key: Mistral never
    /// accepts an anonymous socket, and letting it fail as a silent 401 is the
    /// worst possible UX.
    func makeConnectRequest(configuration: RealtimeSessionConfiguration) throws -> URLRequest {
        try validateWebSocketScheme(configuration.endpoint, errorDomain: Self.errorDomain)

        let trimmedAPIKey = configuration.apiKey.trimmed
        guard !trimmedAPIKey.isEmpty else {
            throw NSError(
                domain: Self.errorDomain,
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Mistral API key is missing. Add your Mistral API key in Settings → Engines."
                ]
            )
        }

        let url = try Self.requestURL(
            endpoint: configuration.endpoint, model: configuration.model)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The `session.update` frame sent right after `session.created`.
    func sessionUpdatePayload() -> [String: Any] {
        var session: [String: Any] = [
            "audio_format": [
                "encoding": Self.audioEncoding,
                "sample_rate": Self.audioSampleRate,
            ]
        ]
        if let targetStreamingDelayMilliseconds {
            session["target_streaming_delay_ms"] = targetStreamingDelayMilliseconds
        }
        return ["type": "session.update", "session": session]
    }

    // MARK: - RealtimeClient

    func connect(configuration: RealtimeSessionConfiguration) throws {
        #if DEBUG
        // Recorded before the key check so a socketless test can still see
        // exactly what the session tried to dial with.
        state.withLock { $0.lastConnectConfigurationForTesting = configuration }
        #endif
        let request = try makeConnectRequest(configuration: configuration)

        #if DEBUG
        if state.withLock({ $0.skipsSocketCreationForTesting }) {
            return
        }
        #endif

        logger.notice(
            "mistral realtime connect url=\(request.url?.absoluteString ?? "<none>", privacy: .public)"
        )

        let previousUsage: MistralUsageEntry? = state.withLock { s in
            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            s.usageModel = Self.resolvedModel(configuration.model)

            let (session, task) = createWebSocketSession(request: request, delegate: self)

            s.base.urlSession = session
            s.base.webSocketTask = task
            s.base.socketState = .connecting
            s.base.isUserInitiatedDisconnect = false

            task.resume()
            return usage
        }
        recordUsage(previousUsage)
    }

    func disconnect() {
        let (wasConnected, usage): (Bool, MistralUsageEntry?) = state.withLock { s in
            let was = s.base.socketState != .disconnected
            guard was else { return (false, nil) }
            s.base.isUserInitiatedDisconnect = true
            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            return (was, usage)
        }
        recordUsage(usage)

        if wasConnected {
            debugLog("disconnect")
            emit(.disconnected)
        }
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        debugLog("send input_audio.append bytes=\(pcm16Data.count)")
        send(
            event: [
                "type": "input_audio.append",
                "audio": pcm16Data.base64EncodedString(),
            ],
            audioBytes: pcm16Data.count
        )
    }

    func sendCommit(final: Bool) {
        // Mistral streams deltas continuously; there is no partial commit.
        guard final else { return }

        let shouldEndStream: Bool = state.withLock { s in
            guard s.base.socketState != .disconnected else { return false }
            guard !s.hasRequestedFinalCommit else { return false }
            s.hasRequestedFinalCommit = true
            s.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone
            return true
        }
        guard shouldEndStream else { return }

        logger.notice("mistral realtime final commit: flush + end")
        send(event: ["type": "input_audio.flush"])
        send(event: ["type": "input_audio.end"])
    }

    // MARK: - JSON Event Handling

    override func handle(json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        if !type.isEmpty {
            debugLog("recv event type=\(type)")
        }

        switch type {
        case "session.created":
            handleSessionCreated()

        case "session.updated":
            emit(.status("Session updated."))

        case "transcription.text.delta":
            guard let text = json["text"] as? String, !text.isEmpty else { return }
            emit(.partialTranscript(text))

        case "transcription.done":
            handleTranscriptionDone(json: json)

        case "error":
            let message = Self.errorMessage(from: json)
            state.withLock { s in
                s.finalCommitCompletionGate = .idle
            }
            logger.notice("mistral realtime error: \(message, privacy: .public)")
            emit(.error(message))

        case "transcription.language", "transcription.segment":
            // Not used for dictation; the delta/done stream carries the text.
            break

        default:
            // Forward compatibility: an unknown frame is never an error.
            break
        }
    }

    private func handleSessionCreated() {
        let queuedMessages: [PendingFrame]? = state.withLock { s in
            guard s.base.socketState == .connected else { return nil }
            guard !s.hasReceivedSessionCreated else { return nil }
            s.hasReceivedSessionCreated = true
            let queued = s.pendingMessages
            s.pendingMessages.removeAll(keepingCapacity: true)
            return queued
        }

        if let queuedMessages {
            logger.notice("mistral realtime session ready")
            send(event: sessionUpdatePayload())
            for message in queuedMessages {
                sendText(message.text, audioBytes: message.audioBytes)
            }
        }

        // Status goes out AFTER session.update and the replayed queue, so a
        // consumer that starts streaming on "Session ready." (the live lane
        // does, synchronously) puts its audio behind the audio-format
        // declaration on the wire, not ahead of it.
        emit(.status("Session ready."))
    }

    private func handleTranscriptionDone(json: [String: Any]) {
        enum DoneAction {
            case none
            case emitTranscriptionFinalized
        }

        let doneAction: DoneAction = state.withLock { s in
            switch s.finalCommitCompletionGate {
            case .idle:
                return .none
            case .awaitingFinalCommitTranscriptionDone:
                s.finalCommitCompletionGate = .idle
                return .emitTranscriptionFinalized
            }
        }

        let text = (json["text"] as? String) ?? ""
        logger.notice("mistral realtime transcription.done characters=\(text.count, privacy: .public)")
        if !text.isEmpty {
            emit(.finalTranscript(text))
        }

        switch doneAction {
        case .none:
            break
        case .emitTranscriptionFinalized:
            emit(.transcriptionFinalized)
        }
    }

    /// Extracts a user-facing message from an `error` frame.
    ///
    /// `error.message` is a string in the common case and `{"detail": ...}` in
    /// the validation-error case (matching the Python SDK's
    /// `_extract_error_message`). `code`/`type` are appended when present so a
    /// support log names the exact rejection.
    static func errorMessage(from json: [String: Any]) -> String {
        let errorObject = json["error"] as? [String: Any]

        var message = ""
        if let errorObject {
            if let text = errorObject["message"] as? String {
                message = text.trimmed
            } else if let nested = errorObject["message"] as? [String: Any],
                let detail = nested["detail"] as? String
            {
                message = detail.trimmed
            }
        }
        if message.isEmpty {
            message = "Mistral realtime error."
        }

        var annotations: [String] = []
        if let code = scalarString(errorObject?["code"]) {
            annotations.append("code=\(code)")
        }
        if let type = scalarString(errorObject?["type"]) {
            annotations.append("type=\(type)")
        }
        guard !annotations.isEmpty else { return message }
        return "\(message) [\(annotations.joined(separator: ", "))]"
    }

    private static func scalarString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmed
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    // MARK: - Post-Connect

    override func didOpenConnection(on webSocketTask: URLSessionWebSocketTask) {
        startPingTimer()
    }

    // MARK: - Send Helpers

    private enum SendAction: Sendable {
        case send(task: URLSessionWebSocketTask, text: String)
        case queued
        case dropped
    }

    private func send(event: [String: Any], audioBytes: Int = 0) {
        guard JSONSerialization.isValidJSONObject(event) else {
            emit(.error("Invalid JSON payload generated."))
            return
        }

        do {
            // Sorted keys keep the encoded frame byte-stable, which is what the
            // unit suite asserts on. Slashes stay unescaped: base64 audio is
            // ~1.6% "/", and JSONSerialization's default `\/` would pay two
            // bytes for each of them on every audio frame.
            let data = try JSONSerialization.data(
                withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.error("Failed to encode WebSocket frame."))
                return
            }

            #if DEBUG
            state.withLock { s in
                // A bounded ring, not a transcript: audio frames arrive every
                // 100 ms at ~4 KB each, and a DEBUG build (Xcode, the dogfood
                // tree) would otherwise grow by ~150 MB per hour of dictation
                // for a buffer only the unit suite reads (GLM review, 2026-09-16).
                s.recordedFrames.append(text)
                if s.recordedFrames.count > Self.debugRecordedFrameLimit {
                    s.recordedFrames.removeFirst(
                        s.recordedFrames.count - Self.debugRecordedFrameLimit)
                }
            }
            #endif

            if let type = event["type"] as? String {
                debugLog("queue event type=\(type)")
            }
            sendText(text, audioBytes: audioBytes)
        } catch {
            emit(.error("Failed to serialize WebSocket payload: \(error.localizedDescription)"))
        }
    }

    private func sendText(_ text: String, audioBytes: Int) {
        let action: SendAction = state.withLock { s in
            switch s.base.socketState {
            case .connected:
                guard s.hasReceivedSessionCreated else {
                    s.pendingMessages.append(PendingFrame(text: text, audioBytes: audioBytes))
                    return .queued
                }
                guard let webSocketTask = s.base.webSocketTask else { return .dropped }
                // Counted when handed to the socket, not on its completion: a
                // send that fails as the socket dies over-counts by the frames
                // in flight — at most a fraction of a second.
                s.sentAudioBytes += audioBytes
                return .send(task: webSocketTask, text: text)
            case .connecting:
                s.pendingMessages.append(PendingFrame(text: text, audioBytes: audioBytes))
                return .queued
            case .disconnected:
                return .dropped
            }
        }

        guard case .send(let task, let payloadText) = action else {
            return
        }

        task.send(.string(payloadText)) { [weak self] error in
            guard let self, let error else { return }
            self.handleTerminalSocketError(
                for: task,
                errorMessage: "WebSocket send failed: \(self.describeSocketError(error))"
            )
        }
    }

    // MARK: - Timers

    private func startPingTimer() {
        state.withLock { startPingTimerLocked(&$0) }
    }

    private func startPingTimerLocked(_ s: inout State) {
        stopPingTimerLocked(&s)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let task: URLSessionWebSocketTask? = self.state.withLock { s in
                guard s.base.socketState == .connected else { return nil }
                return s.base.webSocketTask
            }
            guard let task else { return }
            task.sendPing { [weak self] error in
                guard let self, let error else { return }
                self.handleTerminalSocketError(
                    for: task,
                    errorMessage: "Connection lost: \(self.describeSocketError(error))"
                )
            }
        }
        s.pingTimer = timer
        timer.resume()
    }

    private func stopPingTimerLocked(_ s: inout State) {
        s.pingTimer?.cancel()
        s.pingTimer = nil
    }

    // MARK: - Terminal Errors

    override func handleTerminalSocketError(
        for task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        let resolvedMessage = Self.terminalErrorMessage(
            errorMessage: errorMessage,
            httpStatusCode: (task.response as? HTTPURLResponse)?.statusCode
        )

        let outcome: (error: String?, disconnected: Bool, usage: MistralUsageEntry?) =
            state.withLock { s in
                guard s.base.socketState != .disconnected, s.base.webSocketTask === task else {
                    return (nil, false, nil)
                }

                let shouldEmitError = !s.base.isUserInitiatedDisconnect
                let usage = takeUsageLocked(&s)
                closeSocketLocked(&s, cancelTask: false)
                return (shouldEmitError ? resolvedMessage : nil, true, usage)
            }
        recordUsage(outcome.usage)

        if let error = outcome.error {
            logger.notice("mistral realtime socket failed: \(error, privacy: .public)")
            emit(.error(error))
        }
        if outcome.disconnected {
            emit(.disconnected)
        }
    }

    /// Folds the HTTP status of a rejected upgrade into the socket error text.
    ///
    /// URLSession reports an HTTP-level rejection of the upgrade (401/403 bad
    /// key, 402 billing, 429 rate limit) as a bare `NSURLErrorBadServerResponse`
    /// (-1011), which the failure classifier would otherwise read as "check the
    /// path" — actively misleading for a hosted provider. `task.response` still
    /// carries the real status, so we name it.
    static func terminalErrorMessage(errorMessage: String?, httpStatusCode: Int?) -> String? {
        guard let errorMessage else { return nil }
        guard let httpStatusCode, httpStatusCode >= 400 else { return errorMessage }
        return "Mistral rejected the connection (HTTP \(httpStatusCode)): "
            + "\(httpRejectionHint(statusCode: httpStatusCode)) \(errorMessage)"
    }

    static func httpRejectionHint(statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return "check the API key."
        case 402:
            return "the account is out of credit or the plan does not cover this model."
        case 429:
            return "rate limit reached; wait and retry."
        default:
            return "the server refused the websocket upgrade."
        }
    }

    // MARK: - Usage

    /// The closing socket's entry, nil when it sent no audio. Resets the
    /// counters, so each socket is recorded exactly once whichever path
    /// closes it.
    private func takeUsageLocked(_ s: inout State) -> MistralUsageEntry? {
        defer {
            s.usageModel = nil
            s.sentAudioBytes = 0
        }
        guard let model = s.usageModel, s.sentAudioBytes > 0 else { return nil }
        let audioSeconds = Double(s.sentAudioBytes) / Double(Self.audioSampleRate * 2)
        return MistralUsageEntry(
            date: Date(),
            kind: .dictation,
            model: model,
            audioSeconds: audioSeconds,
            costEUR: MistralPricing.dictationCost(model: model, audioSeconds: audioSeconds)
        )
    }

    private func recordUsage(_ entry: MistralUsageEntry?) {
        guard let entry, let recorder = usageRecorder.withLock({ $0 }) else { return }
        recorder.record(entry)
    }

    // MARK: - State Cleanup

    private func closeSocketLocked(_ s: inout State, cancelTask: Bool) {
        stopPingTimerLocked(&s)
        closeBaseStateLocked(&s.base, cancelTask: cancelTask)
        s.hasReceivedSessionCreated = false
        s.hasRequestedFinalCommit = false
        s.finalCommitCompletionGate = .idle
        s.pendingMessages.removeAll(keepingCapacity: false)
    }
}

#if DEBUG
extension MistralRealtimeWebSocketClient {
    struct DebugStateSnapshot {
        let isConnected: Bool
        let hasPingTimer: Bool
        let pendingMessageCount: Int
        let hasReceivedSessionCreated: Bool
        let hasRequestedFinalCommit: Bool
        let isAwaitingFinalCommitDone: Bool
    }

    /// Keeps view-model unit tests on the complete session-start path without
    /// creating a process-retained URLSession or touching a live backend.
    func debugSkipSocketCreationForTesting() {
        state.withLock { $0.skipsSocketCreationForTesting = true }
    }

    func debugPrimeConnectedStateForTesting(
        task: URLSessionWebSocketTask,
        isUserInitiatedDisconnect: Bool = false,
        hasReceivedSessionCreated: Bool = false,
        usageModel: String? = nil
    ) {
        state.withLock { s in
            closeSocketLocked(&s, cancelTask: false)
            s.usageModel = usageModel
            s.sentAudioBytes = 0
            s.base.webSocketTask = task
            s.base.socketState = .connected
            s.base.isUserInitiatedDisconnect = isUserInitiatedDisconnect
            s.hasReceivedSessionCreated = hasReceivedSessionCreated
            s.pendingMessages = [PendingFrame(text: "pending-message", audioBytes: 0)]
            startPingTimerLocked(&s)
        }
    }

    func debugHandleTerminalSocketErrorForTesting(
        task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        handleTerminalSocketError(for: task, errorMessage: errorMessage)
    }

    func debugStateSnapshot() -> DebugStateSnapshot {
        state.withLock { s in
            DebugStateSnapshot(
                isConnected: s.base.socketState == .connected,
                hasPingTimer: s.pingTimer != nil,
                pendingMessageCount: s.pendingMessages.count,
                hasReceivedSessionCreated: s.hasReceivedSessionCreated,
                hasRequestedFinalCommit: s.hasRequestedFinalCommit,
                isAwaitingFinalCommitDone: s.finalCommitCompletionGate
                    == .awaitingFinalCommitTranscriptionDone
            )
        }
    }

    /// Every frame this client encoded for the wire, in order.
    /// The configuration the most recent `connect(configuration:)` was handed,
    /// nil when this transport was never dialled.
    func debugLastConnectConfigurationForTesting() -> RealtimeSessionConfiguration? {
        state.withLock { $0.lastConnectConfigurationForTesting }
    }

    func debugRecordedFrames() -> [String] {
        state.withLock { $0.recordedFrames }
    }

    func debugClearRecordedFrames() {
        state.withLock { $0.recordedFrames.removeAll(keepingCapacity: true) }
    }
}
#endif
