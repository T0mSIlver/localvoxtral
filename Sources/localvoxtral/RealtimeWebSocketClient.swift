import Foundation
import Synchronization
import os

final class RealtimeWebSocketClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, Sendable, RealtimeClient {
    struct Configuration: Sendable {
        let endpoint: URL
        let apiKey: String
        let model: String
        let transcriptionDelayMilliseconds: Int?

        init(
            endpoint: URL,
            apiKey: String,
            model: String,
            transcriptionDelayMilliseconds: Int? = nil
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.model = model
            self.transcriptionDelayMilliseconds = transcriptionDelayMilliseconds
        }
    }

    enum Event: Sendable {
        case connected
        case disconnected
        case status(String)
        case partialTranscript(String)
        case finalTranscript(String)
        case error(String)
    }

    private enum SocketState {
        case disconnected
        case connecting
        case connected
    }

    private struct State {
        var urlSession: URLSession?
        var webSocketTask: URLSessionWebSocketTask?
        var socketState: SocketState = .disconnected
        var onEvent: (@Sendable (Event) -> Void)?
        var pingTimer: DispatchSourceTimer?
        var sessionReadyTimer: DispatchSourceTimer?
        var hasReceivedSessionCreated = false
        var hasBypassedSessionCreatedGate = false
        var hasSentSessionUpdate = false
        var hasUncommittedAudio = false
        var isGenerationInProgress = false
        var isUserInitiatedDisconnect = false
        var pendingMessages: [String] = []
        var pendingModelName = ""
    }

    private let state = Mutex(State())
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"
    let supportsPeriodicCommit = true

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        state.withLock { $0.onEvent = handler }
    }

    func connect(configuration: Configuration) throws {
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw NSError(
                domain: "localvoxtral.realtime.websocket",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Realtime endpoint must use ws:// or wss://."]
            )
        }

        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 30

        let trimmedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("connect endpoint=\(configuration.endpoint.absoluteString) model=\(modelName)")

        state.withLock { s in
            closeSocketLocked(&s, cancelTask: true)

            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.waitsForConnectivity = true
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60

            let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: request)

            s.urlSession = session
            s.webSocketTask = task
            s.socketState = .connecting
            s.isUserInitiatedDisconnect = false
            s.pendingMessages.removeAll(keepingCapacity: true)
            s.pendingModelName = modelName
            s.hasReceivedSessionCreated = false
            s.hasBypassedSessionCreatedGate = false
            s.hasSentSessionUpdate = false
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = false

            task.resume()
        }
    }

    func disconnect() {
        let wasConnected: Bool = state.withLock { s in
            let was = s.socketState != .disconnected
            guard was else { return false }
            s.isUserInitiatedDisconnect = true
            closeSocketLocked(&s, cancelTask: true)
            return was
        }

        if wasConnected {
            debugLog("disconnect")
            emit(.disconnected)
        }
    }

    func disconnectAfterFinalCommitIfNeeded() {
        enum DisconnectAction {
            case none
            case closeNow
            case sendFinalCommit(URLSessionWebSocketTask)
        }

        let action: DisconnectAction = state.withLock { s in
            guard s.socketState != .disconnected else { return .none }
            s.isUserInitiatedDisconnect = true

            guard s.socketState == .connected,
                  let webSocketTask = s.webSocketTask,
                  (s.hasUncommittedAudio || s.isGenerationInProgress)
            else {
                closeSocketLocked(&s, cancelTask: true)
                return .closeNow
            }

            s.hasUncommittedAudio = false
            s.isGenerationInProgress = false
            return .sendFinalCommit(webSocketTask)
        }

        switch action {
        case .none:
            return
        case .closeNow:
            debugLog("disconnect")
            emit(.disconnected)
        case .sendFinalCommit(let task):
            debugLog("send final commit before disconnect")
            let payload = #"{"type":"input_audio_buffer.commit","final":true}"#
            task.send(.string(payload)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.emit(.status("Final commit send failed: \(error.localizedDescription)"))
                }

                let shouldEmitDisconnected: Bool = self.state.withLock { s in
                    guard s.socketState != .disconnected, s.webSocketTask === task else {
                        return false
                    }
                    self.closeSocketLocked(&s, cancelTask: true)
                    return true
                }

                if shouldEmitDisconnected {
                    self.debugLog("disconnect")
                    self.emit(.disconnected)
                }
            }
        }
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        state.withLock { $0.hasUncommittedAudio = true }
        debugLog("send append bytes=\(pcm16Data.count)")
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
        send(event: payload)
    }

    func sendCommit(final: Bool) {
        let shouldCommit: Bool = state.withLock { s in
            guard s.socketState != .disconnected else { return false }

            if final {
                let shouldSignalFinal = s.hasUncommittedAudio || s.isGenerationInProgress
                s.hasUncommittedAudio = false
                s.isGenerationInProgress = false
                return shouldSignalFinal
            }

            guard s.hasUncommittedAudio else { return false }
            guard !s.isGenerationInProgress else { return false }
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = true
            return true
        }
        guard shouldCommit else { return }

        var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
        if final {
            payload["final"] = true
        }
        debugLog("send commit final=\(final)")
        send(event: payload)
    }

    private enum SendAction: Sendable {
        case send(task: URLSessionWebSocketTask, text: String)
        case queued
        case dropped
    }

    private func send(event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event) else {
            emit(.error("Invalid JSON payload generated."))
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.error("Failed to encode WebSocket frame."))
                return
            }

            if let type = event["type"] as? String {
                debugLog("queue event type=\(type)")
            }
            sendText(text)
        } catch {
            emit(.error("Failed to serialize WebSocket payload: \(error.localizedDescription)"))
        }
    }

    private func sendText(_ text: String) {
        let action: SendAction = state.withLock { s in
            switch s.socketState {
            case .connected:
                guard s.hasReceivedSessionCreated || s.hasBypassedSessionCreatedGate else {
                    s.pendingMessages.append(text)
                    return .queued
                }
                guard let webSocketTask = s.webSocketTask else { return .dropped }
                return .send(task: webSocketTask, text: text)
            case .connecting:
                s.pendingMessages.append(text)
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
                errorMessage: "WebSocket send failed: \(error.localizedDescription)"
            )
        }
    }

    private func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            let shouldHandleResult: Bool = self.state.withLock { s in
                s.socketState == .connected && s.webSocketTask === task
            }
            guard shouldHandleResult else { return }

            switch result {
            case .success(let message):
                self.handle(message: message)
                self.listenForMessages(on: task)
            case .failure(let error):
                self.handleTerminalSocketError(
                    for: task,
                    errorMessage: "WebSocket receive failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handle(text: text)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.status("Received binary frame of \(data.count) bytes."))
                return
            }
            handle(text: text)
        @unknown default:
            emit(.status("Received an unknown WebSocket frame."))
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("received non-dictionary JSON frame")
                emit(.status("Received non-JSON frame."))
                return
            }
            handle(json: json)
        } catch {
            debugLog("JSON parse error: \(error.localizedDescription)")
            emit(.status("Received non-JSON frame."))
        }
    }

    private func handle(json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        if !type.isEmpty {
            debugLog("recv event type=\(type)")
        }

        switch type {
        case "session.created":
            emit(.status("Session ready."))
            let startup: (modelName: String, shouldSendUpdate: Bool, queuedMessages: [String])? = state.withLock { s in
                guard s.socketState == .connected else { return nil }
                guard !s.hasReceivedSessionCreated else {
                    return nil
                }
                s.hasReceivedSessionCreated = true
                stopSessionReadyTimerLocked(&s)
                let modelName = s.pendingModelName
                let shouldSendUpdate = !s.hasSentSessionUpdate && !modelName.isEmpty
                if shouldSendUpdate {
                    s.hasSentSessionUpdate = true
                }
                let queuedMessages = s.pendingMessages
                s.pendingMessages.removeAll(keepingCapacity: true)
                return (modelName: modelName, shouldSendUpdate: shouldSendUpdate, queuedMessages: queuedMessages)
            }

            guard let startup else { return }
            if startup.shouldSendUpdate {
                send(event: ["type": "session.update", "model": startup.modelName])
            }
            for message in startup.queuedMessages {
                sendText(message)
            }
        case "session.updated":
            emit(.status("Session updated."))
        case "transcription.delta",
             "response.audio_transcript.delta",
             "conversation.item.input_audio_transcription.delta":
            if let delta = findString(in: json, matching: ["delta", "text", "transcript"]) {
                emit(.partialTranscript(delta))
            }
        case "transcription.done",
             "response.audio_transcript.done",
             "conversation.item.input_audio_transcription.completed":
            state.withLock { $0.isGenerationInProgress = false }
            if let text = findString(in: json, matching: ["text", "transcript", "delta"]) {
                emit(.finalTranscript(text))
            }
        case "error":
            state.withLock { $0.isGenerationInProgress = false }
            let message = findString(in: json, matching: ["message", "error", "detail"]) ?? "Unknown realtime error."
            emit(.error(message))
        default:
            break
        }
    }

    func findString(in value: Any, matching keys: Set<String>) -> String? {
        if let dict = value as? [String: Any] {
            // Direct key lookup first
            for key in keys {
                if let stringValue = dict[key] as? String, !stringValue.isEmpty {
                    return stringValue
                }
            }
            // Recurse only into nested containers, not leaf strings
            for (_, nestedValue) in dict {
                if nestedValue is [String: Any] || nestedValue is [Any] {
                    if let found = findString(in: nestedValue, matching: keys) {
                        return found
                    }
                }
            }
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                if let found = findString(in: nestedValue, matching: keys) {
                    return found
                }
            }
        }

        return nil
    }

    private func closeSocketLocked(_ s: inout State, cancelTask: Bool) {
        stopPingTimerLocked(&s)
        stopSessionReadyTimerLocked(&s)
        if cancelTask {
            s.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }

        s.webSocketTask = nil

        s.urlSession?.invalidateAndCancel()
        s.urlSession = nil

        s.socketState = .disconnected
        s.hasReceivedSessionCreated = false
        s.hasBypassedSessionCreatedGate = false
        s.hasSentSessionUpdate = false
        s.hasUncommittedAudio = false
        s.isGenerationInProgress = false
        s.pendingMessages.removeAll(keepingCapacity: false)
        s.pendingModelName = ""
        s.isUserInitiatedDisconnect = false
    }

    private func startPingTimer() {
        state.withLock { startPingTimerLocked(&$0) }
    }

    private func startSessionReadyTimer() {
        state.withLock { startSessionReadyTimerLocked(&$0) }
    }

    private func startPingTimerLocked(_ s: inout State) {
        stopPingTimerLocked(&s)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let task: URLSessionWebSocketTask? = self.state.withLock { s in
                guard s.socketState == .connected else { return nil }
                return s.webSocketTask
            }
            guard let task else { return }
            task.sendPing { [weak self] error in
                guard let self, let error else { return }
                self.handleTerminalSocketError(
                    for: task,
                    errorMessage: "Connection lost: \(error.localizedDescription)"
                )
            }
        }
        s.pingTimer = timer
        timer.resume()
    }

    private func startSessionReadyTimerLocked(_ s: inout State) {
        stopSessionReadyTimerLocked(&s)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let startup: (modelName: String, shouldSendUpdate: Bool, queuedMessages: [String])? = self.state.withLock { s in
                guard s.socketState == .connected else { return nil }
                guard !s.hasReceivedSessionCreated else { return nil }
                stopSessionReadyTimerLocked(&s)
                s.hasBypassedSessionCreatedGate = true
                let modelName = s.pendingModelName
                let shouldSendUpdate = !s.hasSentSessionUpdate && !modelName.isEmpty
                if shouldSendUpdate {
                    s.hasSentSessionUpdate = true
                }
                let queuedMessages = s.pendingMessages
                s.pendingMessages.removeAll(keepingCapacity: true)
                return (modelName: modelName, shouldSendUpdate: shouldSendUpdate, queuedMessages: queuedMessages)
            }
            guard let startup else { return }
            self.emit(.status("Connected without session.created; using compatibility mode."))
            if startup.shouldSendUpdate {
                self.send(event: ["type": "session.update", "model": startup.modelName])
            }
            for message in startup.queuedMessages {
                self.sendText(message)
            }
        }
        s.sessionReadyTimer = timer
        timer.resume()
    }

    private func stopPingTimerLocked(_ s: inout State) {
        s.pingTimer?.cancel()
        s.pingTimer = nil
    }

    private func stopSessionReadyTimerLocked(_ s: inout State) {
        s.sessionReadyTimer?.cancel()
        s.sessionReadyTimer = nil
    }

    private func handleTerminalSocketError(for task: URLSessionWebSocketTask, errorMessage: String?) {
        let outcome: (error: String?, disconnected: Bool) = state.withLock { s in
            guard s.socketState != .disconnected, s.webSocketTask === task else {
                return (nil, false)
            }

            let shouldEmitError = !s.isUserInitiatedDisconnect
            closeSocketLocked(&s, cancelTask: false)
            return (shouldEmitError ? errorMessage : nil, true)
        }

        if let error = outcome.error {
            emit(.error(error))
        }
        if outcome.disconnected {
            emit(.disconnected)
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let isCurrentTask: Bool = state.withLock { s in
            guard s.webSocketTask === webSocketTask else { return false }
            s.socketState = .connected
            return true
        }
        guard isCurrentTask else { return }

        debugLog("didOpen")
        emit(.connected)
        startPingTimer()
        startSessionReadyTimer()

        listenForMessages(on: webSocketTask)
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        debugLog("didClose code=\(closeCode.rawValue)")
        guard closeCode != .normalClosure, closeCode != .goingAway else {
            handleTerminalSocketError(for: webSocketTask, errorMessage: nil)
            return
        }

        let reasonText = reason.flatMap { data in
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let reasonText, !reasonText.isEmpty {
            handleTerminalSocketError(
                for: webSocketTask,
                errorMessage: "WebSocket closed (\(closeCode.rawValue)): \(reasonText)"
            )
            return
        }

        handleTerminalSocketError(
            for: webSocketTask,
            errorMessage: "WebSocket closed (\(closeCode.rawValue))."
        )
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }

        guard let error else {
            handleTerminalSocketError(for: webSocketTask, errorMessage: nil)
            return
        }

        debugLog("task didCompleteWithError=\(error.localizedDescription)")
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            handleTerminalSocketError(for: webSocketTask, errorMessage: nil)
            return
        }

        handleTerminalSocketError(
            for: webSocketTask,
            errorMessage: "WebSocket failed: \(error.localizedDescription)"
        )
    }

    private func emit(_ event: Event) {
        let handler: (@Sendable (Event) -> Void)? = state.withLock { $0.onEvent }

        guard let handler else { return }
        handler(event)
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.realtime.debug("\(message)")
    }
}
