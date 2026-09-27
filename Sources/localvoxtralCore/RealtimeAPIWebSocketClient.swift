import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

package final class RealtimeAPIWebSocketClient: BaseRealtimeWebSocketClient, @unchecked Sendable, RealtimeClient {
    /// Tracks stop-finalization commit coordination so we only emit
    /// `.transcriptionFinalized` once the final commit response completes.
    private enum FinalCommitCompletionGate {
        /// No stop-finalization completion tracking is active.
        case idle
        /// Final commit has been sent and we are waiting for its
        /// `transcription.done` to emit `.transcriptionFinalized`.
        case awaitingFinalCommitTranscriptionDone
    }

    /// A frame held until the handshake, with the PCM bytes it carries (zero
    /// for a control frame) so audio is counted only once it is sent.
    private struct PendingFrame {
        let text: String
        let audioBytes: Int
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
        var pendingMessages: [PendingFrame] = []
        var pendingModelName = ""
        /// The open socket's ledger line: who serves it, the model it asked
        /// for, and the PCM bytes handed to it. Nil backend records nothing.
        var usageBackend: UsageEntry.Backend?
        var usageModel = ""
        var sentAudioBytes = 0
        var pendingVocabulary: [String] = []
        #if DEBUG
        var skipsSocketCreationForTesting = false
        var lastConnectConfigurationForTesting: RealtimeSessionConfiguration?
        #endif
    }

    private let state = Mutex(State())
    private let usageRecorder = Mutex<(any RealtimeUsageRecording)?>(nil)
    /// The date a closing socket's usage is filed under; injected so tests
    /// read no wall clock.
    private let usageDate: @Sendable () -> Date
    package let supportsPeriodicCommit = true
    package var isConnected: Bool {
        state.withLock { $0.base.socketState == .connected }
    }
    package var connectionGeneration: RealtimeConnectionGeneration {
        state.withLock { $0.base.connectionGeneration }
    }

    package init(usageDate: @escaping @Sendable () -> Date = { Date() }) {
        self.usageDate = usageDate
        super.init()
    }

    /// Where each socket reports the audio it sent when it closes. Nil (the
    /// default) records nothing.
    package func setUsageRecorder(_ recorder: (any RealtimeUsageRecording)?) {
        usageRecorder.withLock { $0 = recorder }
    }

    override func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        state.withLock { body(&$0.base) }
    }

    package func setEventHandler(
        _ handler: @escaping @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void
    ) {
        state.withLock { $0.base.onEvent = handler }
    }

    package func connect(configuration: RealtimeSessionConfiguration) throws {
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

        let previousUsage: SocketUsage? = state.withLock { s in
            let usage = takeUsageLocked(&s)
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
            s.pendingVocabulary = configuration.vocabulary
            s.hasReceivedSessionCreated = false
            s.hasBypassedSessionCreatedGate = false
            s.hasSentSessionUpdate = false
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = false
            s.finalCommitCompletionGate = .idle
            s.usageBackend = configuration.usageBackend
            s.usageModel = modelName

            task.resume()
            return usage
        }
        recordUsage(previousUsage)
    }

    package func disconnect() {
        let (closed, usage): (RealtimeConnectionGeneration?, SocketUsage?) = state.withLock { s in
            guard s.base.socketState != .disconnected else { return (nil, nil) }
            s.base.isUserInitiatedDisconnect = true
            let generation = s.base.connectionGeneration
            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            return (generation, usage)
        }
        recordUsage(usage)

        if let closed {
            debugLog("disconnect")
            emit(.disconnected, from: closed)
        }
    }

    package func sendAudioChunk(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        state.withLock { $0.hasUncommittedAudio = true }
        debugLog("send append bytes=\(pcm16Data.count)")
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
        send(event: payload, audioBytes: pcm16Data.count)
    }

    package func sendCommit(final: Bool) {
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
            let startup: (modelName: String, vocabulary: [String], shouldSendUpdate: Bool, queuedMessages: [PendingFrame])? =
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
                        modelName: modelName, vocabulary: s.pendingVocabulary,
                            shouldSendUpdate: shouldSendUpdate,
                        queuedMessages: queuedMessages
                    )
                }

            guard let startup else { return }
            if startup.shouldSendUpdate {
                send(event: Self.sessionUpdateEvent(model: startup.modelName, vocabulary: startup.vocabulary))
            }
            for message in startup.queuedMessages {
                sendText(message.text, audioBytes: message.audioBytes)
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

    private func send(event: [String: Any], audioBytes: Int = 0) {
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
            sendText(text, audioBytes: audioBytes)
        } catch {
            emit(
                .error("Failed to serialize WebSocket payload: \(error.localizedDescription)"),
                from: currentConnectionGeneration)
        }
    }

    private func sendText(_ text: String, audioBytes: Int = 0) {
        let action: SendAction = state.withLock { s in
            switch s.base.socketState {
            case .connected:
                guard s.hasReceivedSessionCreated || s.hasBypassedSessionCreatedGate else {
                    s.pendingMessages.append(PendingFrame(text: text, audioBytes: audioBytes))
                    return .queued
                }
                guard let webSocketTask = s.base.webSocketTask else { return .dropped }
                // Counted when handed to the socket, as the Mistral client
                // does: a send that fails as the socket dies over-counts by
                // the frames in flight.
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
                (modelName: String, vocabulary: [String], shouldSendUpdate: Bool, queuedMessages: [PendingFrame])? = self.state
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
                            modelName: modelName, vocabulary: s.pendingVocabulary,
                            shouldSendUpdate: shouldSendUpdate,
                            queuedMessages: queuedMessages
                        )
                    }
            guard let startup else { return }
            self.emit(
                .status("Connected without session.created; using compatibility mode."),
                from: generation)
            if startup.shouldSendUpdate {
                self.send(
                    event: Self.sessionUpdateEvent(model: startup.modelName, vocabulary: startup.vocabulary))
            }
            for message in startup.queuedMessages {
                self.sendText(message.text, audioBytes: message.audioBytes)
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
            (
                error: String?, disconnected: Bool, usage: SocketUsage?,
                generation: RealtimeConnectionGeneration
            ) =
            state.withLock { s in
                guard s.base.socketState != .disconnected, s.base.webSocketTask === task else {
                    return (nil, false, nil, .none)
                }

                let shouldEmitError = !s.base.isUserInitiatedDisconnect
                let generation = s.base.connectionGeneration
                let usage = takeUsageLocked(&s)
                closeSocketLocked(&s, cancelTask: false)
                return (shouldEmitError ? errorMessage : nil, true, usage, generation)
            }
        recordUsage(outcome.usage)

        if let error = outcome.error {
            emit(.error(error), from: outcome.generation)
        }
        if outcome.disconnected {
            emit(.disconnected, from: outcome.generation)
        }
    }

    // MARK: - Usage

    private struct SocketUsage {
        let backend: UsageEntry.Backend
        let model: String
        let audioSeconds: Double
    }

    /// The closing socket's entry, nil when it has no backend or sent no
    /// audio. Resets the counters, so each socket is recorded exactly once
    /// whichever path closes it.
    private func takeUsageLocked(_ s: inout State) -> SocketUsage? {
        defer {
            s.usageBackend = nil
            s.usageModel = ""
            s.sentAudioBytes = 0
        }
        guard let backend = s.usageBackend, s.sentAudioBytes > 0 else { return nil }
        return SocketUsage(
            backend: backend,
            // A user server may take no model name; the ledger needs one.
            model: s.usageModel.isEmpty ? "default" : s.usageModel,
            // 16 kHz mono S16, what the capture pipeline sends both clients.
            audioSeconds: Double(s.sentAudioBytes) / Double(MistralRealtimeWebSocketClient.audioSampleRate * 2)
        )
    }

    private func recordUsage(_ usage: SocketUsage?) {
        guard let usage, let recorder = usageRecorder.withLock({ $0 }) else { return }
        recorder.recordRealtimeDictation(
            date: usageDate(), backend: usage.backend, model: usage.model, audioSeconds: usage.audioSeconds
        )
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
        s.pendingVocabulary = []
    }

    /// The `session.update` frame. `vocabulary` goes out only when non-empty,
    /// so a server that has never heard of it sees the frame it always did.
    static func sessionUpdateEvent(model: String, vocabulary: [String]) -> [String: Any] {
        var event: [String: Any] = ["type": "session.update", "model": model]
        if !vocabulary.isEmpty {
            event["vocabulary"] = vocabulary
        }
        return event
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
    package struct DebugStateSnapshot {
        package let isConnected: Bool
        package let hasPingTimer: Bool
        package let hasSessionReadyTimer: Bool
        package let pendingMessageCount: Int
        package let hasUncommittedAudio: Bool
        package let isGenerationInProgress: Bool
        package let hasReceivedSessionCreated: Bool
        package let isAwaitingFinalCommitDone: Bool
    }

    /// Keeps view-model unit tests on the complete session-start path without
    /// creating a process-retained URLSession or touching a live backend.
    package func debugSkipSocketCreationForTesting() {
        state.withLock { $0.skipsSocketCreationForTesting = true }
    }

    /// The configuration the most recent `connect(configuration:)` was handed,
    /// recorded before the socket-skip check so a socketless test still sees
    /// exactly what the session would have dialled with.
    package func debugLastConnectConfigurationForTesting() -> RealtimeSessionConfiguration? {
        state.withLock { $0.lastConnectConfigurationForTesting }
    }

    package func debugPrimeConnectedStateForTesting(
        task: URLSessionWebSocketTask,
        isUserInitiatedDisconnect: Bool = false,
        hasReceivedSessionCreated: Bool = false,
        usageBackend: UsageEntry.Backend? = nil,
        usageModel: String = ""
    ) {
        state.withLock { s in
            closeSocketLocked(&s, cancelTask: false)
            s.base.connectionGeneration = .next()
            s.base.webSocketTask = task
            s.base.socketState = .connected
            s.base.isUserInitiatedDisconnect = isUserInitiatedDisconnect
            s.hasReceivedSessionCreated = hasReceivedSessionCreated
            s.usageBackend = usageBackend
            s.usageModel = usageModel
            s.sentAudioBytes = 0
            s.pendingMessages = [PendingFrame(text: "pending-message", audioBytes: 0)]
            s.hasUncommittedAudio = true
            s.isGenerationInProgress = true
            startPingTimerLocked(&s)
            startSessionReadyTimerLocked(&s)
        }
    }

    package func debugHandleTerminalSocketErrorForTesting(
        task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        handleTerminalSocketError(for: task, errorMessage: errorMessage)
    }

    /// Put the client where a stop-finalization leaves it: the final commit is
    /// out and the socket owes a `transcription.done` for it.
    package func debugPrimeFinalCommitGateForTesting() {
        state.withLock { $0.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone }
    }

    package func debugSetGenerationTrackingState(
        hasUncommittedAudio: Bool,
        isGenerationInProgress: Bool
    ) {
        state.withLock { s in
            s.hasUncommittedAudio = hasUncommittedAudio
            s.isGenerationInProgress = isGenerationInProgress
            s.finalCommitCompletionGate = .idle
        }
    }

    package func debugStateSnapshot() -> DebugStateSnapshot {
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
