import Foundation

final class RealtimeWebSocketClient: @unchecked Sendable {
    struct Configuration {
        let endpoint: URL
        let apiKey: String
        let model: String
    }

    enum Event {
        case connected
        case status(String)
        case partialTranscript(String)
        case finalTranscript(String)
        case error(String)
    }

    private let stateQueue = DispatchQueue(label: "supervoxtral.realtime.websocket")
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var onEvent: (@Sendable (Event) -> Void)?

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        stateQueue.sync {
            onEvent = handler
        }
    }

    func connect(configuration: Configuration) throws {
        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 20

        let trimmedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        stateQueue.sync {
            disconnectLocked()

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)

            urlSession = session
            webSocketTask = task
            isConnected = true

            task.resume()
        }

        emit(.connected)
        listenForMessages()

        let modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelName.isEmpty {
            send(event: ["type": "session.update", "model": modelName])
        }

        sendCommit(final: false)
    }

    func disconnect() {
        stateQueue.sync {
            disconnectLocked()
        }

        emit(.status("Disconnected."))
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
        send(event: payload)
    }

    func sendCommit(final: Bool) {
        var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
        if final {
            payload["final"] = true
        }
        send(event: payload)
    }

    private func send(event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event) else {
            emit(.error("Invalid JSON payload generated."))
            return
        }

        let task: URLSessionWebSocketTask? = stateQueue.sync {
            guard isConnected else { return nil }
            return webSocketTask
        }

        guard let task else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.error("Failed to encode WebSocket frame."))
                return
            }

            task.send(.string(text)) { [weak self] error in
                guard let self, let error else { return }
                self.emit(.error("WebSocket send failed: \(error.localizedDescription)"))
            }
        } catch {
            emit(.error("Failed to serialize WebSocket payload: \(error.localizedDescription)"))
        }
    }

    private func listenForMessages() {
        let task: URLSessionWebSocketTask? = stateQueue.sync {
            guard isConnected else { return nil }
            return webSocketTask
        }

        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message: message)
                self.listenForMessages()
            case .failure(let error):
                self.emit(.error("WebSocket receive failed: \(error.localizedDescription)"))
                self.disconnect()
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
            if let text = findString(in: json, matching: ["text", "transcript", "delta"]) {
                emit(.finalTranscript(text))
            }
        case "error":
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

    private func disconnectLocked() {
        guard isConnected else { return }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        isConnected = false
    }

    private func emit(_ event: Event) {
        let handler: (@Sendable (Event) -> Void)? = stateQueue.sync {
            onEvent
        }

        guard let handler else { return }
        handler(event)
    }
}
