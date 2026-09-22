import Foundation
import Synchronization
import os

final class RealtimeAPIWebSocketClient: BaseRealtimeWebSocketClient, @unchecked Sendable, RealtimeClient {
    /// Tracks stop-finalization commit coordination so we only emit
    /// `.transcriptionFinalized` once the final commit response completes.
    private enum FinalCommitCompletionGate {
        /// No stop-finalization completion tracking is active.
        case idle
        /// Final commit has been sent and we are waiting for its
        /// `transcription.done` to emit `.transcriptionFinalized`.
        case awaitingFinalCommitTranscriptionDone
    }

    private struct State {
        var base = BaseState()
        var pingTimer: DispatchSourceTimer?
        var sessionReadyTimer: DispatchSourceTimer?
        var hasReceivedSessionCreated = false
        var hasBypassedSessionCreatedGate = false
        var hasSentSessionUpdate = false
        var hasUncommittedAudio = false
        var isGenerationInProgress = false
        var finalCommitCompletionGate: FinalCommitCompletionGate = .idle
        var pendingMessages: [String] = []
        var pendingModelName = ""
        #if DEBUG
        var skipsSocketCreationForTesting = false
        var lastConnectConfigurationForTesting: RealtimeSessionConfiguration?
        #endif
    }

    private let state = Mutex(State())
    let supportsPeriodicCommit = true
    var isConnected: Bool {
        state.withLock { $0.base.socketState == .connected }
    }
    var connectionGeneration: RealtimeConnectionGeneration {
        state.withLock { $0.base.connectionGeneration }
    }

    override var logger: Logger { Log.realtime }

    override func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        state.withLock { body(&$0.base) }
    }

    func setEventHandler(
        _ handler: @escaping @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void
    ) {
        state.withLock { $0.base.onEvent = handler }
    }

    func connect(configuration: RealtimeSessionConfiguration) throws {
        try validateWebSocketScheme(
            configuration.endpoint, errorDomain: "localvoxtral.realtime.websocket")

        #if DEBUG
        let skipsSocket: Bool = state.withLock { s in
            s.lastConnectConfigurationForTesting = configuration
            guard s.skipsSocketCreationForTesting else { return false }
            // No socket to swap, so the stamp is all this call does — the
            // session still reads it back as the connection it is now on.
            s.base.connectionGeneration = .next()
            return true
        }
        if skipsSocket {
            return
        }
        #endif

        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 30

        let trimmedAPIKey = configuration.apiKey.trimmed
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let modelName = configuration.model.trimmed
        debugLog("connect endpoint=\(configuration.endpoint.absoluteString) model=\(modelName)")

        state.withLock { s in
            closeSocketLocked(&s, cancelTask: true)
            // Stamped in the SAME locked block as the swap. A separate
            // acquisition would leave a window where the outgoing socket is
            // still the current one while the generation has already moved:
            // a frame admitted in that window would come out wearing the new
            // socket's name, which is the failure this whole stamp exists for.
            s.base.connectionGeneration = .next()

            let (session, task) = createWebSocketSession(request: request, delegate: self)

            s.base.urlSession = session
            s.base.webSocketTask = task
            s.base.socketState = .connecting
            s.base.isUserInitiatedDisconnect = false
            s.pendingMessages.removeAll(keepingCapacity: true)
            s.pendingModelName = modelName
            s.hasReceivedSessionCreated = false
            s.hasBypassedSessionCreatedGate = false
            s.hasSentSessionUpdate = false
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = false
            s.finalCommitCompletionGate = .idle

            task.resume()
        }
    }

    func disconnect() {
        let closed: RealtimeConnectionGeneration? = state.withLock { s in
            guard s.base.socketState != .disconnected else { return nil }
            s.base.isUserInitiatedDisconnect = true
            let generation = s.base.connectionGeneration
            closeSocketLocked(&s, cancelTask: true)
            return generation
        }

        if let closed {
            debugLog("disconnect")
            emit(.disconnected, from: closed)
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
        enum CommitAction {
            case none
            case sendCommitFrame(final: Bool)
        }

        let action: CommitAction = state.withLock { s in
            guard s.base.socketState != .disconnected else { return .none }

            if final {
                switch s.finalCommitCompletionGate {
                case .idle:
                    break
                case .awaitingFinalCommitTranscriptionDone:
                    return .none
                }

                s.hasUncommittedAudio = false
                s.isGenerationInProgress = true
                s.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone
                return .sendCommitFrame(final: true)
            }

            guard s.finalCommitCompletionGate == .idle else { return .none }
            guard s.hasUncommittedAudio else { return .none }
            guard !s.isGenerationInProgress else { return .none }
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = true
            return .sendCommitFrame(final: false)
        }

        switch action {
        case .none:
            return
        case .sendCommitFrame(let shouldMarkFinal):
            var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
            if shouldMarkFinal {
                payload["final"] = true
            }
            debugLog("send commit final=\(shouldMarkFinal)")
            send(event: payload)
        }
    }

    // MARK: - JSON Event Handling

    /// `code` the bundled speech helper puts on the `error` frame it sends when its engine
    /// stops transcribing before the final commit (`RealtimeServerMessage.transcriptionStopped`).
    static let transcriptionStoppedCode = "transcription_stopped"

    override func handle(json: [String: Any], from generation: RealtimeConnectionGeneration) {
        let type = json["type"] as? String ?? ""
        if !type.isEmpty {
            debugLog("recv event type=\(type)")
        }

        switch type {
        case "session.created":
            emit(.status("Session ready."), from: generation)
            let startup: (modelName: String, shouldSendUpdate: Bool, queuedMessages: [String])? =
                state.withLock { s in
                    // The socket this frame was read from, not whichever one
                    // the client holds now: a stale handshake applied here
                    // drains the NEW socket's queue ahead of its own
                    // session.update.
                    guard isCurrentConnectionLocked(s.base, generation) else { return nil }
                    guard s.base.socketState == .connected else { return nil }
                    guard !s.hasReceivedSessionCreated else { return nil }
                    s.hasReceivedSessionCreated = true
                    stopSessionReadyTimerLocked(&s)
                    let modelName = s.pendingModelName
                    let shouldSendUpdate = !s.hasSentSessionUpdate && !modelName.isEmpty
                    if shouldSendUpdate {
                        s.hasSentSessionUpdate = true
                    }
                    let queuedMessages = s.pendingMessages
                    s.pendingMessages.removeAll(keepingCapacity: true)
                    return (
                        modelName: modelName, shouldSendUpdate: shouldSendUpdate,
                        queuedMessages: queuedMessages
                    )
                }

            guard let startup else { return }
            if startup.shouldSendUpdate {
                send(event: ["type": "session.update", "model": startup.modelName])
            }
            for message in startup.queuedMessages {
                sendText(message)
            }
        case "session.updated":
            emit(.status("Session updated."), from: generation)
        case "transcription.delta",
            "response.audio_transcript.delta",
            "conversation.item.input_audio_transcription.delta":
            if let delta = findString(in: json, matching: ["delta", "text", "transcript"]) {
                emit(.partialTranscript(delta), from: generation)
            }
        case "transcription.done",
            "response.audio_transcript.done",
            "conversation.item.input_audio_transcription.completed":
            enum DoneAction {
                case none
                case emitTranscriptionFinalized
            }

            let doneAction: DoneAction = state.withLock { s in
                // A `done` the retiring socket was read for must not clear the
                // commit gate its replacement is still waiting on.
                guard isCurrentConnectionLocked(s.base, generation) else { return .none }
                s.isGenerationInProgress = false

                switch s.finalCommitCompletionGate {
                case .idle:
                    return .none
                case .awaitingFinalCommitTranscriptionDone:
                    s.finalCommitCompletionGate = .idle
                    return .emitTranscriptionFinalized
                }
            }
            if let text = findString(in: json, matching: ["text", "transcript", "delta"]) {
                emit(.finalTranscript(text), from: generation)
            }
            switch doneAction {
            case .none:
                break
            case .emitTranscriptionFinalized:
                emit(.transcriptionFinalized, from: generation)
            }
        case "error":
            state.withLock { s in
                guard isCurrentConnectionLocked(s.base, generation) else { return }
                s.isGenerationInProgress = false
            }
            let message =
                findString(in: json, matching: ["message", "error", "detail"])
                ?? "Unknown realtime error."
            if json["code"] as? String == Self.transcriptionStoppedCode {
                emit(.transcriptionStopped(message), from: generation)
            } else {
                emit(.error(message), from: generation)
            }
        default:
            break
        }
    }

    // MARK: - Post-Connect

    override func didOpenConnection(on webSocketTask: URLSessionWebSocketTask) {
        startPingTimer()
        startSessionReadyTimer()
    }

    // MARK: - Send Helpers

    private enum SendAction: Sendable {
        case send(task: URLSessionWebSocketTask, text: String)
        case queued
        case dropped
    }

    private func send(event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event) else {
            emit(.error("Invalid JSON payload generated."), from: currentConnectionGeneration)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.error("Failed to encode WebSocket frame."), from: currentConnectionGeneration)
                return
            }

            if let type = event["type"] as? String {
                debugLog("queue event type=\(type)")
            }
            sendText(text)
        } catch {
            emit(
                .error("Failed to serialize WebSocket payload: \(error.localizedDescription)"),
                from: currentConnectionGeneration)
        }
    }

    private func sendText(_ text: String) {
        let action: SendAction = state.withLock { s in
            switch s.base.socketState {
            case .connected:
                guard s.hasReceivedSessionCreated || s.hasBypassedSessionCreatedGate else {
                    s.pendingMessages.append(text)
                    return .queued
                }
                guard let webSocketTask = s.base.webSocketTask else { return .dropped }
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
                errorMessage: "WebSocket send failed: \(self.describeSocketError(error))"
            )
        }
    }

    // MARK: - Timers

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

    private func startSessionReadyTimerLocked(_ s: inout State) {
        stopSessionReadyTimerLocked(&s)

        // The socket this timer is armed for. A close cancels the timer, but a
        // handler already in flight would otherwise announce compatibility mode
        // under whatever name the client had picked up by then.
        let generation = s.base.connectionGeneration
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let startup:
                (modelName: String, shouldSendUpdate: Bool, queuedMessages: [String])? = self.state
                    .withLock { s in
                        // Cancelling a DispatchSourceTimer does not unqueue a
                        // handler already on its way: without this, a timer
                        // armed for the previous socket puts the NEW one into
                        // compatibility mode and flushes its queue early.
                        guard self.isCurrentConnectionLocked(s.base, generation) else { return nil }
                        guard s.base.socketState == .connected else { return nil }
                        guard !s.hasReceivedSessionCreated else { return nil }
                        self.stopSessionReadyTimerLocked(&s)
                        s.hasBypassedSessionCreatedGate = true
                        let modelName = s.pendingModelName
                        let shouldSendUpdate = !s.hasSentSessionUpdate && !modelName.isEmpty
                        if shouldSendUpdate {
                            s.hasSentSessionUpdate = true
                        }
                        let queuedMessages = s.pendingMessages
                        s.pendingMessages.removeAll(keepingCapacity: true)
                        return (
                            modelName: modelName, shouldSendUpdate: shouldSendUpdate,
                            queuedMessages: queuedMessages
                        )
                    }
            guard let startup else { return }
            self.emit(
                .status("Connected without session.created; using compatibility mode."),
                from: generation)
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

    override func handleTerminalSocketError(
        for task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        let outcome:
            (error: String?, disconnected: Bool, generation: RealtimeConnectionGeneration) =
            state.withLock { s in
                guard s.base.socketState != .disconnected, s.base.webSocketTask === task else {
                    return (nil, false, .none)
                }

                let shouldEmitError = !s.base.isUserInitiatedDisconnect
                let generation = s.base.connectionGeneration
                closeSocketLocked(&s, cancelTask: false)
                return (shouldEmitError ? errorMessage : nil, true, generation)
            }

        if let error = outcome.error {
            emit(.error(error), from: outcome.generation)
        }
        if outcome.disconnected {
            emit(.disconnected, from: outcome.generation)
        }
    }

    // MARK: - State Cleanup

    private func closeSocketLocked(_ s: inout State, cancelTask: Bool) {
        stopPingTimerLocked(&s)
        stopSessionReadyTimerLocked(&s)
        closeBaseStateLocked(&s.base, cancelTask: cancelTask)
        s.hasReceivedSessionCreated = false
        s.hasBypassedSessionCreatedGate = false
        s.hasSentSessionUpdate = false
        s.hasUncommittedAudio = false
        s.isGenerationInProgress = false
        s.finalCommitCompletionGate = .idle
        s.pendingMessages.removeAll(keepingCapacity: false)
        s.pendingModelName = ""
    }

    // MARK: - JSON Helpers

    /// Recursively searches a JSON structure for the first non-empty string
    /// value matching one of the given keys in priority order. Internal visibility
    /// for test access.
    func findString(in value: Any, matching keys: [String]) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let stringValue = dict[key] as? String, !stringValue.isEmpty {
                    return stringValue
                }
            }
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
}

#if DEBUG
extension RealtimeAPIWebSocketClient {
    struct DebugStateSnapshot {
        let isConnected: Bool
        let hasPingTimer: Bool
        let hasSessionReadyTimer: Bool
        let pendingMessageCount: Int
        let hasUncommittedAudio: Bool
        let isGenerationInProgress: Bool
        let hasReceivedSessionCreated: Bool
        let isAwaitingFinalCommitDone: Bool
    }

    /// Keeps view-model unit tests on the complete session-start path without
    /// creating a process-retained URLSession or touching a live backend.
    func debugSkipSocketCreationForTesting() {
        state.withLock { $0.skipsSocketCreationForTesting = true }
    }

    /// The configuration the most recent `connect(configuration:)` was handed,
    /// recorded before the socket-skip check so a socketless test still sees
    /// exactly what the session would have dialled with.
    func debugLastConnectConfigurationForTesting() -> RealtimeSessionConfiguration? {
        state.withLock { $0.lastConnectConfigurationForTesting }
    }

    func debugPrimeConnectedStateForTesting(
        task: URLSessionWebSocketTask, isUserInitiatedDisconnect: Bool = false
    ) {
        state.withLock { s in
            closeSocketLocked(&s, cancelTask: false)
            s.base.connectionGeneration = .next()
            s.base.webSocketTask = task
            s.base.socketState = .connected
            s.base.isUserInitiatedDisconnect = isUserInitiatedDisconnect
            s.pendingMessages = ["pending-message"]
            s.hasUncommittedAudio = true
            s.isGenerationInProgress = true
            startPingTimerLocked(&s)
            startSessionReadyTimerLocked(&s)
        }
    }

    func debugHandleTerminalSocketErrorForTesting(
        task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        handleTerminalSocketError(for: task, errorMessage: errorMessage)
    }

    /// Put the client where a stop-finalization leaves it: the final commit is
    /// out and the socket owes a `transcription.done` for it.
    func debugPrimeFinalCommitGateForTesting() {
        state.withLock { $0.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone }
    }

    func debugSetGenerationTrackingState(
        hasUncommittedAudio: Bool,
        isGenerationInProgress: Bool
    ) {
        state.withLock { s in
            s.hasUncommittedAudio = hasUncommittedAudio
            s.isGenerationInProgress = isGenerationInProgress
            s.finalCommitCompletionGate = .idle
        }
    }

    func debugStateSnapshot() -> DebugStateSnapshot {
        state.withLock { s in
            DebugStateSnapshot(
                isConnected: s.base.socketState == .connected,
                hasPingTimer: s.pingTimer != nil,
                hasSessionReadyTimer: s.sessionReadyTimer != nil,
                pendingMessageCount: s.pendingMessages.count,
                hasUncommittedAudio: s.hasUncommittedAudio,
                isGenerationInProgress: s.isGenerationInProgress,
                hasReceivedSessionCreated: s.hasReceivedSessionCreated,
                isAwaitingFinalCommitDone: s.finalCommitCompletionGate
                    == .awaitingFinalCommitTranscriptionDone
            )
        }
    }
}
#endif
