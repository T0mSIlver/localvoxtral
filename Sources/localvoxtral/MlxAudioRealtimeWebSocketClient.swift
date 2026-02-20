import Foundation
import Synchronization
import os

final class MlxAudioRealtimeWebSocketClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, Sendable, RealtimeClient {
    private enum SocketState {
        case disconnected
        case connecting
        case connected
    }

    private struct State {
        var urlSession: URLSession?
        var webSocketTask: URLSessionWebSocketTask?
        var socketState: SocketState = .disconnected
        var onEvent: (@Sendable (RealtimeWebSocketClient.Event) -> Void)?
        var isUserInitiatedDisconnect = false
        var hasSentInitialConfiguration = false
        var pendingModelName = ""
        var pendingTextMessages: [String] = []
        var pendingBinaryMessages: [Data] = []
        var sawStreamingDeltaForCurrentChunk = false
        var suppressDeltasUntilFinalComplete = false
        var pendingTranscriptionDelayMilliseconds: Int?
        var delayedDisconnectWorkItem: DispatchWorkItem?
    }

    private enum TextSendAction: Sendable {
        case send(task: URLSessionWebSocketTask, text: String)
        case queued
        case dropped
    }

    private enum BinarySendAction: Sendable {
        case send(task: URLSessionWebSocketTask, data: Data)
        case queued
        case dropped
    }

    private enum DisconnectAction {
        case none
        case closeNow
        case schedule(DispatchWorkItem)
    }

    private let state = Mutex(State())
    private let sampleRate = 16_000
    private let streamingModeEnabled = true
    private let finalizationGracePeriodSeconds: TimeInterval = 2.0
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    let supportsPeriodicCommit = false

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeWebSocketClient.Event) -> Void) {
        state.withLock { $0.onEvent = handler }
    }

    func connect(configuration: RealtimeWebSocketClient.Configuration) throws {
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw NSError(
                domain: "localvoxtral.realtime.mlx",
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

        let modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("connect endpoint=\(configuration.endpoint.absoluteString) model=\(modelName)")

        state.withLock { s in
            closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)

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
            s.hasSentInitialConfiguration = false
            s.pendingModelName = modelName
            s.sawStreamingDeltaForCurrentChunk = false
            s.suppressDeltasUntilFinalComplete = false
            s.pendingTranscriptionDelayMilliseconds = configuration.transcriptionDelayMilliseconds

            task.resume()
        }
    }

    func disconnect() {
        let shouldEmitDisconnected = state.withLock { s -> Bool in
            guard s.socketState != .disconnected else { return false }
            s.isUserInitiatedDisconnect = true
            closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)
            return true
        }

        if shouldEmitDisconnected {
            debugLog("disconnect")
            emit(.disconnected)
        }
    }

    func disconnectAfterFinalCommitIfNeeded() {
        let action: DisconnectAction = state.withLock { s in
            guard s.socketState != .disconnected else { return .none }
            s.isUserInitiatedDisconnect = true

            guard s.socketState == .connected, let task = s.webSocketTask else {
                closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)
                return .closeNow
            }

            s.delayedDisconnectWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldEmit = self.state.withLock { s -> Bool in
                    guard s.socketState != .disconnected, s.webSocketTask === task else { return false }
                    self.closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)
                    return true
                }
                if shouldEmit {
                    self.debugLog("disconnect after grace period")
                    self.emit(.disconnected)
                }
            }

            s.delayedDisconnectWorkItem = workItem
            return .schedule(workItem)
        }

        switch action {
        case .none:
            return
        case .closeNow:
            debugLog("disconnect")
            emit(.disconnected)
        case .schedule(let workItem):
            debugLog("waiting for mlx finalization before disconnect")
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + finalizationGracePeriodSeconds,
                execute: workItem
            )
        }
    }

    func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        enqueueBinaryMessage(pcm16Data)
    }

    func sendCommit(final: Bool) {
        guard final else { return }
        // mlx-audio handles chunking server-side and does not support explicit commit events.
        debugLog("explicit commit ignored for mlx-audio backend")
    }

    private func enqueueTextMessage(_ text: String) {
        let action: TextSendAction = state.withLock { s in
            switch s.socketState {
            case .connected:
                guard s.hasSentInitialConfiguration, let task = s.webSocketTask else {
                    s.pendingTextMessages.append(text)
                    return .queued
                }
                return .send(task: task, text: text)
            case .connecting:
                s.pendingTextMessages.append(text)
                return .queued
            case .disconnected:
                return .dropped
            }
        }

        guard case .send(let task, let payloadText) = action else { return }
        sendText(payloadText, on: task)
    }

    private func enqueueBinaryMessage(_ data: Data) {
        let action: BinarySendAction = state.withLock { s in
            switch s.socketState {
            case .connected:
                guard s.hasSentInitialConfiguration, let task = s.webSocketTask else {
                    s.pendingBinaryMessages.append(data)
                    return .queued
                }
                return .send(task: task, data: data)
            case .connecting:
                s.pendingBinaryMessages.append(data)
                return .queued
            case .disconnected:
                return .dropped
            }
        }

        guard case .send(let task, let payloadData) = action else { return }
        sendBinary(payloadData, on: task)
    }

    private func sendInitialConfigurationAndFlushQueue(on task: URLSessionWebSocketTask) {
        let startup: (configurationText: String, queuedTexts: [String], queuedBinaries: [Data])? = state.withLock { s in
            guard s.socketState == .connected, s.webSocketTask === task else { return nil }
            guard !s.hasSentInitialConfiguration else { return nil }
            s.hasSentInitialConfiguration = true

            var configuration: [String: Any] = [
                "model": s.pendingModelName.isEmpty
                    ? "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
                    : s.pendingModelName,
                "sample_rate": sampleRate,
                // Keep realtime streaming enabled; duplicate overlap is handled client-side.
                "streaming": streamingModeEnabled,
            ]
            if let delayMs = s.pendingTranscriptionDelayMilliseconds {
                configuration["transcription_delay_ms"] = delayMs
            }

            guard JSONSerialization.isValidJSONObject(configuration),
                  let data = try? JSONSerialization.data(withJSONObject: configuration),
                  let text = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            let queuedTexts = s.pendingTextMessages
            let queuedBinaries = s.pendingBinaryMessages
            s.pendingTextMessages.removeAll(keepingCapacity: true)
            s.pendingBinaryMessages.removeAll(keepingCapacity: true)
            return (text, queuedTexts, queuedBinaries)
        }

        guard let startup else { return }

        sendText(startup.configurationText, on: task)
        for text in startup.queuedTexts {
            sendText(text, on: task)
        }
        for data in startup.queuedBinaries {
            sendBinary(data, on: task)
        }
    }

    private func sendText(_ text: String, on task: URLSessionWebSocketTask) {
        task.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.handleTerminalSocketError(
                for: task,
                errorMessage: "WebSocket send failed: \(error.localizedDescription)"
            )
        }
    }

    private func sendBinary(_ data: Data, on task: URLSessionWebSocketTask) {
        task.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.handleTerminalSocketError(
                for: task,
                errorMessage: "WebSocket audio send failed: \(error.localizedDescription)"
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
        if let status = json["status"] as? String {
            let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedStatus == "ready" {
                emit(.status("Session ready."))
            } else if let message = json["message"] as? String,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                emit(.status(message))
            }
        }

        if let type = json["type"] as? String {
            switch type {
            case "delta":
                guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
                let shouldSuppress: Bool = state.withLock { s in
                    if s.suppressDeltasUntilFinalComplete {
                        return true
                    }
                    s.sawStreamingDeltaForCurrentChunk = true
                    return false
                }
                if shouldSuppress { return }
                emit(.partialTranscript(delta))
                return

            case "complete":
                let text = (json["text"] as? String) ?? ""
                let isPartial = (json["is_partial"] as? Bool) ?? false
                handleCompletion(text: text, isPartial: isPartial)
                return

            case "error":
                let message = (json["error"] as? String)
                    ?? (json["message"] as? String)
                    ?? "Unknown mlx-audio server error."
                emit(.error(message))
                return

            default:
                break
            }
        }

        if let error = json["error"] as? String, !error.isEmpty {
            emit(.error(error))
            return
        }

        if let text = json["text"] as? String {
            let isPartial = (json["is_partial"] as? Bool) ?? false
            handleCompletion(text: text, isPartial: isPartial)
        }
    }

    private func handleCompletion(text: String, isPartial: Bool) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sawStreamingDelta = state.withLock { s in
            let hadDelta = s.sawStreamingDeltaForCurrentChunk
            if isPartial {
                // The next pass may re-transcribe the same chunk from the beginning.
                // Keep current partial text visible and suppress replacement deltas
                // until final completion arrives.
                s.suppressDeltasUntilFinalComplete = true
            } else {
                s.sawStreamingDeltaForCurrentChunk = false
                s.suppressDeltasUntilFinalComplete = false
            }
            return hadDelta
        }

        guard !normalizedText.isEmpty else { return }

        if isPartial {
            // Avoid duplicate partial text when the server sends delta events and then a complete partial.
            if sawStreamingDelta { return }
            emit(.partialTranscript(normalizedText))
            return
        }

        emit(.finalTranscript(normalizedText))
    }

    private func closeSocketLocked(_ s: inout State, cancelTask: Bool, clearQueuedMessages: Bool) {
        s.delayedDisconnectWorkItem?.cancel()
        s.delayedDisconnectWorkItem = nil

        if cancelTask {
            s.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }
        s.webSocketTask = nil

        s.urlSession?.invalidateAndCancel()
        s.urlSession = nil

        s.socketState = .disconnected
        s.isUserInitiatedDisconnect = false
        s.hasSentInitialConfiguration = false
        s.pendingModelName = ""
        s.sawStreamingDeltaForCurrentChunk = false
        s.suppressDeltasUntilFinalComplete = false
        s.pendingTranscriptionDelayMilliseconds = nil

        if clearQueuedMessages {
            s.pendingTextMessages.removeAll(keepingCapacity: false)
            s.pendingBinaryMessages.removeAll(keepingCapacity: false)
        }
    }

    private func handleTerminalSocketError(for task: URLSessionWebSocketTask, errorMessage: String?) {
        let outcome: (error: String?, disconnected: Bool) = state.withLock { s in
            guard s.socketState != .disconnected, s.webSocketTask === task else {
                return (nil, false)
            }
            let shouldEmitError = !s.isUserInitiatedDisconnect
            closeSocketLocked(&s, cancelTask: false, clearQueuedMessages: true)
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
            s.isUserInitiatedDisconnect = false
            return true
        }
        guard isCurrentTask else { return }

        debugLog("didOpen")
        emit(.connected)
        sendInitialConfigurationAndFlushQueue(on: webSocketTask)
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
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            handleTerminalSocketError(for: webSocketTask, errorMessage: nil)
            return
        }

        handleTerminalSocketError(
            for: webSocketTask,
            errorMessage: "WebSocket failed: \(error.localizedDescription)"
        )
    }

    private func emit(_ event: RealtimeWebSocketClient.Event) {
        let handler: (@Sendable (RealtimeWebSocketClient.Event) -> Void)? = state.withLock { $0.onEvent }
        guard let handler else { return }
        handler(event)
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.mlxRealtime.debug("\(message)")
    }
}
