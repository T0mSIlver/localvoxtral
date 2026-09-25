import Foundation
import Network
import Synchronization
import XCTest

/// An OpenAI Realtime-compatible server on a loopback port, for tests that
/// put the real `RealtimeAPIWebSocketClient` and its socket on the session
/// path. It answers each connection with `session.created` and records every
/// frame the client sends; what it transcribes, and when, is the test's to
/// say with `send`.
///
/// The OS picks the port (#442: test classes run in several processes at
/// once). One client at a time: a new connection replaces the previous one.
final class FakeRealtimeServer: @unchecked Sendable {
    /// One JSON frame the client sent, in arrival order.
    struct Frame: @unchecked Sendable {
        let json: [String: Any]
        var type: String { json["type"] as? String ?? "" }

        /// The PCM an `input_audio_buffer.append` carried.
        var audio: Data? {
            (json["audio"] as? String).flatMap { Data(base64Encoded: $0) }
        }

        var isFinalCommit: Bool {
            type == "input_audio_buffer.commit" && json["final"] as? Bool == true
        }
    }

    private struct FrameWaiter {
        let matches: @Sendable (Frame) -> Bool
        let wait: BoundedWait
    }

    private struct State {
        var connection: NWConnection?
        var frames: [Frame] = []
        var frameWaiters: [FrameWaiter] = []
        var isClosed = false
        var closeWaiters: [BoundedWait] = []
        var listenerError: NWError?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeRealtimeServer")
    private let state = Mutex(State())

    init() throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    deinit {
        stop()
    }

    /// Starts listening and returns the endpoint to put in Settings.
    func start(failAfter: TimeInterval = 10) async throws -> URL {
        let ready = BoundedWait()
        listener.stateUpdateHandler = { [weak self] listenerState in
            switch listenerState {
            case .ready:
                ready.resolve()
            case .failed(let error):
                self?.state.withLock { $0.listenerError = error }
                ready.resolve()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard await ready.value(failAfter: failAfter) else {
            throw FakeRealtimeServerError.notListening("never became ready")
        }
        if let error = state.withLock({ $0.listenerError }) {
            throw FakeRealtimeServerError.notListening("\(error)")
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            throw FakeRealtimeServerError.notListening("no port")
        }
        return URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
    }

    func stop() {
        listener.cancel()
        state.withLock { $0.connection }?.cancel()
    }

    /// Sends one JSON frame to the connected client.
    func send(_ json: [String: Any]) {
        guard let connection = state.withLock({ $0.connection }) else {
            XCTFail("no client is connected to send \(json["type"] ?? "a frame") to")
            return
        }
        send(json, on: connection)
    }

    /// Every frame received so far.
    var frames: [Frame] { state.withLock { $0.frames } }

    /// Returns the first frame, received already or later, that `matches`.
    /// Nil, and a test failure, if none arrives within `failAfter` seconds of
    /// wall time; a passing test never waits that long.
    @discardableResult
    func awaitFrame(
        _ description: String,
        failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath,
        line: UInt = #line,
        where matches: @escaping @Sendable (Frame) -> Bool
    ) async -> Frame? {
        let arrived = BoundedWait()
        let found = state.withLock { state -> Frame? in
            if let frame = state.frames.first(where: matches) { return frame }
            state.frameWaiters.append(FrameWaiter(matches: matches, wait: arrived))
            return nil
        }
        if let found { return found }
        guard await arrived.value(failAfter: failAfter) else {
            state.withLock { $0.frameWaiters.removeAll { $0.wait === arrived } }
            XCTFail("the client never sent \(description)", file: file, line: line)
            return nil
        }
        return state.withLock { $0.frames.first(where: matches) }
    }

    /// Returns once the client has closed its socket.
    func awaitClose(
        failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let closed = BoundedWait()
        let isClosed = state.withLock { state -> Bool in
            if state.isClosed { return true }
            state.closeWaiters.append(closed)
            return false
        }
        if isClosed { return }
        if await closed.value(failAfter: failAfter) { return }
        XCTFail("the client never closed its socket", file: file, line: line)
    }

    // MARK: - Connection

    private func accept(_ connection: NWConnection) {
        let previous = state.withLock { state -> NWConnection? in
            let previous = state.connection
            state.connection = connection
            state.isClosed = false
            return previous
        }
        previous?.cancel()
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let self, let connection else { return }
            switch connectionState {
            case .ready:
                self.send(["type": "session.created"], on: connection)
            case .failed, .cancelled:
                self.markClosed(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let content, metadata?.opcode != .close else {
                self.markClosed(connection)
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any] {
                self.record(Frame(json: json))
            }
            self.receive(on: connection)
        }
    }

    private func record(_ frame: Frame) {
        let satisfied = state.withLock { state -> [BoundedWait] in
            state.frames.append(frame)
            let satisfied = state.frameWaiters.filter { $0.matches(frame) }
            state.frameWaiters.removeAll { $0.matches(frame) }
            return satisfied.map(\.wait)
        }
        satisfied.forEach { $0.resolve() }
    }

    private func markClosed(_ connection: NWConnection) {
        let waiters = state.withLock { state -> [BoundedWait] in
            guard state.connection === connection, !state.isClosed else { return [] }
            state.isClosed = true
            let waiters = state.closeWaiters
            state.closeWaiters = []
            return waiters
        }
        waiters.forEach { $0.resolve() }
    }

    private func send(_ json: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            XCTFail("unencodable frame \(json)")
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true, completion: .idempotent
        )
    }
}

enum FakeRealtimeServerError: Error {
    case notListening(String)
}
