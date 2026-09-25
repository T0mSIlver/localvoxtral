import Foundation
import MLX
import MLXAudioSTT
import Network
import SpeechEngineText
import Synchronization

/// Loopback OpenAI-Realtime-compatible ASR server: a drop-in for the Python `voxmlx`
/// process. Serves `GET /health` (the supervisor's readiness probe) and a WebSocket
/// `/v1/realtime` on the same port, driving one `SpeechASRStreamingSession` per connection.
/// Which engine backs that session (Voxtral, Nemotron) is `SpeechModelLoader`'s decision.
///
/// All model/session access is confined to one serial queue — MLX inference is not
/// concurrency-safe, and dictation uses one connection at a time anyway. The Network
/// callbacks (also serialized per connection) only parse bytes and hand decoded messages to
/// that queue in order.
public final class RealtimeSpeechServer: @unchecked Sendable {
    private let engine: SpeechASREngine
    private let transcriptionDelayMs: Int?
    private let stepMilliseconds: Int
    private let utteranceLimit: UtteranceLimit
    private let listener: NWListener
    private let netQueue = DispatchQueue(label: "localvoxtral.speechd.net")
    private let inferenceQueue = DispatchQueue(label: "localvoxtral.speechd.inference")

    /// Called when the listener dies after serving began; the supervised helper passes
    /// `{ exit(1) }` so a dead port gets the process restarted (mirrors PolishHelper).
    public var onListenerFailure: (@Sendable (Error) -> Void)?

    /// Load the model and build a server ready to `start()`. Public entry point for the
    /// executable target, which cannot see the (module-internal) model types. Sets the MLX GPU
    /// cache limit and loads from an HF id or a local directory.
    public static func load(
        modelID: String?,
        modelRevision: String?,
        modelDirectory: String?,
        port: UInt16,
        transcriptionDelayMs: Int?,
        cacheLimitMB: Int,
        stepMilliseconds: Int = 100,
        utteranceLimit: UtteranceLimit = UtteranceLimit()
    ) async throws -> RealtimeSpeechServer {
        Memory.cacheLimit = cacheLimitMB * 1024 * 1024
        let engine = try await SpeechModelLoader.load(
            modelID: modelID,
            modelRevision: modelRevision,
            modelDirectory: modelDirectory
        )
        return try RealtimeSpeechServer(
            engine: engine,
            port: port,
            transcriptionDelayMs: transcriptionDelayMs,
            stepMilliseconds: stepMilliseconds,
            utteranceLimit: utteranceLimit
        )
    }

    public enum ServerError: Error { case noModelSpecified }

    init(
        engine: SpeechASREngine,
        port: UInt16,
        transcriptionDelayMs: Int?,
        stepMilliseconds: Int,
        utteranceLimit: UtteranceLimit
    ) throws {
        self.engine = engine
        self.transcriptionDelayMs = transcriptionDelayMs
        self.stepMilliseconds = stepMilliseconds
        self.utteranceLimit = utteranceLimit
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        self.listener = try NWListener(using: parameters)
    }

    public var boundPort: UInt16 { listener.port?.rawValue ?? 0 }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let resumeOnce = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    resumeOnce.run { cont.resume() }
                case .failed(let error), .waiting(let error):
                    // Pre-ready fails start(); post-ready means the listener died under us —
                    // cancel and escalate so the supervised helper exits and is restarted.
                    let wasPreReady = resumeOnce.run { cont.resume(throwing: error) }
                    self?.listener.cancel()
                    if !wasPreReady { self?.onListenerFailure?(error) }
                case .cancelled:
                    resumeOnce.run { cont.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: netQueue)
        }
    }

    /// A continuation resumes once, but the listener can emit several terminal transitions —
    /// collapse them to the first. `run` returns whether THIS call was first (the body ran).
    private final class ResumeOnce: Sendable {
        private let resumed = Mutex(false)
        @discardableResult
        func run(_ body: () -> Void) -> Bool {
            let first = resumed.withLock { v in let p = v; v = true; return !p }
            if first { body() }
            return first
        }
    }

    public func stop() { listener.cancel() }

    // MARK: - Per-connection state

    /// Mutable state for one connection, touched only on the network queue (buffer/phase) and
    /// the inference queue (session). @unchecked because it crosses those queue boundaries;
    /// the two never touch the same field concurrently.
    private final class Connection: @unchecked Sendable {
        var phase: Phase = .http
        var buffer = Data()
        var session: SpeechASRStreamingSession?
        var stepBatcher: StepBatcher
        // Append-only delta contract lives in OUR layer now (the engine is an upstream
        // dependency whose raw `Delta` re-emits the whole transcript on a non-prefix step).
        // Feed it the session's full-transcript snapshot after each step/finish; emit only
        // its append-only delta. Touched only on the inference queue, like `session`.
        var deltas = TranscriptDeltaEmitter()
        // Latches an early engine stop (length cap or end-of-stream) so it is reported once
        // per engine session. Inference queue only, like `session`.
        var stopReporter = UtteranceStopReporter()
        enum Phase { case http, webSocket }

        init(stepMilliseconds: Int) {
            self.stepBatcher = StepBatcher(cadenceMilliseconds: stepMilliseconds)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: netQueue)
        receive(connection, Connection(stepMilliseconds: stepMilliseconds))
    }

    private func receive(_ connection: NWConnection, _ ctx: Connection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                ctx.buffer.append(data)
                do {
                    try self.drain(connection, ctx)
                } catch {
                    connection.cancel()
                    return
                }
            }
            if error != nil || isComplete { connection.cancel(); return }
            self.receive(connection, ctx)
        }
    }

    /// Consume as much of `ctx.buffer` as forms complete units (the HTTP head, then whole WS
    /// frames).
    private func drain(_ connection: NWConnection, _ ctx: Connection) throws {
        if ctx.phase == .http {
            guard let (head, headerBytes) = WebSocketHandshake.parseRequestHead(ctx.buffer) else {
                return  // need more bytes
            }
            ctx.buffer.removeFirst(headerBytes)

            guard head.isWebSocketUpgrade, let key = head.header("sec-websocket-key") else {
                // Plain HTTP: the readiness probe. Anything else also gets a simple 200 so a
                // stray GET can't wedge the supervisor.
                let json = head.path == "/health" ? #"{"status":"ok"}"# : #"{"status":"ok"}"#
                self.rawSend(connection, WebSocketHandshake.httpResponse(status: "200 OK", json: json),
                             thenClose: true)
                return
            }

            self.rawSend(connection, WebSocketHandshake.upgradeResponse(secWebSocketKey: key))
            ctx.phase = .webSocket
            // The client gates flushing its queued messages on session.created (with a 3s
            // fallback), so send it as soon as the socket is up.
            self.sendServer(connection, .sessionCreated)
        }

        // WebSocket phase: decode every complete frame currently buffered.
        while ctx.phase == .webSocket {
            let result = try WebSocketFrameCodec.decode(ctx.buffer)
            guard case .frame(let frame, let consumed) = result else { break }
            ctx.buffer.removeFirst(consumed)
            try self.handle(frame, connection, ctx)
        }
    }

    private func handle(_ frame: WebSocketFrame, _ connection: NWConnection, _ ctx: Connection) throws {
        switch frame.opcode {
        case .ping:
            rawSend(connection, WebSocketFrameCodec.pong(frame.payload))
        case .close:
            rawSend(connection, WebSocketFrameCodec.close(), thenClose: true)
            // A client that disconnects without a final commit (mid-utterance
            // cancel) would otherwise release its session's buffers into the
            // pool with no clear behind them. Serial queue: this lands after
            // any already-queued steps for this connection.
            inferenceQueue.async {
                ctx.session = nil
                ctx.stopReporter.reset()
                Memory.clearCache()
            }
        case .pong, .continuation:
            break
        case .text, .binary:
            let message: RealtimeClientMessage
            do {
                message = try RealtimeClientMessage.parse(frame.payload)
            } catch {
                sendServer(connection, .error(message: "malformed message: \(error)"))
                return
            }
            dispatch(message, connection, ctx)
        }
    }

    // MARK: - Inference (serial queue)

    private func dispatch(_ message: RealtimeClientMessage, _ connection: NWConnection, _ ctx: Connection) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            switch message {
            case .sessionUpdate:
                self.sendServer(connection, .sessionUpdated)
            case .audioAppend(let base64):
                guard let samples = PCM16.decode(base64: base64) else {
                    self.sendServer(connection, .error(message: "Invalid PCM16 payload"))
                    return
                }
                for batch in ctx.stepBatcher.append(samples) {
                    let session = self.ensureSession(ctx)
                    session.step(batch)
                    // Emit the append-only delta from the full transcript snapshot, NOT the
                    // engine's raw `Delta` (which re-emits the whole transcript on a non-prefix
                    // step — our no-backspace insertion path would duplicate it).
                    let delta = ctx.deltas.emit(fullText: session.text)
                    if !delta.isEmpty { self.sendServer(connection, .transcriptDelta(delta)) }
                    self.reportEarlyStopIfNeeded(session, connection, ctx)
                }
            case .commit(let final):
                guard final else { return }  // non-final commit is a no-op, matching voxmlx
                let session = self.ensureSession(ctx)
                let remainder = ctx.stepBatcher.flushRemainder()
                if !remainder.isEmpty { session.step(remainder) }
                // The remainder can be what crosses the limit (Nemotron then drops it).
                // Check before finish(), which ends every Voxtral stream and would
                // read as the model stopping early.
                self.reportEarlyStopIfNeeded(session, connection, ctx)
                session.finish()
                let tail = ctx.deltas.emit(fullText: session.text)
                if !tail.isEmpty { self.sendServer(connection, .transcriptDelta(tail)) }
                // Use the append-only emitted text (== sum of every delta), so the final
                // payload can never contradict what was streamed on the wire.
                self.sendServer(connection, .transcriptDone(text: ctx.deltas.emittedText))
                ctx.session = nil  // ready for the next utterance
                ctx.deltas = TranscriptDeltaEmitter()
                ctx.stopReporter.reset()
                ctx.stepBatcher.clear()
                // The engine's finish() clears the buffer pool, but at that point the
                // session's KV caches and encoder state are still live — dropping the
                // session afterwards releases them INTO the pool, which then sits at
                // `Memory.cacheLimit` for as long as the helper idles (field-hit
                // 2026-07-17: ~5 GB resident between dictations at a 2 GB cap). Clear
                // AFTER the drop so idle footprint returns to the weight floor; the
                // next utterance re-warms the pool while it streams.
                Memory.clearCache()
            case .clear:
                ctx.session = nil
                ctx.deltas = TranscriptDeltaEmitter()
                ctx.stopReporter.reset()
                ctx.stepBatcher.clear()
                // Same idle-footprint contract as the commit path above.
                Memory.clearCache()
            case .ignored:
                break
            }
        }
    }

    /// Must be called on `inferenceQueue`.
    private func ensureSession(_ ctx: Connection) -> SpeechASRStreamingSession {
        if let s = ctx.session { return s }
        let s = engine.makeSession(
            transcriptionDelayMs: transcriptionDelayMs,
            utteranceLimit: utteranceLimit
        )
        ctx.session = s
        return s
    }

    /// An engine session that stops before the client's final commit returns nothing from
    /// every later step, so the app would see deltas simply stop (#314). Say so once: an
    /// `error` event the app shows on its status line, and a stderr line for the helper log.
    /// Must be called on `inferenceQueue`.
    private func reportEarlyStopIfNeeded(
        _ session: SpeechASRStreamingSession,
        _ connection: NWConnection,
        _ ctx: Connection
    ) {
        guard let stop = ctx.stopReporter.report(session.utteranceStop) else { return }
        switch stop {
        case .lengthLimit:
            FileHandle.standardError.write(Data(
                "speechd: utterance reached the \(utteranceLimit.seconds)s limit; later audio is not transcribed\n".utf8))
            sendServer(connection, .transcriptionStopped(message: utteranceLimit.reachedMessage))
        case .endOfStream:
            FileHandle.standardError.write(Data(
                "speechd: model ended the stream after \(session.decodedTokenCount) tokens; later audio is not transcribed\n".utf8))
            sendServer(
                connection,
                .transcriptionStopped(message: UtteranceLimit.endOfStreamMessage)
            )
        }
    }

    // MARK: - Send helpers

    private func sendServer(_ connection: NWConnection, _ message: RealtimeServerMessage) {
        rawSend(connection, WebSocketFrameCodec.text(message.json()))
    }

    private func rawSend(_ connection: NWConnection, _ data: Data, thenClose: Bool = false) {
        connection.send(
            content: data,
            completion: .contentProcessed { _ in if thenClose { connection.cancel() } }
        )
    }
}

/// Resolves the checkpoint the app pinned into a loaded engine. The engine kind comes
/// from the repo id, or from a `--model-dir` checkpoint's own `config.json`
/// (`SpeechASREngineKind.infer`), so adding a model to the app's catalog never needs a
/// new helper flag.
enum SpeechModelLoader {
    static func load(
        modelID: String?,
        modelRevision: String?,
        modelDirectory: String?
    ) async throws -> SpeechASREngine {
        switch engineKind(modelID: modelID, modelDirectory: modelDirectory) {
        case .voxtral:
            return VoxtralASREngine(model: try await loadModel(
                modelID: modelID,
                modelRevision: modelRevision,
                modelDirectory: modelDirectory,
                fromDirectory: { try VoxtralRealtimeModel.fromDirectory($0) },
                fromPretrained: { try await VoxtralRealtimeModel.fromPretrained($0) }
            ))
        case .nemotron:
            return NemotronASREngine(model: try await loadModel(
                modelID: modelID,
                modelRevision: modelRevision,
                modelDirectory: modelDirectory,
                fromDirectory: { try NemotronASRModel.fromDirectory($0) },
                fromPretrained: { try await NemotronASRModel.fromPretrained($0) }
            ))
        }
    }

    private static func engineKind(
        modelID: String?,
        modelDirectory: String?
    ) -> SpeechASREngineKind {
        if let modelID { return .infer(fromModelID: modelID) }
        if let modelDirectory {
            return .infer(fromModelDirectory: URL(fileURLWithPath: modelDirectory))
        }
        return .voxtral
    }

    /// The same three-way resolution for every engine: an explicit directory, the
    /// app-pinned revision already in the shared Hugging Face cache, or — development
    /// only — whatever the repo's `main` resolves to.
    private static func loadModel<Model>(
        modelID: String?,
        modelRevision: String?,
        modelDirectory: String?,
        fromDirectory: (URL) throws -> Model,
        fromPretrained: (String) async throws -> Model
    ) async throws -> Model {
        if let dir = modelDirectory {
            return try fromDirectory(URL(fileURLWithPath: dir))
        }
        if let id = modelID, let revision = modelRevision {
            return try fromDirectory(try SpeechHFCacheModelLocator.locate(
                repoID: id,
                revision: revision,
                cacheRoot: SpeechHFCacheModelLocator.defaultCacheRoot()
            ))
        }
        if let id = modelID {
            return try await fromPretrained(id)
        }
        throw RealtimeSpeechServer.ServerError.noModelSpecified
    }
}
