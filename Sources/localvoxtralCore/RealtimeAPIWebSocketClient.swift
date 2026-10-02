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

    /// A rollover under way (#1139): the retiring socket's final commit is
    /// out and the client waits for its `done`. Audio sent meanwhile is
    /// carried to the next socket, never to the retiring one.
    private struct Rollover {
        let retiring: RealtimeConnectionGeneration
        var carried: [Data] = []
        /// The session's own final commit came in during the rollover.
        var stopRequested = false
        var watchdog: Task<Void, Never>?
    }

    private struct State {
        var base = BaseState()
        /// Both sleep on `clock` and are cancelled when the socket closes.
        var pingTimer: Task<Void, Never>?
        var sessionReadyTimer: Task<Void, Never>?
        var hasReceivedSessionCreated = false
        var hasBypassedSessionCreatedGate = false
        var hasSentSessionUpdate = false
        var hasUncommittedAudio = false
        var isGenerationInProgress = false
        var finalCommitCompletionGate: FinalCommitCompletionGate = .idle
        var pendingMessages: [PendingFrame] = []
        /// The handshake's replay of `pendingMessages` is under way: new
        /// frames queue behind it until it has emptied the queue (#1058).
        var isReplayingHandshakeQueue = false
        var pendingModelName = ""
        /// The open socket's ledger line: who serves it, the model it asked
        /// for, and the PCM bytes handed to it. Nil backend records nothing.
        var usageBackend: UsageEntry.Backend?
        var usageModel = ""
        var sentAudioBytes = 0
        /// What the most recent `connect()` dialled; a rollover dials it again.
        var configuration: RealtimeSessionConfiguration?
        var contextBudget: RealtimeContextBudget?
        /// PCM bytes appended on this socket, against `contextBudget`.
        var socketAudioBytes = 0
        /// When this socket last sent transcript text, or sent its first
        /// audio: the start of the quiet a pause is read from.
        var lastTextAt: Date?
        var rollover: Rollover?
        /// The socket a rollover opened has not sent text yet: its first text
        /// starts a new word after the retiring socket's last.
        var startsAfterRollover = false
        /// The socket a rollover dialled is still opening. The session reads
        /// it as connected: the dictation never left its server.
        var isRolloverSocketOpening = false
        #if DEBUG
        var skipsSocketCreationForTesting = false
        var lastConnectConfigurationForTesting: RealtimeSessionConfiguration?
        var beforeHandshakeDrainForTesting: (@Sendable () -> Void)?
        var transmitObserverForTesting: (@Sendable (URLSessionWebSocketTask, String) -> Void)?
        var rolloverSocketForTesting: (@Sendable () -> URLSessionWebSocketTask)?
        var rolloverDialObserverForTesting: (@Sendable (Bool) -> Void)?
        #endif
    }

    /// How long a rollover waits for the retiring socket's `done` before it
    /// opens the next socket anyway.
    package static let rolloverDoneTimeout: Duration = .seconds(5)

    private let state = Mutex(State())
    private let usageRecorder = Mutex<(any RealtimeUsageRecording)?>(nil)
    /// The date a closing socket's usage is filed under; injected so tests
    /// read no wall clock.
    private let usageDate: @Sendable () -> Date
    /// What the rollover's pause is read on and what its watchdog, the
    /// handshake fallback and the keepalive ping sleep on.
    private let clock: SessionClock
    /// How long the client waits for `session.created` before it opens the
    /// send gate itself (compatibility mode).
    package static let sessionCreatedFallbackDelay: Duration = .seconds(3)
    package let supportsPeriodicCommit = true
    package var isConnected: Bool {
        state.withLock { s in
            // A stop polled while a rollover's socket opens must not take it
            // for a dead one and finish without the carried audio (#1139).
            s.base.socketState == .connected || (s.base.socketState == .connecting && s.isRolloverSocketOpening)
        }
    }
    package var connectionGeneration: RealtimeConnectionGeneration {
        state.withLock { $0.base.connectionGeneration }
    }

    package init(usageDate: @escaping @Sendable () -> Date = { Date() }, clock: SessionClock = .live) {
        self.usageDate = usageDate
        self.clock = clock
        super.init()
    }

    package func setContextBudget(_ budget: RealtimeContextBudget?) {
        state.withLock { $0.contextBudget = budget }
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
            s.configuration = configuration
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

        let request = Self.socketRequest(for: configuration)
        debugLog("connect endpoint=\(configuration.endpoint.absoluteString) model=\(configuration.model.trimmed)")

        let previousUsage: SocketUsage? = state.withLock { s in
            s.configuration = configuration
            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            // Stamped in the SAME locked block as the swap. A separate
            // acquisition would leave a window where the outgoing socket is
            // still the current one while the generation has already moved:
            // a frame admitted in that window would come out wearing the new
            // socket's name, which is the failure this whole stamp exists for.
            s.base.connectionGeneration = .next()
            let (session, task) = createWebSocketSession(request: request, delegate: self)
            installSocketLocked(&s, session: session, task: task, configuration: configuration)
            task.resume()
            return usage
        }
        recordUsage(previousUsage)
    }

    private static func socketRequest(for configuration: RealtimeSessionConfiguration) -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 30

        let trimmedAPIKey = configuration.apiKey.trimmed
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        return request
    }

    /// Puts a new, not yet resumed socket in the client's hands, as
    /// `connecting`. The caller has closed the old one and stamped the new
    /// generation in the same locked block.
    private func installSocketLocked(
        _ s: inout State, session: URLSession?, task: URLSessionWebSocketTask?,
        configuration: RealtimeSessionConfiguration
    ) {
        let modelName = configuration.model.trimmed
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
        s.usageBackend = configuration.usageBackend
        s.usageModel = modelName
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
        let now = clock.now()
        let next: ChunkAction = state.withLock { s in
            if s.rollover != nil {
                s.rollover?.carried.append(pcm16Data)
                return .carry
            }
            s.hasUncommittedAudio = true
            s.socketAudioBytes += pcm16Data.count
            if s.lastTextAt == nil { s.lastTextAt = now }
            return rolloverReasonLocked(s, now: now).map(ChunkAction.sendThenRollOver) ?? .send
        }
        if case .carry = next { return }
        debugLog("send append bytes=\(pcm16Data.count)")
        send(event: Self.appendPayload(pcm16Data), audioBytes: pcm16Data.count)
        if case .sendThenRollOver(let reason) = next {
            beginRollover(reason: reason)
        }
    }

    private static func appendPayload(_ pcm16Data: Data) -> [String: Any] {
        [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
    }

    /// A final commit with no run going goes out behind a non-final one
    /// (#1135). vLLM's `/v1/realtime` starts a run only on a non-final commit;
    /// a final one just marks the end of the audio, so on its own it is never
    /// answered: a voice memo, or a stop under `commitInterval` after the
    /// start, waited for its timeout. The run the non-final commit starts reads
    /// up to that mark and sends the one `done` the final commit waits for.
    /// speechd ignores a non-final commit (`RealtimeSpeechServer`), so the
    /// bundled helper still answers only the final one.
    package func sendCommit(final: Bool) {
        let frames: [Bool] = state.withLock { s in
            guard s.base.socketState != .disconnected else { return [] }

            if s.rollover != nil {
                // The retiring socket's final commit is out already. A stop
                // is answered once the carried audio is transcribed; a
                // periodic commit waits for the next socket.
                if final { s.rollover?.stopRequested = true }
                return []
            }

            if final {
                switch s.finalCommitCompletionGate {
                case .idle:
                    break
                case .awaitingFinalCommitTranscriptionDone:
                    return []
                }

                let startsRun = !s.isGenerationInProgress
                s.hasUncommittedAudio = false
                s.isGenerationInProgress = true
                s.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone
                return startsRun ? [false, true] : [true]
            }

            guard s.finalCommitCompletionGate == .idle else { return [] }
            guard s.hasUncommittedAudio else { return [] }
            guard !s.isGenerationInProgress else { return [] }
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = true
            return [false]
        }

        for shouldMarkFinal in frames {
            var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
            if shouldMarkFinal {
                payload["final"] = true
            }
            debugLog("send commit final=\(shouldMarkFinal)")
            send(event: payload)
        }
    }

    // MARK: - Rollover (#1139)

    private enum RolloverReason: String {
        /// A pause inside the window before the limit.
        case pause
        /// The margin before the limit, with no pause in the window.
        case limit
    }

    private enum ChunkAction {
        case send
        case carry
        case sendThenRollOver(RolloverReason)
    }

    /// Whether the socket has taken enough audio to roll over now. Only an
    /// open, handshaked socket with no stop under way rolls over: a stop's
    /// final commit ends the session anyway.
    private func rolloverReasonLocked(_ s: State, now: Date) -> RolloverReason? {
        guard let budget = s.contextBudget,
              s.rollover == nil,
              s.base.socketState == .connected,
              s.hasReceivedSessionCreated || s.hasBypassedSessionCreatedGate,
              s.finalCommitCompletionGate == .idle
        else { return nil }
        if s.socketAudioBytes >= budget.forceBytes { return .limit }
        guard s.socketAudioBytes >= budget.pauseWindowBytes, let lastTextAt = s.lastTextAt else { return nil }
        return now.timeIntervalSince(lastTextAt) + 1e-9 >= RealtimeContextBudget.pauseQuietSeconds ? .pause : nil
    }

    /// Ends the socket's run with a final commit, and carries every chunk sent
    /// from here to the next socket. The commit starts a run first when none
    /// is going, or vLLM would never answer it (#1135).
    private func beginRollover(reason: RolloverReason) {
        let started: (generation: RealtimeConnectionGeneration, frames: [Bool], bytes: Int)? = state.withLock { s in
            guard s.rollover == nil, s.base.socketState == .connected, s.finalCommitCompletionGate == .idle else {
                return nil
            }
            let generation = s.base.connectionGeneration
            s.rollover = Rollover(retiring: generation)
            let startsRun = !s.isGenerationInProgress
            s.hasUncommittedAudio = false
            s.isGenerationInProgress = true
            return (generation, startsRun ? [false, true] : [true], s.socketAudioBytes)
        }
        guard let started else { return }
        Log.backends.notice(
            "realtime rollover starting on connection \(started.generation.description, privacy: .public) at \(String(format: "%.1f", Double(started.bytes) / Double(AudioChunkBuffer.bytesPerSecond)), privacy: .public)s of audio (\(reason.rawValue, privacy: .public))"
        )
        for shouldMarkFinal in started.frames {
            var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
            if shouldMarkFinal {
                payload["final"] = true
            }
            debugLog("send rollover commit final=\(shouldMarkFinal)")
            send(event: payload)
        }

        let clock = clock
        let watchdog = Task { [weak self] in
            await clock.sleep(Self.rolloverDoneTimeout)
            guard !Task.isCancelled else { return }
            self?.finishRollover(retiring: started.generation, cause: "no done within the timeout")
        }
        let armed = state.withLock { s -> Bool in
            guard s.rollover?.retiring == started.generation else { return false }
            s.rollover?.watchdog = watchdog
            return true
        }
        if !armed { watchdog.cancel() }
    }

    private enum RolloverEnd {
        /// The session's stop came in and nothing was carried: the retiring
        /// socket's `done` answers it.
        case finalized
        case switched(
            next: RealtimeConnectionGeneration, dial: RealtimeSessionConfiguration?, usage: SocketUsage?,
            carriedBytes: Int)
        case noConfiguration(stopRequested: Bool)
    }

    /// The retiring socket answered (or will not): close it, open the next
    /// one with the carried audio queued, and hand the session over. `cause`
    /// is nil for the `done` that answers the rollover's final commit.
    private func finishRollover(retiring: RealtimeConnectionGeneration, cause: String?) {
        let now = clock.now()
        let end: RolloverEnd? = state.withLock { s in
            guard let rollover = s.rollover, rollover.retiring == retiring,
                  isCurrentConnectionLocked(s.base, retiring)
            else { return nil }
            rollover.watchdog?.cancel()
            s.rollover = nil
            if rollover.stopRequested, rollover.carried.isEmpty {
                return .finalized
            }

            #if DEBUG
            let testSocket = s.rolloverSocketForTesting
            #else
            let testSocket: (@Sendable () -> URLSessionWebSocketTask)? = nil
            #endif
            // Every socket the client opens latches one; nothing to dial
            // without it, and the carried audio has nowhere to go.
            guard let configuration = s.configuration else {
                return .noConfiguration(stopRequested: rollover.stopRequested)
            }

            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            let next = RealtimeConnectionGeneration.next()
            s.base.connectionGeneration = next
            let dial: RealtimeSessionConfiguration?
            if let testSocket {
                installSocketLocked(&s, session: nil, task: testSocket(), configuration: configuration)
                s.base.socketState = .connected
                dial = nil
            } else {
                // `connecting` with no task yet: the socket itself is created
                // off this queue (`dialRolloverSocket`). Frames sent meanwhile
                // queue for the handshake as they do while any socket opens.
                installSocketLocked(&s, session: nil, task: nil, configuration: configuration)
                s.isRolloverSocketOpening = true
                dial = configuration
            }

            // The carried audio goes out first, behind session.update, then
            // the commit that starts the next socket's run, and the final one
            // when the stop already came in.
            var carriedBytes = 0
            for chunk in rollover.carried {
                guard let text = Self.frameText(Self.appendPayload(chunk)) else { continue }
                s.pendingMessages.append(PendingFrame(text: text, audioBytes: chunk.count))
                carriedBytes += chunk.count
            }
            s.socketAudioBytes = carriedBytes
            s.lastTextAt = now
            s.startsAfterRollover = true
            // The run starts at once, not at the next periodic commit, so the
            // text keeps coming across the seam.
            var commits: [[String: Any]] = [["type": "input_audio_buffer.commit"]]
            if rollover.stopRequested {
                commits.append(["type": "input_audio_buffer.commit", "final": true])
                s.finalCommitCompletionGate = .awaitingFinalCommitTranscriptionDone
            }
            for commit in commits {
                if let text = Self.frameText(commit) {
                    s.pendingMessages.append(PendingFrame(text: text, audioBytes: 0))
                }
            }
            s.isGenerationInProgress = true
            return .switched(next: next, dial: dial, usage: usage, carriedBytes: carriedBytes)
        }

        switch end {
        case nil:
            return
        case .noConfiguration(let stopRequested):
            Log.backends.error(
                "realtime rollover has no configuration to dial; staying on connection \(retiring.description, privacy: .public), carried audio dropped"
            )
            if stopRequested { emit(.transcriptionFinalized, from: retiring) }
        case .finalized:
            Log.backends.notice("realtime rollover ended by the stop, with no audio to carry")
            emit(.transcriptionFinalized, from: retiring)
        case .switched(let next, let dial, let usage, let carriedBytes):
            recordUsage(usage)
            if let cause {
                Log.backends.error(
                    "realtime rollover: connection \(retiring.description, privacy: .public) left without its done (\(cause, privacy: .public)); its untranscribed tail is lost"
                )
            }
            Log.backends.notice(
                "realtime rollover: connection \(retiring.description, privacy: .public) finished; continuing on \(next.description, privacy: .public) with \(String(format: "%.1f", Double(carriedBytes) / Double(AudioChunkBuffer.bytesPerSecond)), privacy: .public)s of carried audio"
            )
            // Before the new socket can raise anything: it does not exist yet.
            emit(.sessionRolledOver(to: next), from: retiring)
            if let dial {
                // Usually on the retiring socket's receive callback. On Linux,
                // swift-corelibs-foundation's `webSocketTask(with:)` syncs onto
                // that same work queue and traps (SIGILL, found by the live
                // take on #1147), so the socket is created elsewhere on every
                // platform.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.dialRolloverSocket(next, configuration: dial)
                }
            }
        }
    }

    /// Creates and resumes the socket a rollover switched to, unless the
    /// client moved on meanwhile (a disconnect, a new `connect()`).
    private func dialRolloverSocket(
        _ generation: RealtimeConnectionGeneration, configuration: RealtimeSessionConfiguration
    ) {
        let (session, task) = createWebSocketSession(
            request: Self.socketRequest(for: configuration), delegate: self)
        let installed: Bool = state.withLock { s in
            guard isCurrentConnectionLocked(s.base, generation),
                  s.base.socketState == .connecting, s.base.webSocketTask == nil
            else { return false }
            s.base.urlSession = session
            s.base.webSocketTask = task
            return true
        }
        #if DEBUG
        state.withLock { $0.rolloverDialObserverForTesting }?(installed)
        #endif
        guard installed else {
            Log.backends.notice(
                "realtime rollover: connection \(generation.description, privacy: .public) was given up before it was dialled"
            )
            session.invalidateAndCancel()
            return
        }
        task.resume()
    }

    private static func frameText(_ event: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first text a rolled-over socket sends gets a leading space when it
    /// has none: the server starts a fresh transcript, and its first word
    /// would otherwise run into the retiring socket's last.
    private func textAfterRollover(_ text: String, from generation: RealtimeConnectionGeneration) -> String {
        let now = clock.now()
        let prefixes: Bool = state.withLock { s in
            guard isCurrentConnectionLocked(s.base, generation),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            s.lastTextAt = now
            guard s.startsAfterRollover else { return false }
            s.startsAfterRollover = false
            return text.first?.isWhitespace == false
        }
        return prefixes ? " " + text : text
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
            let opened: Bool = state.withLock { s in
                // The socket this frame was read from, not whichever one
                // the client holds now: a stale handshake applied here
                // drains the NEW socket's queue ahead of its own
                // session.update.
                guard isCurrentConnectionLocked(s.base, generation) else { return false }
                guard s.base.socketState == .connected else { return false }
                guard !s.hasReceivedSessionCreated else { return false }
                s.hasReceivedSessionCreated = true
                stopSessionReadyTimerLocked(&s)
                // The compatibility timer opened the gate already, and its
                // replay may still be draining: a second one would race it.
                guard !s.hasBypassedSessionCreatedGate else { return false }
                openSendGateLocked(&s)
                return true
            }
            guard opened else { return }
            #if DEBUG
            state.withLock { $0.beforeHandshakeDrainForTesting }?()
            #endif
            replayHandshakeQueue(for: generation)
        case "session.updated":
            emit(.status("Session updated."), from: generation)
        case "transcription.delta",
            "response.audio_transcript.delta",
            "conversation.item.input_audio_transcription.delta":
            if let delta = findString(in: json, matching: ["delta", "text", "transcript"]) {
                emit(.partialTranscript(textAfterRollover(delta, from: generation)), from: generation)
            }
        case "transcription.done",
            "response.audio_transcript.done",
            "conversation.item.input_audio_transcription.completed":
            enum DoneAction {
                case none
                case emitTranscriptionFinalized
                case finishRollover
            }

            let doneAction: DoneAction = state.withLock { s in
                // A `done` the retiring socket was read for must not clear the
                // commit gate its replacement is still waiting on.
                guard isCurrentConnectionLocked(s.base, generation) else { return .none }
                s.isGenerationInProgress = false
                if s.rollover != nil { return .finishRollover }

                switch s.finalCommitCompletionGate {
                case .idle:
                    return .none
                case .awaitingFinalCommitTranscriptionDone:
                    s.finalCommitCompletionGate = .idle
                    return .emitTranscriptionFinalized
                }
            }
            if let text = findString(in: json, matching: ["text", "transcript", "delta"]) {
                emit(.finalTranscript(textAfterRollover(text, from: generation)), from: generation)
            }
            switch doneAction {
            case .none:
                break
            case .emitTranscriptionFinalized:
                emit(.transcriptionFinalized, from: generation)
            case .finishRollover:
                finishRollover(retiring: generation, cause: nil)
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
                // Behind the handshake's replay too: sent now, this frame
                // would pass session.update and the audio queued before it.
                guard s.hasReceivedSessionCreated || s.hasBypassedSessionCreatedGate,
                      !s.isReplayingHandshakeQueue
                else {
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
        transmit(payloadText, on: task)
    }

    /// The handshake, or the compatibility timer standing in for it, opens
    /// the send gate: session.update goes to the front of the queue, and
    /// frames sent from here on queue behind the replay.
    private func openSendGateLocked(_ s: inout State) {
        let modelName = s.pendingModelName
        if !s.hasSentSessionUpdate, !modelName.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["type": "session.update", "model": modelName]),
           let text = String(data: data, encoding: .utf8) {
            s.hasSentSessionUpdate = true
            s.pendingMessages.insert(PendingFrame(text: text, audioBytes: 0), at: 0)
            debugLog("queue event type=session.update")
        }
        s.isReplayingHandshakeQueue = true
    }

    /// Sends what queued before the gate opened, then whatever queued while
    /// those were being sent, until the queue is empty; only then do frames
    /// go straight to the socket again. It stops, sending nothing more, once
    /// the socket that opened the gate is no longer this client's: its
    /// replacement keeps its own queue (#1058).
    private func replayHandshakeQueue(for generation: RealtimeConnectionGeneration) {
        while true {
            let batch: (task: URLSessionWebSocketTask, frames: [PendingFrame])? = state.withLock { s in
                guard isCurrentConnectionLocked(s.base, generation), s.base.socketState == .connected,
                      let task = s.base.webSocketTask
                else { return nil }
                guard !s.pendingMessages.isEmpty else {
                    s.isReplayingHandshakeQueue = false
                    return nil
                }
                let frames = s.pendingMessages
                s.pendingMessages.removeAll(keepingCapacity: true)
                s.sentAudioBytes += frames.reduce(0) { $0 + $1.audioBytes }
                return (task, frames)
            }
            guard let batch else { return }
            for frame in batch.frames {
                transmit(frame.text, on: batch.task)
            }
        }
    }

    private func transmit(_ text: String, on task: URLSessionWebSocketTask) {
        #if DEBUG
        state.withLock { $0.transmitObserverForTesting }?(task, text)
        #endif

        task.send(.string(text)) { [weak self] error in
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

        let clock = clock
        s.pingTimer = Task { [weak self] in
            while true {
                await clock.sleep(Self.keepalivePingInterval)
                guard !Task.isCancelled, let self else { return }
                self.sendKeepalivePing()
            }
        }
    }

    private func sendKeepalivePing() {
        let task: URLSessionWebSocketTask? = state.withLock { s in
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

    private func startSessionReadyTimerLocked(_ s: inout State) {
        stopSessionReadyTimerLocked(&s)

        // The socket this timer is armed for. A close cancels the timer, but a
        // handler already in flight would otherwise announce compatibility mode
        // under whatever name the client had picked up by then.
        let generation = s.base.connectionGeneration
        let clock = clock
        s.sessionReadyTimer = Task { [weak self] in
            await clock.sleep(Self.sessionCreatedFallbackDelay)
            guard !Task.isCancelled else { return }
            self?.bypassSessionCreatedGate(for: generation)
        }
    }

    /// No `session.created` within the timer: compatibility mode opens the
    /// gate itself.
    private func bypassSessionCreatedGate(for generation: RealtimeConnectionGeneration) {
        let opened: Bool = state.withLock { s in
            // A cancelled wait can already be past its cancellation
            // check: without this, a timer armed for the previous socket
            // puts the NEW one into compatibility mode and flushes its
            // queue early.
            guard isCurrentConnectionLocked(s.base, generation) else { return false }
            guard s.base.socketState == .connected else { return false }
            guard !s.hasReceivedSessionCreated else { return false }
            stopSessionReadyTimerLocked(&s)
            s.hasBypassedSessionCreatedGate = true
            openSendGateLocked(&s)
            return true
        }
        guard opened else { return }
        emit(
            .status("Connected without session.created; using compatibility mode."),
            from: generation)
        replayHandshakeQueue(for: generation)
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
        // The retiring socket died before its `done` (a 1012 from a server
        // that ran out of context, say): the session goes on to the next
        // socket with the carried audio rather than through a reconnect,
        // which would drop it.
        let retiring: RealtimeConnectionGeneration? = state.withLock { s in
            guard s.base.socketState != .disconnected, s.base.webSocketTask === task,
                  let rollover = s.rollover, !s.base.isUserInitiatedDisconnect
            else { return nil }
            return rollover.retiring
        }
        if let retiring {
            finishRollover(retiring: retiring, cause: errorMessage ?? "socket closed")
            return
        }

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
        s.isReplayingHandshakeQueue = false
        s.pendingModelName = ""
        s.rollover?.watchdog?.cancel()
        s.rollover = nil
        s.socketAudioBytes = 0
        s.lastTextAt = nil
        s.startsAfterRollover = false
        s.isRolloverSocketOpening = false
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
        package let contextBudget: RealtimeContextBudget?
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

    /// Runs between the handshake opening the send gate and the queue
    /// replay, so a test can send or swap the socket there (#1058).
    package func debugSetBeforeHandshakeDrain(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.beforeHandshakeDrainForTesting = hook }
    }

    /// What the session-ready timer does when it fires, run now.
    package func debugBypassSessionCreatedGateForTesting() {
        bypassSessionCreatedGate(for: connectionGeneration)
    }

    /// A rollover installs the socket this returns, already open, instead of
    /// dialling: the test then plays its handshake.
    package func debugSetRolloverSocket(_ opener: (@Sendable () -> URLSessionWebSocketTask)?) {
        state.withLock { $0.rolloverSocketForTesting = opener }
    }

    /// Hears each socket a rollover dials: true once it is installed,
    /// false when the client had moved on.
    package func debugObserveRolloverDial(_ observer: (@Sendable (Bool) -> Void)?) {
        state.withLock { $0.rolloverDialObserverForTesting = observer }
    }

    /// Hears every frame as it is handed to a socket, in order.
    package func debugObserveTransmits(_ observer: (@Sendable (URLSessionWebSocketTask, String) -> Void)?) {
        state.withLock { $0.transmitObserverForTesting = observer }
    }

    package func debugPrimeConnectedStateForTesting(
        task: URLSessionWebSocketTask,
        isUserInitiatedDisconnect: Bool = false,
        hasReceivedSessionCreated: Bool = false,
        usageBackend: UsageEntry.Backend? = nil,
        usageModel: String = "",
        modelName: String = ""
    ) {
        state.withLock { s in
            closeSocketLocked(&s, cancelTask: false)
            s.pendingModelName = modelName
            s.configuration = RealtimeSessionConfiguration(
                endpoint: task.originalRequest?.url ?? URL(string: "ws://127.0.0.1/v1/realtime")!,
                apiKey: "",
                model: modelName,
                usageBackend: usageBackend
            )
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
                    == .awaitingFinalCommitTranscriptionDone,
                contextBudget: s.contextBudget
            )
        }
    }
}
#endif
