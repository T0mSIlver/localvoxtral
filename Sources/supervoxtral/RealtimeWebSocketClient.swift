import Foundation

final class RealtimeWebSocketClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    struct Configuration {
        let endpoint: URL
        let apiKey: String
        let model: String
    }

    enum Event {
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

    private let stateQueue = DispatchQueue(label: "supervoxtral.realtime.websocket")
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var socketState: SocketState = .disconnected
    private var onEvent: (@Sendable (Event) -> Void)?
    private var pingTimer: DispatchSourceTimer?
    private var hasUncommittedAudio = false
    private var isGenerationInProgress = false
    private var isUserInitiatedDisconnect = false
    private var pendingEvents: [[String: Any]] = []
    private var pendingModelName = ""

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        stateQueue.sync {
            onEvent = handler
        }
    }

    func connect(configuration: Configuration) throws {
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw NSError(
                domain: "supervoxtral.realtime.websocket",
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

        stateQueue.sync {
            closeSocketLocked(cancelTask: true)

            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.waitsForConnectivity = true
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60

            let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: request)

            urlSession = session
            webSocketTask = task
            socketState = .connecting
            isUserInitiatedDisconnect = false
            pendingEvents.removeAll(keepingCapacity: true)
            pendingModelName = modelName
            hasUncommittedAudio = false
            isGenerationInProgress = false

            task.resume()
        }
    }

    func disconnect() {
        let wasConnected: Bool = stateQueue.sync {
            let was = socketState != .disconnected
            guard was else { return false }
            isUserInitiatedDisconnect = true
            closeSocketLocked(cancelTask: true)
            return was
        }

        if wasConnected {
            emit(.disconnected)
        }
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        stateQueue.sync { hasUncommittedAudio = true }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
        send(event: payload)
    }

    func sendCommit(final: Bool) {
        let shouldCommit: Bool = stateQueue.sync {
            guard socketState != .disconnected else { return false }

            if final {
                let shouldSignalFinal = hasUncommittedAudio || isGenerationInProgress
                hasUncommittedAudio = false
                isGenerationInProgress = false
                return shouldSignalFinal
            }

            guard hasUncommittedAudio else { return false }
            guard !isGenerationInProgress else { return false }
            hasUncommittedAudio = false
            isGenerationInProgress = true
            return true
        }
        guard shouldCommit else { return }

        var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
        if final {
            payload["final"] = true
        }
        send(event: payload)
    }

    private enum SendAction {
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

            let action: SendAction = stateQueue.sync {
                switch socketState {
                case .connected:
                    guard let webSocketTask else { return .dropped }
                    return .send(task: webSocketTask, text: text)
                case .connecting:
                    pendingEvents.append(event)
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
        } catch {
            emit(.error("Failed to serialize WebSocket payload: \(error.localizedDescription)"))
        }
    }

    private func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            let shouldHandleResult: Bool = self.stateQueue.sync {
                self.socketState == .connected && self.webSocketTask === task
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            emit(.status("Received non-JSON frame."))
            return
        }

        handle(json: json)
    }

    private func handle(json: [String: Any]) {
        let type = json["type"] as? String ?? ""

        switch type {
        case "session.created":
            emit(.status("Session ready."))
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
            stateQueue.sync {
                isGenerationInProgress = false
            }
            if let text = findString(in: json, matching: ["text", "transcript", "delta"]) {
                emit(.finalTranscript(text))
            }
        case "error":
            stateQueue.sync {
                isGenerationInProgress = false
            }
            let message = findString(in: json, matching: ["message", "error", "detail"]) ?? "Unknown realtime error."
            emit(.error(message))
        default:
            break
        }
    }

    private func findString(in value: Any, matching keys: Set<String>) -> String? {
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

    private func closeSocketLocked(cancelTask: Bool) {
        stopPingTimerLocked()
        if cancelTask {
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }

        webSocketTask = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        socketState = .disconnected
        hasUncommittedAudio = false
        isGenerationInProgress = false
        pendingEvents.removeAll(keepingCapacity: false)
        pendingModelName = ""
        isUserInitiatedDisconnect = false
    }

    private func startPingTimer() {
        stateQueue.sync {
            startPingTimerLocked()
        }
    }

    private func startPingTimerLocked() {
        stopPingTimerLocked()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let task: URLSessionWebSocketTask? = self.stateQueue.sync {
                guard self.socketState == .connected else { return nil }
                return self.webSocketTask
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
        pingTimer = timer
        timer.resume()
    }

    private func stopPingTimerLocked() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func handleTerminalSocketError(for task: URLSessionWebSocketTask, errorMessage: String?) {
        let outcome: (error: String?, disconnected: Bool) = stateQueue.sync {
            guard socketState != .disconnected, webSocketTask === task else {
                return (nil, false)
            }

            let shouldEmitError = !isUserInitiatedDisconnect
            closeSocketLocked(cancelTask: false)
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
        let isCurrentTask: Bool = stateQueue.sync {
            guard self.webSocketTask === webSocketTask else { return false }
            socketState = .connected
            return true
        }
        guard isCurrentTask else { return }

        emit(.connected)
        startPingTimer()

        let modelName: String = stateQueue.sync { pendingModelName }
        if !modelName.isEmpty {
            send(event: ["type": "session.update", "model": modelName])
        }

        let queuedEvents: [[String: Any]] = stateQueue.sync {
            let queued = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            return queued
        }
        for event in queuedEvents {
            send(event: event)
        }

        listenForMessages(on: webSocketTask)
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
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
        let handler: (@Sendable (Event) -> Void)? = stateQueue.sync {
            onEvent
        }

        guard let handler else { return }
        handler(event)
    }
}
