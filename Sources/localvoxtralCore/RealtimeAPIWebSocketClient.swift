import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

package final class RealtimeAPIWebSocketClient: BaseRealtimeWebSocketClient, @unchecked Sendable, RealtimeClient {
    /// What a commit does on the server the socket reached, read from its
    /// `session.created` (#1943).
    private enum CommitProtocol {
        /// vLLM and speechd: a non-final commit starts a run that lasts until
        /// the final commit, which the one `done` answers.
        case runUntilFinal
        /// llama-server (`realtime.transcription_session`): every commit closes
        /// an item, answered by its own `completed`; audio is transcribed with
        /// no commit at all. A non-final commit pads the stream with ~1.4 s of
        /// silence and its `completed` would pass for the final's answer, so
        /// the client sends none: only the final commit, at a stop or a
        /// rollover.
        case itemPerCommit
    }

    /// A frame held until the handshake, with the PCM it carries (nil for a
    /// control frame): audio is counted only once it is sent, and a socket
    /// that closes first hands it back to the session (#1672).
    private struct PendingFrame {
        let text: String
        var audio: Data?
        /// A non-final commit, dropped at the handshake of an
        /// `itemPerCommit` server.
        var isNonFinalCommit = false
        var audioBytes: Int { audio?.count ?? 0 }
    }

    /// A rollover under way (#1139): the retiring socket's final commit is
    /// out and the client waits for its `done`. Audio sent meanwhile is
    /// carried to the next socket, never to the retiring one.
    private struct Rollover {
        let retiring: RealtimeConnectionGeneration
        var carried: [Data] = []
        /// The session's own final commit came in during the rollover.
        var stopRequested = false
        /// The retiring socket's `done` is in: it ends the rollover once its
        /// final is out, and nothing else may end it first (#1459).
        var isDoneAccepted = false
        var watchdog: Task<Void, Never>?
    }

    /// Who opened the socket.
    private enum SocketOrigin: Equatable {
        /// `connect()`.
        case connect
        /// A rollover (#1139). Until this socket sends text its first text
        /// starts a new word after the retiring socket's last, and while it
        /// opens the session reads it as connected: the dictation never left
        /// its server.
        case rollover(awaitingFirstText: Bool)
    }

    /// What one socket holds. `connect()` and a rollover's switch install a
    /// fresh one; a close drops it whole, so nothing of one socket reaches
    /// the next.
    private struct OpenSocket {
        /// The configuration's model, `contextBias` and `language`, sent in
        /// the socket's one `session.update`.
        let modelName: String
        let contextBias: [String]
        let language: String?
        /// The socket's ledger line: who serves it, the model it asked for,
        /// and the PCM bytes handed to it. Nil backend records nothing.
        let usageBackend: UsageEntry.Backend?
        let usageModel: String
        var sentAudioBytes = 0
        var origin: SocketOrigin
        var handshake: RealtimeHandshake = .awaitingSessionCreated
        /// Audio appended since the last commit, and a run going on the
        /// server. Every pair is reachable (audio arrives during a run), so
        /// they stay two flags.
        var hasUncommittedAudio = false
        var isGenerationInProgress = false
        /// Once `answered`, llama-server closes the socket at once and macOS
        /// reads that close as a receive error (#1943): from there a failure
        /// is the socket's end, not an error.
        var finalCommit: RealtimeFinalCommit = .notSent
        var pendingMessages: [PendingFrame] = []
        /// PCM bytes appended on this socket, against `contextBudget`.
        var socketAudioBytes = 0
        /// When this socket last sent transcript text, or sent its first
        /// audio: the start of the quiet a pause is read from.
        var lastTextAt: Date?
        /// A rollover retiring this socket.
        var rollover: Rollover?
        /// The server going quiet while this socket's audio still goes out:
        /// a hung speechd or External URL server sends no error and no close
        /// (#1866). Starts with the socket's first audio.
        var health: MistralStreamHealth?
    }

    private struct State {
        var base = BaseState()
        /// Both sleep on `clock` and are cancelled when the socket closes.
        var pingTimer: Task<Void, Never>?
        var sessionReadyTimer: Task<Void, Never>?
        /// The socket the client holds, from its install until it closes:
        /// nil exactly when `base.socketState` is `.disconnected`.
        var socket: OpenSocket?
        /// Kept across a rollover, which dials the same server; a `connect()`
        /// learns it again from the next `session.created`.
        var commitProtocol: CommitProtocol = .runUntilFinal
        /// Audio a socket closed on before sending it: queued for its
        /// handshake, the carried audio of a rollover above all. No server
        /// took it, so the session replays it on the next socket (#1672).
        var unsentAudio = Data()
        /// What the most recent `connect()` dialled; a rollover dials it again.
        var configuration: RealtimeSessionConfiguration?
        var contextBudget: RealtimeContextBudget?
        #if DEBUG
        var silenceLogForTesting: [String] = []
        var skipsSocketCreationForTesting = false
        var lastConnectConfigurationForTesting: RealtimeSessionConfiguration?
        var beforeHandshakeDrainForTesting: (@Sendable () -> Void)?
        var transmitObserverForTesting: (@Sendable (URLSessionWebSocketTask, String) -> Void)?
        var rolloverSocketForTesting: (@Sendable () -> URLSessionWebSocketTask)?
        var rolloverDialObserverForTesting: (@Sendable (Bool) -> Void)?
        var beforeTerminalErrorCloseForTesting: (@Sendable () -> Void)?
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
            switch (s.base.socketState, s.socket?.origin) {
            case (.connected, _), (.connecting, .rollover): return true
            default: return false
            }
        }
    }
    package var isSessionReady: Bool {
        state.withLock { s in
            // A rollover holds the audio it carries until the retiring
            // socket's `done`, up to `rolloverDoneTimeout`.
            s.base.socketState == .connected && s.socket?.handshake.isSendGateOpen == true
                && s.socket?.rollover == nil
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
            // A new session or a reconnect: the one that could have replayed
            // it has taken it or moved on.
            s.unsentAudio.removeAll()
            s.commitProtocol = .runUntilFinal
            let usage = takeUsageLocked(&s)
            closeSocketLocked(&s, cancelTask: true)
            // Stamped in the SAME locked block as the swap. A separate
            // acquisition would leave a window where the outgoing socket is
            // still the current one while the generation has already moved:
            // a frame admitted in that window would come out wearing the new
            // socket's name, which is the failure this whole stamp exists for.
            s.base.connectionGeneration = .next()
            let (session, task) = createWebSocketSession(request: request, delegate: self)
            installSocketLocked(&s, session: session, task: task, configuration: configuration, origin: .connect)
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
    /// `connecting`, with a fresh `OpenSocket`. The caller has closed the old
    /// one, which dropped its `OpenSocket`, and stamped the new generation in
    /// the same locked block.
    private func installSocketLocked(
        _ s: inout State, session: URLSession?, task: URLSessionWebSocketTask?,
        configuration: RealtimeSessionConfiguration, origin: SocketOrigin
    ) {
        let modelName = configuration.model.trimmed
        s.base.urlSession = session
        s.base.webSocketTask = task
        s.base.socketState = .connecting
        s.socket = OpenSocket(
            modelName: modelName,
            contextBias: configuration.contextBias,
            language: configuration.language,
            usageBackend: configuration.usageBackend,
            usageModel: modelName,
            origin: origin)
    }

    package func disconnect() {
        let (closed, usage): (RealtimeConnectionGeneration?, SocketUsage?) = state.withLock { s in
            guard s.base.socketState != .disconnected else { return (nil, nil) }
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

    @discardableResult
    package func sendAudioChunk(_ pcm16Data: Data) -> Bool {
        guard !pcm16Data.isEmpty else { return true }
        let now = clock.now()
        let next: ChunkAction = state.withLock { s in
            if s.socket?.rollover != nil {
                s.socket?.rollover?.carried.append(pcm16Data)
                return .carry
            }
            s.socket?.hasUncommittedAudio = true
            s.socket?.socketAudioBytes += pcm16Data.count
            if s.socket?.lastTextAt == nil { s.socket?.lastTextAt = now }
            return rolloverReasonLocked(s, now: now).map(ChunkAction.sendThenRollOver) ?? .send
        }
        if case .carry = next { return true }
        debugLog("send append bytes=\(pcm16Data.count)")
        guard send(event: Self.appendPayload(pcm16Data), audio: pcm16Data) else { return false }
        if case .sendThenRollOver(let reason) = next {
            beginRollover(reason: reason)
        }
        return true
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
            guard s.base.socketState != .disconnected, let socket = s.socket else { return [] }

            if socket.rollover != nil {
                // The retiring socket's final commit is out already. A stop
                // is answered once the carried audio is transcribed; a
                // periodic commit waits for the next socket.
                if final { s.socket?.rollover?.stopRequested = true }
                return []
            }

            if final {
                guard socket.finalCommit != .awaitingDone else { return [] }
                let startsRun = !socket.isGenerationInProgress && s.commitProtocol == .runUntilFinal
                s.socket?.hasUncommittedAudio = false
                s.socket?.isGenerationInProgress = true
                s.socket?.finalCommit.move(to: .awaitingDone, onRefused: reportUnexpectedMove)
                return startsRun ? [false, true] : [true]
            }

            guard s.commitProtocol == .runUntilFinal else { return [] }
            guard socket.finalCommit != .awaitingDone else { return [] }
            guard socket.hasUncommittedAudio else { return [] }
            guard !socket.isGenerationInProgress else { return [] }
            s.socket?.hasUncommittedAudio = false
            s.socket?.isGenerationInProgress = true
            return [false]
        }

        for shouldMarkFinal in frames {
            var payload: [String: Any] = ["type": "input_audio_buffer.commit"]
            if shouldMarkFinal {
                payload["final"] = true
            }
            debugLog("send commit final=\(shouldMarkFinal)")
            send(event: payload, isNonFinalCommit: !shouldMarkFinal)
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
              let socket = s.socket,
              socket.rollover == nil,
              s.base.socketState == .connected,
              socket.handshake.isSendGateOpen,
              socket.finalCommit != .awaitingDone
        else { return nil }
        if socket.socketAudioBytes >= budget.forceBytes { return .limit }
        guard socket.socketAudioBytes >= budget.pauseWindowBytes, let lastTextAt = socket.lastTextAt else { return nil }
        return now.timeIntervalSince(lastTextAt) + 1e-9 >= RealtimeContextBudget.pauseQuietSeconds ? .pause : nil
    }

    /// Ends the socket's run with a final commit, and carries every chunk sent
    /// from here to the next socket. The commit starts a run first when none
    /// is going, or vLLM would never answer it (#1135).
    private func beginRollover(reason: RolloverReason) {
        let started: (generation: RealtimeConnectionGeneration, frames: [Bool], bytes: Int)? = state.withLock { s in
            guard let socket = s.socket, socket.rollover == nil, s.base.socketState == .connected,
                  socket.finalCommit != .awaitingDone
            else {
                return nil
            }
            let generation = s.base.connectionGeneration
            s.socket?.rollover = Rollover(retiring: generation)
            let startsRun = !socket.isGenerationInProgress && s.commitProtocol == .runUntilFinal
            s.socket?.hasUncommittedAudio = false
            s.socket?.isGenerationInProgress = true
            return (generation, startsRun ? [false, true] : [true], socket.socketAudioBytes)
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
            // Only to the retiring socket: one that failed as the first
            // commit went out was replaced, and its final would end the
            // replacement's run while the user still talks (#1725).
            guard send(event: payload, onlyTo: started.generation) else {
                Log.backends.notice(
                    "realtime rollover: connection \(started.generation.description, privacy: .public) went before its commits were out; the rest dropped"
                )
                break
            }
        }

        let clock = clock
        let watchdog = Task { [weak self] in
            await clock.sleep(Self.rolloverDoneTimeout)
            guard !Task.isCancelled else { return }
            self?.finishRollover(retiring: started.generation, cause: "no done within the timeout")
        }
        let armed = state.withLock { s -> Bool in
            guard s.socket?.rollover?.retiring == started.generation else { return false }
            s.socket?.rollover?.watchdog = watchdog
            return true
        }
        if !armed { watchdog.cancel() }
    }

    /// The cause a rollover reports for a close that carried no error text.
    private static let plainSocketCloseCause = "socket closed"

    private enum RolloverEnd {
        /// The session's stop came in and nothing was carried: the retiring
        /// socket's `done` answers it.
        case finalized
        /// The same stop, but the retiring socket failed or timed out first.
        case endedWithoutDone(usage: SocketUsage?)
        case switched(
            next: RealtimeConnectionGeneration, dial: RealtimeSessionConfiguration?, usage: SocketUsage?,
            carriedBytes: Int)
        case noConfiguration
    }

    /// The retiring socket answered (or will not): close it, open the next
    /// one with the carried audio queued, and hand the session over. `cause`
    /// is nil for the `done` that answers the rollover's final commit.
    private func finishRollover(
        retiring: RealtimeConnectionGeneration, cause: String?, doneType: String = "transcription.done"
    ) {
        let now = clock.now()
        let uptime = clock.uptime()
        // The `done` is the retiring socket's last event, and closing it drops
        // its health: end a reported stall here, where `noteServerEvent` can
        // no longer reach it.
        var resumedAfter: TimeInterval?
        let end: RolloverEnd? = state.withLock { s in
            guard let rollover = s.socket?.rollover, rollover.retiring == retiring,
                  isCurrentConnectionLocked(s.base, retiring),
                  cause == nil || !rollover.isDoneAccepted
            else { return nil }
            rollover.watchdog?.cancel()
            s.socket?.rollover = nil
            if rollover.stopRequested, rollover.carried.isEmpty {
                if cause == nil { return .finalized }
                // The retiring socket left without the `done` that answers
                // the stop: the stop ends as a socket closed at stop does,
                // and the controller keeps its missing-end warning.
                let usage = takeUsageLocked(&s)
                closeSocketLocked(&s, cancelTask: true)
                return .endedWithoutDone(usage: usage)
            }

            #if DEBUG
            let testSocket = s.rolloverSocketForTesting
            #else
            let testSocket: (@Sendable () -> URLSessionWebSocketTask)? = nil
            #endif
            // Every socket the client opens latches one; nothing to dial
            // without it, and the carried audio has nowhere to go.
            guard let configuration = s.configuration else {
                if rollover.stopRequested {
                    // The stop's final commit had nowhere to go: no claim of
                    // a final, the stop ends as a closed socket does.
                    let usage = takeUsageLocked(&s)
                    closeSocketLocked(&s, cancelTask: true)
                    return .endedWithoutDone(usage: usage)
                }
                return .noConfiguration
            }

            let usage = takeUsageLocked(&s)
            if cause == nil {
                resumedAfter = s.socket?.health?.serverEvent(at: uptime) ?? nil
            }
            closeSocketLocked(&s, cancelTask: true)
            let next = RealtimeConnectionGeneration.next()
            s.base.connectionGeneration = next
            let dial: RealtimeSessionConfiguration?
            let origin = SocketOrigin.rollover(awaitingFirstText: true)
            if let testSocket {
                installSocketLocked(&s, session: nil, task: testSocket(), configuration: configuration, origin: origin)
                s.base.socketState = .connected
                dial = nil
            } else {
                // `connecting` with no task yet: the socket itself is created
                // off this queue (`dialRolloverSocket`). Frames sent meanwhile
                // queue for the handshake as they do while any socket opens.
                installSocketLocked(&s, session: nil, task: nil, configuration: configuration, origin: origin)
                dial = configuration
            }

            // The carried audio goes out first, behind session.update, then
            // the commit that starts the next socket's run, and the final one
            // when the stop already came in.
            var carriedBytes = 0
            for chunk in rollover.carried {
                guard let text = Self.frameText(Self.appendPayload(chunk)) else { continue }
                s.socket?.pendingMessages.append(PendingFrame(text: text, audio: chunk))
                carriedBytes += chunk.count
            }
            s.socket?.socketAudioBytes = carriedBytes
            s.socket?.lastTextAt = now
            // The run starts at once, not at the next periodic commit, so the
            // text keeps coming across the seam. An `itemPerCommit` server
            // transcribes without one.
            var commits: [[String: Any]] = []
            if s.commitProtocol == .runUntilFinal {
                commits.append(["type": "input_audio_buffer.commit"])
            }
            if rollover.stopRequested {
                commits.append(["type": "input_audio_buffer.commit", "final": true])
                s.socket?.finalCommit.move(to: .awaitingDone, onRefused: reportUnexpectedMove)
            }
            for commit in commits {
                if let text = Self.frameText(commit) {
                    s.socket?.pendingMessages.append(
                        PendingFrame(text: text, isNonFinalCommit: commit["final"] == nil))
                }
            }
            s.socket?.isGenerationInProgress = true
            return .switched(next: next, dial: dial, usage: usage, carriedBytes: carriedBytes)
        }

        switch end {
        case nil:
            return
        case .noConfiguration:
            Log.backends.error(
                "realtime rollover has no configuration to dial; staying on connection \(retiring.description, privacy: .public), carried audio dropped"
            )
        case .finalized:
            Log.backends.notice("realtime rollover ended by the stop, with no audio to carry")
            emit(.transcriptionFinalized, from: retiring)
        case .endedWithoutDone(let usage):
            recordUsage(usage)
            Log.backends.error(
                "realtime rollover ended by the stop, but connection \(retiring.description, privacy: .public) left without its done (\(cause ?? "", privacy: .public)); no final claimed"
            )
            if let cause, cause != Self.plainSocketCloseCause { emit(.error(cause), from: retiring) }
            emit(.disconnected, from: retiring)
        case .switched(let next, let dial, let usage, let carriedBytes):
            if let resumedAfter {
                logServerSilence(
                    "realtime server resumed after \(String(format: "%.1f", resumedAfter))s of silence (\(doneType))")
            }
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

    /// llama-server's `session.created` carries an OpenAI transcription
    /// session object; vLLM's carries none and speechd's names no object.
    static func isItemPerCommitSession(_ json: [String: Any]) -> Bool {
        (json["session"] as? [String: Any])?["object"] as? String == "realtime.transcription_session"
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
            s.socket?.lastTextAt = now
            guard s.socket?.origin == .rollover(awaitingFirstText: true) else { return false }
            s.socket?.origin = .rollover(awaitingFirstText: false)
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
        // After the event's own handling, which reads the clock first.
        defer { noteServerEvent(type, from: generation) }

        switch type {
        case "session.created":
            emit(.status("Session ready."), from: generation)
            let opened: Bool = state.withLock { s in
                // The socket this frame was read from, not whichever one
                // the client holds now: a stale handshake applied here
                // drains the NEW socket's queue ahead of its own
                // session.update.
                guard isCurrentConnectionLocked(s.base, generation) else { return false }
                guard s.base.socketState == .connected, let handshake = s.socket?.handshake,
                      !handshake.hasReceivedSessionCreated
                else { return false }
                stopSessionReadyTimerLocked(&s)
                if Self.isItemPerCommitSession(json) {
                    if s.commitProtocol != .itemPerCommit {
                        Log.backends.notice(
                            "realtime server opens a transcription session (llama-server): no periodic commits, final commits only"
                        )
                    }
                    s.commitProtocol = .itemPerCommit
                    // Queued before the server was known: each would close an
                    // item and pad the audio with silence.
                    s.socket?.pendingMessages.removeAll { $0.isNonFinalCommit }
                    s.socket?.isGenerationInProgress = false
                }
                // The compatibility timer opened the gate already, and its
                // replay may still be draining: a second one would race it.
                if case .gateOpen(let replaying, sessionCreated: false) = handshake {
                    s.socket?.handshake.move(
                        to: .gateOpen(replaying: replaying, sessionCreated: true), onRefused: reportUnexpectedMove)
                    return false
                }
                openSendGateLocked(&s, sessionCreated: true)
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
                s.socket?.isGenerationInProgress = false
                if s.socket?.rollover != nil {
                    s.socket?.rollover?.isDoneAccepted = true
                    return .finishRollover
                }

                guard s.socket?.finalCommit == .awaitingDone else { return .none }
                s.socket?.finalCommit.move(to: .answered, onRefused: reportUnexpectedMove)
                return .emitTranscriptionFinalized
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
                finishRollover(retiring: generation, cause: nil, doneType: type)
            }
        case "error":
            state.withLock { s in
                guard isCurrentConnectionLocked(s.base, generation) else { return }
                s.socket?.isGenerationInProgress = false
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
        state.withLock { s in
            // A disconnect between the open and this call has already stopped
            // the timers; arming them now would leave a ping loop running on a
            // closed client.
            guard s.base.webSocketTask === webSocketTask, s.base.socketState == .connected else { return }
            startPingTimerLocked(&s)
            startSessionReadyTimerLocked(&s)
        }
    }

    // MARK: - Send Helpers

    private enum SendAction: Sendable {
        case send(task: URLSessionWebSocketTask, text: String, audioBytes: Int, stall: MistralStreamHealth.StallReport?)
        case queued
        case dropped
    }

    /// False when the frame went nowhere: no socket, or no frame to send.
    /// `onlyTo` is the connection whose rollover sends the frame: once it has
    /// been replaced, the frame is dropped.
    @discardableResult
    private func send(
        event: [String: Any], audio: Data? = nil, onlyTo retiring: RealtimeConnectionGeneration? = nil,
        isNonFinalCommit: Bool = false
    ) -> Bool {
        guard JSONSerialization.isValidJSONObject(event) else {
            emit(.error("Invalid JSON payload generated."), from: currentConnectionGeneration)
            return false
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.error("Failed to encode WebSocket frame."), from: currentConnectionGeneration)
                return false
            }

            if let type = event["type"] as? String {
                debugLog("queue event type=\(type)")
            }
            return sendText(text, audio: audio, onlyTo: retiring, isNonFinalCommit: isNonFinalCommit)
        } catch {
            emit(
                .error("Failed to serialize WebSocket payload: \(error.localizedDescription)"),
                from: currentConnectionGeneration)
            return false
        }
    }

    @discardableResult
    private func sendText(
        _ text: String, audio: Data? = nil, onlyTo retiring: RealtimeConnectionGeneration? = nil,
        isNonFinalCommit: Bool = false
    ) -> Bool {
        let action: SendAction = state.withLock { s in
            if let retiring, s.socket?.rollover?.retiring != retiring { return .dropped }
            // Chosen before a handshake that named llama-server took the
            // lock: the queue filter ran without it (#1943).
            if isNonFinalCommit, s.commitProtocol == .itemPerCommit { return .dropped }
            switch s.base.socketState {
            case .connected:
                // Behind the handshake's replay too: sent now, this frame
                // would pass session.update and the audio queued before it.
                guard let handshake = s.socket?.handshake, handshake.isSendGateOpen, !handshake.isReplayingQueue
                else {
                    s.socket?.pendingMessages.append(
                        PendingFrame(text: text, audio: audio, isNonFinalCommit: isNonFinalCommit))
                    return .queued
                }
                guard let webSocketTask = s.base.webSocketTask else { return .dropped }
                // Counted when handed to the socket, as the Mistral client
                // does: a send that fails as the socket dies over-counts by
                // the frames in flight.
                s.socket?.sentAudioBytes += audio?.count ?? 0
                let stall = admitLocked(&s, audio: audio)
                return .send(task: webSocketTask, text: text, audioBytes: audio?.count ?? 0, stall: stall)
            case .connecting:
                s.socket?.pendingMessages.append(
                    PendingFrame(text: text, audio: audio, isNonFinalCommit: isNonFinalCommit))
                return .queued
            case .disconnected:
                return .dropped
            }
        }

        switch action {
        case .send(let task, let payloadText, let audioBytes, let stall):
            transmit(payloadText, audioBytes: audioBytes, stall: stall, on: task)
            return true
        case .queued:
            return true
        case .dropped:
            return false
        }
    }

    /// The handshake, or the compatibility timer standing in for it, opens
    /// the send gate, once per socket: session.update goes to the front of
    /// the queue, and frames sent from here on queue behind the replay.
    private func openSendGateLocked(_ s: inout State, sessionCreated: Bool) {
        guard let modelName = s.socket?.modelName else { return }
        if !modelName.isEmpty,
           let text = Self.sessionUpdateFrame(
               model: modelName, contextBias: s.socket?.contextBias ?? [], language: s.socket?.language) {
            s.socket?.pendingMessages.insert(PendingFrame(text: text), at: 0)
            debugLog("queue event type=session.update")
        }
        s.socket?.handshake.move(
            to: .gateOpen(replaying: true, sessionCreated: sessionCreated), onRefused: reportUnexpectedMove)
    }

    /// The socket's one `session.update`. The term list rides it as
    /// `context_bias`, the field Mistral's realtime API reads, only when the
    /// model takes terms, and the dictation language as `language` only when
    /// the model takes one: every other server gets the frame it always did.
    package static func sessionUpdateFrame(
        model: String, contextBias: [String], language: String? = nil
    ) -> String? {
        var frame: [String: Any] = ["type": "session.update", "model": model]
        if !contextBias.isEmpty { frame["context_bias"] = contextBias }
        if let language { frame["language"] = language }
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Sends what queued before the gate opened, then whatever queued while
    /// those were being sent, until the queue is empty; only then do frames
    /// go straight to the socket again. It stops, sending nothing more, once
    /// the socket that opened the gate is no longer this client's: its
    /// replacement keeps its own queue (#1058).
    private func replayHandshakeQueue(for generation: RealtimeConnectionGeneration) {
        while true {
            let batch: (task: URLSessionWebSocketTask, frames: [(PendingFrame, MistralStreamHealth.StallReport?)])? =
                state.withLock { s in
                guard isCurrentConnectionLocked(s.base, generation), s.base.socketState == .connected,
                      let task = s.base.webSocketTask
                else { return nil }
                let pending = s.socket?.pendingMessages ?? []
                guard !pending.isEmpty else {
                    if let handshake = s.socket?.handshake {
                        s.socket?.handshake.move(to: handshake.afterReplay, onRefused: reportUnexpectedMove)
                    }
                    return nil
                }
                s.socket?.pendingMessages.removeAll(keepingCapacity: true)
                let frames = pending.map { frame in (frame, admitLocked(&s, audio: frame.audio)) }
                s.socket?.sentAudioBytes += frames.reduce(0) { $0 + $1.0.audioBytes }
                return (task, frames)
            }
            guard let batch else { return }
            for (frame, stall) in batch.frames {
                transmit(frame.text, audioBytes: frame.audioBytes, stall: stall, on: batch.task)
            }
        }
    }

    /// Counts an audio frame handed to the socket against the server's
    /// silence. Returns a report the first time that silence passes
    /// `MistralStreamHealth.stallThreshold`.
    private func admitLocked(_ s: inout State, audio: Data?) -> MistralStreamHealth.StallReport? {
        guard let audio, !audio.isEmpty else { return nil }
        let now = clock.uptime()
        if s.socket?.health == nil { s.socket?.health = MistralStreamHealth(openedAt: now) }
        return s.socket?.health?.audioSent(
            bytes: audio.count, levelDBFS: MistralStreamHealth.rmsDBFS(pcm16: audio), at: now)
    }

    /// Any frame from the server ends its silence; one that ends a reported
    /// stall says how long it lasted.
    private func noteServerEvent(_ type: String, from generation: RealtimeConnectionGeneration) {
        let receivedAt = clock.uptime()
        let silence: TimeInterval? = state.withLock { s in
            guard isCurrentConnectionLocked(s.base, generation) else { return nil }
            return s.socket?.health?.serverEvent(at: receivedAt) ?? nil
        }
        if let silence {
            logServerSilence(
                "realtime server resumed after \(String(format: "%.1f", silence))s of silence (\(type))")
        }
    }

    private func logServerSilence(_ line: String) {
        Log.backends.notice("\(line, privacy: .public)")
        #if DEBUG
        state.withLock { $0.silenceLogForTesting.append(line) }
        #endif
    }

    private func transmit(
        _ text: String, audioBytes: Int = 0, stall: MistralStreamHealth.StallReport? = nil,
        on task: URLSessionWebSocketTask
    ) {
        if let stall { logServerSilence("realtime server silent: \(stall.logDescription)") }
        #if DEBUG
        state.withLock { $0.transmitObserverForTesting }?(task, text)
        #endif

        task.send(.string(text)) { [weak self] error in
            guard let self else { return }
            guard let error else {
                if audioBytes > 0 {
                    self.state.withLock { s in
                        guard s.base.webSocketTask === task else { return }
                        s.socket?.health?.audioSendCompleted()
                    }
                }
                return
            }
            self.handleTerminalSocketError(
                for: task,
                errorMessage: "WebSocket send failed: \(self.describeSocketError(error))"
            )
        }
    }

    // MARK: - Timers

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
        let sentAt = clock.uptime()
        let task: URLSessionWebSocketTask? = state.withLock { s in
            guard s.base.socketState == .connected else { return nil }
            s.socket?.health?.pingSent(at: sentAt)
            return s.base.webSocketTask
        }
        guard let task else { return }
        task.sendPing { [weak self] error in
            guard let self else { return }
            guard let error else {
                self.state.withLock { s in
                    guard s.base.webSocketTask === task else { return }
                    s.socket?.health?.pongReceived()
                }
                return
            }
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
            guard s.base.socketState == .connected, s.socket?.handshake == .awaitingSessionCreated
            else { return false }
            stopSessionReadyTimerLocked(&s)
            openSendGateLocked(&s, sessionCreated: false)
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
        let errorMessage = Self.terminalErrorMessage(
            errorMessage: errorMessage,
            httpStatusCode: (task.response as? HTTPURLResponse)?.statusCode
        )
        #if DEBUG
        state.withLock { $0.beforeTerminalErrorCloseForTesting }?()
        #endif

        // One critical section decides and closes: a rollover that started
        // between a separate check and the close would lose the audio it
        // carries, which the close deletes (#1724).
        enum Outcome {
            case stale
            case rollover(retiring: RealtimeConnectionGeneration)
            case closed(
                error: String?, usage: SocketUsage?, generation: RealtimeConnectionGeneration, unsentBytes: Int)
        }
        let decided: Outcome = state.withLock { s in
            guard s.base.socketState != .disconnected, s.base.webSocketTask === task else {
                return .stale
            }
            // The retiring socket died before its `done` (a 1012 from a server
            // that ran out of context, say): the session goes on to the next
            // socket with the carried audio rather than through a reconnect,
            // which would drop it.
            if let rollover = s.socket?.rollover {
                return .rollover(retiring: rollover.retiring)
            }

            let hasAnsweredFinalCommit = s.socket?.finalCommit == .answered
            if hasAnsweredFinalCommit, let errorMessage {
                Log.backends.notice(
                    "realtime server closed the socket after the final commit's answer: \(errorMessage, privacy: .public)"
                )
            }
            let generation = s.base.connectionGeneration
            let usage = takeUsageLocked(&s)
            // Taken before the close erases the queue.
            for frame in s.socket?.pendingMessages ?? [] {
                if let audio = frame.audio { s.unsentAudio.append(audio) }
            }
            let unsentBytes = s.unsentAudio.count
            closeSocketLocked(&s, cancelTask: false)
            return .closed(
                error: hasAnsweredFinalCommit ? nil : errorMessage, usage: usage, generation: generation,
                unsentBytes: unsentBytes)
        }
        guard case .closed(let error, let usage, let generation, let unsentBytes) = decided else {
            if case .rollover(let retiring) = decided {
                finishRollover(retiring: retiring, cause: errorMessage ?? Self.plainSocketCloseCause)
            }
            return
        }
        recordUsage(usage)
        if unsentBytes > 0 {
            Log.backends.notice(
                "realtime connection \(generation.description, privacy: .public) closed with \(String(format: "%.1f", Double(unsentBytes) / Double(AudioChunkBuffer.bytesPerSecond)), privacy: .public)s of audio it never sent; kept for the next socket"
            )
        }

        if let error {
            emit(.error(error), from: generation)
        }
        emit(.disconnected, from: generation)
    }

    /// The socket error text a terminal failure reports, with the HTTP
    /// status of a rejected upgrade folded in. URLSession reports a 401, 403
    /// or 429 upgrade as a bare `NSURLErrorBadServerResponse` (-1011), which
    /// the failure classifier reads as a wrong path; `task.response` still
    /// carries the status, and the classifier's `http 401`, `http 403` and
    /// `http 429` rules name the real cause. Mistral words its own
    /// (`MistralRealtimeWebSocketClient.terminalErrorMessage`).
    static func terminalErrorMessage(errorMessage: String?, httpStatusCode: Int?) -> String? {
        guard let errorMessage else { return nil }
        guard let httpStatusCode, httpStatusCode >= 400 else { return errorMessage }
        return "The server refused the connection (HTTP \(httpStatusCode)): \(errorMessage)"
    }

    package func takeUnsentAudio() -> Data {
        state.withLock { s in
            defer { s.unsentAudio = Data() }
            return s.unsentAudio
        }
    }

    // MARK: - Usage

    private struct SocketUsage {
        let backend: UsageEntry.Backend
        let model: String
        let audioSeconds: Double
    }

    /// The closing socket's entry, nil when it has no backend or sent no
    /// audio. Resets the count, so each socket is recorded exactly once
    /// whichever path closes it.
    private func takeUsageLocked(_ s: inout State) -> SocketUsage? {
        guard let socket = s.socket else { return nil }
        s.socket?.sentAudioBytes = 0
        guard let backend = socket.usageBackend, socket.sentAudioBytes > 0 else { return nil }
        return SocketUsage(
            backend: backend,
            // A user server may take no model name; the ledger needs one.
            model: socket.usageModel.isEmpty ? "default" : socket.usageModel,
            // 16 kHz mono S16, what the capture pipeline sends both clients.
            audioSeconds: Double(socket.sentAudioBytes) / Double(MistralRealtimeWebSocketClient.audioSampleRate * 2)
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
        s.socket?.rollover?.watchdog?.cancel()
        s.socket = nil
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

    /// Runs as a terminal socket error is handled, before the client decides
    /// between a rollover and a disconnect, so a test can start a rollover
    /// there (#1724).
    package func debugSetBeforeTerminalErrorClose(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.beforeTerminalErrorCloseForTesting = hook }
    }

    /// Hears every frame as it is handed to a socket, in order.
    package func debugObserveTransmits(_ observer: (@Sendable (URLSessionWebSocketTask, String) -> Void)?) {
        state.withLock { $0.transmitObserverForTesting = observer }
    }

    package func debugPrimeConnectedStateForTesting(
        task: URLSessionWebSocketTask,
        hasReceivedSessionCreated: Bool = false,
        usageBackend: UsageEntry.Backend? = nil,
        usageModel: String = "",
        modelName: String = "",
        contextBias: [String] = [],
        language: String? = nil
    ) {
        state.withLock { s in
            closeSocketLocked(&s, cancelTask: false)
            s.configuration = RealtimeSessionConfiguration(
                endpoint: task.originalRequest?.url ?? URL(string: "ws://127.0.0.1/v1/realtime")!,
                apiKey: "",
                model: modelName,
                usageBackend: usageBackend,
                contextBias: contextBias,
                language: language
            )
            s.base.connectionGeneration = .next()
            s.base.webSocketTask = task
            s.base.socketState = .connected
            s.socket = OpenSocket(
                modelName: modelName,
                contextBias: contextBias,
                language: language,
                usageBackend: usageBackend,
                usageModel: usageModel,
                origin: .connect,
                handshake: hasReceivedSessionCreated
                    ? .gateOpen(replaying: false, sessionCreated: true) : .awaitingSessionCreated,
                hasUncommittedAudio: true,
                isGenerationInProgress: true,
                pendingMessages: [PendingFrame(text: "pending-message")])
            startPingTimerLocked(&s)
            startSessionReadyTimerLocked(&s)
        }
    }

    /// A client whose socket opened without latching a configuration.
    package func debugClearConfigurationForTesting() {
        state.withLock { $0.configuration = nil }
    }

    package func debugHandleTerminalSocketErrorForTesting(
        task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        handleTerminalSocketError(for: task, errorMessage: errorMessage)
    }

    /// Put the client where a stop-finalization leaves it: the final commit is
    /// out and the socket owes a `transcription.done` for it.
    package func debugPrimeFinalCommitGateForTesting() {
        state.withLock { $0.socket?.finalCommit = .awaitingDone }
    }

    package func debugSetGenerationTrackingState(
        hasUncommittedAudio: Bool,
        isGenerationInProgress: Bool
    ) {
        state.withLock { s in
            s.socket?.hasUncommittedAudio = hasUncommittedAudio
            s.socket?.isGenerationInProgress = isGenerationInProgress
            // No final commit in flight; an answered one stays answered.
            if s.socket?.finalCommit == .awaitingDone { s.socket?.finalCommit = .notSent }
        }
    }

    /// The silence and resume lines logged, in order.
    package func debugServerSilenceLogForTesting() -> [String] {
        state.withLock { $0.silenceLogForTesting }
    }

    package func debugStateSnapshot() -> DebugStateSnapshot {
        state.withLock { s in
            DebugStateSnapshot(
                isConnected: s.base.socketState == .connected,
                hasPingTimer: s.pingTimer != nil,
                hasSessionReadyTimer: s.sessionReadyTimer != nil,
                pendingMessageCount: s.socket?.pendingMessages.count ?? 0,
                hasUncommittedAudio: s.socket?.hasUncommittedAudio ?? false,
                isGenerationInProgress: s.socket?.isGenerationInProgress ?? false,
                hasReceivedSessionCreated: s.socket?.handshake.hasReceivedSessionCreated ?? false,
                isAwaitingFinalCommitDone: s.socket?.finalCommit == .awaitingDone,
                contextBudget: s.contextBudget
            )
        }
    }
}
#endif
