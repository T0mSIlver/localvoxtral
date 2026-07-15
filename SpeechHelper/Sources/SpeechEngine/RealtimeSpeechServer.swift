import Foundation
import MLX
import MLXAudioSTT
import Network
import SpeechEngineText
import Synchronization

/// Loopback OpenAI-Realtime-compatible ASR server: a drop-in for the Python `voxmlx`
/// process. Serves `GET /health` (the supervisor's readiness probe) and a WebSocket
/// `/v1/realtime` on the same port, driving a `VoxtralRealtimeStreamSession` per connection.
///
/// All model/session access is confined to one serial queue — MLX inference is not
/// concurrency-safe, and dictation uses one connection at a time anyway. The Network
/// callbacks (also serialized per connection) only parse bytes and hand decoded messages to
/// that queue in order.
public final class RealtimeSpeechServer: @unchecked Sendable {
    private let model: VoxtralRealtimeModel
    private let transcriptionDelayMs: Int?
    private let listener: NWListener
    private let netQueue = DispatchQueue(label: "localvoxtral.speechd.net")
    private let inferenceQueue = DispatchQueue(label: "localvoxtral.speechd.inference")

    /// Called when the listener dies after serving began; the supervised helper passes
    /// `{ exit(1) }` so a dead port gets the process restarted (mirrors PolishHelper).
    public var onListenerFailure: (@Sendable (Error) -> Void)?

    /// Load the Voxtral model and build a server ready to `start()`. Public entry point for the
    /// executable target, which cannot see the (module-internal) model type. Sets the MLX GPU
    /// cache limit and loads from an HF id or a local directory.
    public static func load(
        modelID: String?,
        modelDirectory: String?,
        port: UInt16,
        transcriptionDelayMs: Int?,
        cacheLimitMB: Int
    ) async throws -> RealtimeSpeechServer {
        MLX.GPU.set(cacheLimit: cacheLimitMB * 1024 * 1024)
        let model: VoxtralRealtimeModel
        if let dir = modelDirectory {
            model = try VoxtralRealtimeModel.fromDirectory(URL(fileURLWithPath: dir))
        } else if let id = modelID {
            model = try await VoxtralRealtimeModel.fromPretrained(id)
        } else {
            throw ServerError.noModelSpecified
        }
        return try RealtimeSpeechServer(
            model: model, port: port, transcriptionDelayMs: transcriptionDelayMs)
    }

    public enum ServerError: Error { case noModelSpecified }

    init(model: VoxtralRealtimeModel, port: UInt16, transcriptionDelayMs: Int?) throws {
        self.model = model
        self.transcriptionDelayMs = transcriptionDelayMs
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
        var session: VoxtralRealtimeStreamSession?
        // Append-only delta contract lives in OUR layer now (the engine is an upstream
        // dependency whose raw `Delta` re-emits the whole transcript on a non-prefix step).
        // Feed it the session's full-transcript snapshot after each step/finish; emit only
        // its append-only delta. Touched only on the inference queue, like `session`.
        var deltas = TranscriptDeltaEmitter()
        enum Phase { case http, webSocket }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: netQueue)
        receive(connection, Connection())
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
                let session = self.ensureSession(ctx)
                session.step(samples)
                // Emit the append-only delta from the full transcript snapshot, NOT the
                // engine's raw `Delta` (which re-emits the whole transcript on a non-prefix
                // step — our no-backspace insertion path would duplicate it).
                let delta = ctx.deltas.emit(fullText: session.text)
                if !delta.isEmpty { self.sendServer(connection, .transcriptDelta(delta)) }
            case .commit(let final):
                guard final else { return }  // non-final commit is a no-op, matching voxmlx
                let session = self.ensureSession(ctx)
                session.finish()
                let tail = ctx.deltas.emit(fullText: session.text)
                if !tail.isEmpty { self.sendServer(connection, .transcriptDelta(tail)) }
                // Use the append-only emitted text (== sum of every delta), so the final
                // payload can never contradict what was streamed on the wire.
                self.sendServer(connection, .transcriptDone(text: ctx.deltas.emittedText))
                ctx.session = nil  // ready for the next utterance
                ctx.deltas = TranscriptDeltaEmitter()
            case .clear:
                ctx.session = nil
                ctx.deltas = TranscriptDeltaEmitter()
            case .ignored:
                break
            }
        }
    }

    /// Must be called on `inferenceQueue`.
    private func ensureSession(_ ctx: Connection) -> VoxtralRealtimeStreamSession {
        if let s = ctx.session { return s }
        let s = model.makeStreamSession(temperature: 0.0, transcriptionDelayMs: transcriptionDelayMs)
        ctx.session = s
        return s
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
