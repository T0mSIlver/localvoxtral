import Foundation
import Synchronization
import os

final class MlxAudioRealtimeWebSocketClient: BaseRealtimeWebSocketClient, @unchecked Sendable, RealtimeClient {
    private struct State {
        var base = BaseState()
        var hasSentInitialConfiguration = false
        var pendingModelName = ""
        var pendingTextMessages: [String] = []
        var pendingBinaryMessages: [Data] = []
        var sawStreamingDeltaForCurrentChunk = false
        var activeStreamingHypothesis = ""
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

    let supportsPeriodicCommit = false

    override var logger: Logger { Log.mlxRealtime }

    override func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        state.withLock { body(&$0.base) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeEvent) -> Void) {
        state.withLock { $0.base.onEvent = handler }
    }

    func connect(configuration: RealtimeSessionConfiguration) throws {
        try validateWebSocketScheme(
            configuration.endpoint, errorDomain: "localvoxtral.realtime.mlx")

        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 30

        let trimmedAPIKey = configuration.apiKey.trimmed
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let modelName = configuration.model.trimmed
        debugLog("connect endpoint=\(configuration.endpoint.absoluteString) model=\(modelName)")

        state.withLock { s in
            closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)

            let (session, task) = createWebSocketSession(request: request, delegate: self)

            s.base.urlSession = session
            s.base.webSocketTask = task
            s.base.socketState = .connecting
            s.base.isUserInitiatedDisconnect = false
            s.hasSentInitialConfiguration = false
            s.pendingModelName = modelName
            s.sawStreamingDeltaForCurrentChunk = false
            s.activeStreamingHypothesis = ""
            s.pendingTranscriptionDelayMilliseconds = configuration.transcriptionDelayMilliseconds

            task.resume()
        }
    }

    func disconnect() {
        let shouldEmitDisconnected = state.withLock { s -> Bool in
            guard s.base.socketState != .disconnected else { return false }
            s.base.isUserInitiatedDisconnect = true
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
            guard s.base.socketState != .disconnected else { return .none }
            s.base.isUserInitiatedDisconnect = true

            guard s.base.socketState == .connected, let task = s.base.webSocketTask else {
                closeSocketLocked(&s, cancelTask: true, clearQueuedMessages: true)
                return .closeNow
            }

            s.delayedDisconnectWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldEmit = self.state.withLock { s -> Bool in
                    guard s.base.socketState != .disconnected, s.base.webSocketTask === task
                    else { return false }
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
        debugLog("explicit commit ignored for mlx-audio backend")
    }

    // MARK: - JSON Event Handling

    override func handle(json: [String: Any]) {
        if let status = json["status"] as? String {
            let normalizedStatus = status.trimmed.lowercased()
            if normalizedStatus == "ready" {
                emit(.status("Session ready."))
            } else if let message = json["message"] as? String, !message.trimmed.isEmpty {
                emit(.status(message))
            }
        }

        if let type = json["type"] as? String {
            switch type {
            case "delta":
                guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
                let partialHypothesis = state.withLock { s -> String in
                    s.sawStreamingDeltaForCurrentChunk = true
                    s.activeStreamingHypothesis.append(delta)
                    return s.activeStreamingHypothesis
                }
                emit(.partialTranscript(partialHypothesis))
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

    // MARK: - Post-Connect

    override func didOpenConnection(on webSocketTask: URLSessionWebSocketTask) {
        state.withLock { s in
            s.base.isUserInitiatedDisconnect = false
        }
        sendInitialConfigurationAndFlushQueue(on: webSocketTask)
    }

    // MARK: - Completion Handling

    private func handleCompletion(text: String, isPartial: Bool) {
        let normalizedText = text.trimmed
        let sawStreamingDelta = state.withLock { s in
            let hadDelta = s.sawStreamingDeltaForCurrentChunk
            s.sawStreamingDeltaForCurrentChunk = false
            s.activeStreamingHypothesis = ""
            return hadDelta
        }

        guard !normalizedText.isEmpty else { return }

        if isPartial {
            if sawStreamingDelta { return }
            emit(.partialTranscript(normalizedText))
            return
        }

        emit(.finalTranscript(normalizedText))
    }

    // MARK: - Send Helpers

    private func enqueueTextMessage(_ text: String) {
        let action: TextSendAction = state.withLock { s in
            switch s.base.socketState {
            case .connected:
                guard s.hasSentInitialConfiguration, let task = s.base.webSocketTask else {
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
            switch s.base.socketState {
            case .connected:
                guard s.hasSentInitialConfiguration, let task = s.base.webSocketTask else {
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
        let startup: (configurationText: String, queuedTexts: [String], queuedBinaries: [Data])? =
            state.withLock { s in
                guard s.base.socketState == .connected, s.base.webSocketTask === task else {
                    return nil
                }
                guard !s.hasSentInitialConfiguration else { return nil }
                s.hasSentInitialConfiguration = true

                var configuration: [String: Any] = [
                    "model": s.pendingModelName.isEmpty
                        ? "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
                        : s.pendingModelName,
                    "sample_rate": sampleRate,
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
                errorMessage: "WebSocket send failed: \(self.describeSocketError(error))"
            )
        }
    }

    private func sendBinary(_ data: Data, on task: URLSessionWebSocketTask) {
        task.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.handleTerminalSocketError(
                for: task,
                errorMessage: "WebSocket audio send failed: \(self.describeSocketError(error))"
            )
        }
    }

    // MARK: - State Cleanup

    private func closeSocketLocked(
        _ s: inout State, cancelTask: Bool, clearQueuedMessages: Bool
    ) {
        s.delayedDisconnectWorkItem?.cancel()
        s.delayedDisconnectWorkItem = nil

        closeBaseStateLocked(&s.base, cancelTask: cancelTask)

        s.hasSentInitialConfiguration = false
        s.pendingModelName = ""
        s.sawStreamingDeltaForCurrentChunk = false
        s.activeStreamingHypothesis = ""
        s.pendingTranscriptionDelayMilliseconds = nil

        if clearQueuedMessages {
            s.pendingTextMessages.removeAll(keepingCapacity: false)
            s.pendingBinaryMessages.removeAll(keepingCapacity: false)
        }
    }
}
