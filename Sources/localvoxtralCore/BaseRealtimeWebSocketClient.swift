import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// Shared base for WebSocket-based realtime clients.
///
/// This class is abstract — do not instantiate directly. Subclasses must override:
///  - `withBaseState(_:)` — provide locked access to the embedded `BaseState`
///  - `handle(json:from:)` — protocol-specific event dispatch
///  - `didOpenConnection(on:)` — post-connect setup (timers, config flush)
///  - `handleTerminalSocketError(for:errorMessage:)` — full state cleanup on socket failure
package class BaseRealtimeWebSocketClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    // MARK: - Shared base state

    enum SocketState {
        case disconnected
        case connecting
        case connected
    }

    /// Minimum shared fields every WebSocket client needs.
    /// Subclasses embed this inside their own `State` struct.
    struct BaseState {
        var urlSession: URLSession?
        var webSocketTask: URLSessionWebSocketTask?
        var socketState: SocketState = .disconnected
        var onEvent: (@Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void)?
        var isUserInitiatedDisconnect = false
        /// Stamped by `connect()` inside the same locked block that installs the
        /// new socket, so no reader can see the new name beside the old socket.
        /// Deliberately NOT reset by a close: a socket that dies still names
        /// itself correctly on the way out.
        var connectionGeneration: RealtimeConnectionGeneration = .none
    }

    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    // MARK: - Abstract interface (override in subclasses)

    /// Protocol-specific JSON event handling. `generation` is the socket the
    /// frame was read from, captured before the frame was parsed — every event
    /// raised out of this frame must be emitted `from:` it, never from whatever
    /// socket the client holds by the time the emit runs.
    func handle(json: [String: Any], from generation: RealtimeConnectionGeneration) {
        fatalError("Subclasses must override handle(json:from:)")
    }

    /// Called when the WebSocket connection opens. Subclasses use this for
    /// post-connect setup (ping timers, initial config flush, etc.).
    func didOpenConnection(on task: URLSessionWebSocketTask) {
        fatalError("Subclasses must override didOpenConnection(on:)")
    }

    // MARK: - Must be provided by subclass for state access

    /// Subclasses must return their current base state under their lock.
    func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        fatalError("Subclasses must override withBaseState(_:)")
    }

    // MARK: - Shared helpers

    /// Raise `event` on behalf of `generation`'s socket.
    ///
    /// The generation is always passed in, never re-read here: the whole point
    /// of the stamp is that a frame handler's socket can be retired between the
    /// receive guard that admitted the frame and this call, and re-reading would
    /// hand the dead socket's transcript the live socket's name.
    func emit(_ event: RealtimeEvent, from generation: RealtimeConnectionGeneration) {
        let handler: (@Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void)? =
            withBaseState { $0.onEvent }
        guard let handler else { return }
        handler(event, generation)
    }

    /// The generation of the socket the client holds right now. Only for call
    /// sites that ARE that socket by construction — a send the session just
    /// asked for, a serialization failure on the way to it.
    var currentConnectionGeneration: RealtimeConnectionGeneration {
        withBaseState { $0.connectionGeneration }
    }

    /// Whether `generation` is still the socket this client holds.
    ///
    /// Call it INSIDE the lock that is about to mutate state on a frame's
    /// behalf. Stamping the events is only half the job: `emit(_:from:)` keeps
    /// a retired socket's events off the session, but a frame handler also
    /// mutates handshake and finalization state, and the lock it does that
    /// under is a different acquisition from the one that admitted the frame.
    /// Applied to the socket that REPLACED it, a stale `session.created` drains
    /// the new socket's pending queue onto the wire ahead of its own
    /// `session.update`, and a stale `transcription.done` clears a commit gate
    /// the new socket is still waiting on. Neither shows up as a wrong event.
    func isCurrentConnectionLocked(
        _ s: BaseState, _ generation: RealtimeConnectionGeneration
    ) -> Bool {
        s.connectionGeneration == generation
    }

    func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.realtime.debug("\(message)")
    }

    func describeSocketError(_ error: Error) -> String {
        let nsError = error as NSError
        var components = [error.localizedDescription, "[\(nsError.domain):\(nsError.code)]"]

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            components.append("url=\(failingURL.absoluteString)")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey]
            as? String
        {
            components.append("url=\(failingURLString)")
        }

        return components.joined(separator: " ")
    }

    /// Handles a terminal socket error by cleaning up state and emitting events.
    ///
    /// Subclasses **must** override this to clean up their own state (timers,
    /// queued messages, etc.) in addition to base state. The default implementation
    /// only cleans `BaseState` which is insufficient for subclasses with extra fields.
    func handleTerminalSocketError(
        for task: URLSessionWebSocketTask, errorMessage: String?
    ) {
        let outcome:
            (error: String?, disconnected: Bool, generation: RealtimeConnectionGeneration) =
            withBaseState { s in
                guard s.socketState != .disconnected, s.webSocketTask === task else {
                    return (nil, false, .none)
                }
                let shouldEmitError = !s.isUserInitiatedDisconnect
                let generation = s.connectionGeneration
                self.closeBaseStateLocked(&s, cancelTask: false)
                return (shouldEmitError ? errorMessage : nil, true, generation)
            }

        if let error = outcome.error {
            emit(.error(error), from: outcome.generation)
        }
        if outcome.disconnected {
            emit(.disconnected, from: outcome.generation)
        }
    }

    /// Tears down the base socket fields. Subclasses call this from their own
    /// `closeSocketLocked` after cleaning up subclass-specific state.
    func closeBaseStateLocked(_ s: inout BaseState, cancelTask: Bool) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation cancels synchronously on the task's work
        // queue, which is where `listenForMessages` callbacks run, and they
        // wait for the lock this is called under: a deadlock. So cancel after
        // the lock is released. Stale callbacks from the cancelled task are
        // refused like any other retired socket's.
        let task = cancelTask ? s.webSocketTask : nil
        let session = s.urlSession
        s.webSocketTask = nil
        s.urlSession = nil
        s.socketState = .disconnected
        s.isUserInitiatedDisconnect = false
        DispatchQueue.global().async {
            task?.cancel(with: .normalClosure, reason: nil)
            session?.invalidateAndCancel()
        }
        #else
        if cancelTask {
            s.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }
        s.webSocketTask = nil
        s.urlSession?.invalidateAndCancel()
        s.urlSession = nil
        s.socketState = .disconnected
        s.isUserInitiatedDisconnect = false
        #endif
    }

    func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            // The generation is captured HERE, under the same lock as the
            // admission check, and carried down to every emit the frame
            // produces. `task` can be closed and replaced by another callback
            // while the frame is being parsed; what it may not do is let the
            // frame come out wearing the new socket's name.
            let generation: RealtimeConnectionGeneration? = self.withBaseState { s in
                guard s.socketState == .connected, s.webSocketTask === task else { return nil }
                return s.connectionGeneration
            }
            guard let generation else { return }

            switch result {
            case .success(let message):
                self.handle(message: message, from: generation)
                self.listenForMessages(on: task)
            case .failure(let error):
                self.handleTerminalSocketError(
                    for: task,
                    errorMessage: "WebSocket receive failed: \(self.describeSocketError(error))"
                )
            }
        }
    }

    func handle(
        message: URLSessionWebSocketTask.Message, from generation: RealtimeConnectionGeneration
    ) {
        switch message {
        case .string(let text):
            handle(text: text, from: generation)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                emit(.status("Received binary frame of \(data.count) bytes."), from: generation)
                return
            }
            handle(text: text, from: generation)
        @unknown default:
            emit(.status("Received an unknown WebSocket frame."), from: generation)
        }
    }

    func handle(text: String, from generation: RealtimeConnectionGeneration) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("received non-dictionary JSON frame")
                emit(.status("Received non-JSON frame."), from: generation)
                return
            }
            handle(json: json, from: generation)
        } catch {
            debugLog("JSON parse error: \(error.localizedDescription)")
            emit(.status("Received non-JSON frame."), from: generation)
        }
    }

    #if DEBUG
    /// Drive one parsed frame as if it had just been read off the socket the
    /// client currently holds. Production never reaches `handle(json:from:)`
    /// this way: `listenForMessages` stamps the socket the frame was actually
    /// read from, which is the whole point of the stamp.
    package func debugHandleFrameForTesting(json: [String: Any]) {
        handle(json: json, from: currentConnectionGeneration)
    }

    /// Drive one parsed frame as if a socket that is no longer current had been
    /// read for it — the delayed-handler case a live swap cannot be made to
    /// reproduce on demand.
    package func debugHandleFrameForTesting(
        json: [String: Any], from generation: RealtimeConnectionGeneration
    ) {
        handle(json: json, from: generation)
    }
    #endif

    /// Validates a WebSocket endpoint URL scheme.
    func validateWebSocketScheme(_ endpoint: URL, errorDomain: String) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Realtime endpoint must use ws:// or wss://."
                ]
            )
        }
    }

    /// Creates a configured URLSession and WebSocketTask for the given request.
    func createWebSocketSession(
        request: URLRequest, delegate: URLSessionDelegate
    ) -> (URLSession, URLSessionWebSocketTask) {
        let sessionConfiguration = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        // Get-only on Linux, where swift-corelibs-foundation never waits.
        sessionConfiguration.waitsForConnectivity = true
        #endif
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60

        let session = URLSession(
            configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation sends the upgrade with `Connection:
        // keep-alive`, and a server that checks for `Upgrade` (uvicorn, so
        // vLLM) answers it as plain HTTP: 404. Measured with Swift 6.2.
        var request = request
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        #endif
        let task = session.webSocketTask(with: request)
        return (session, task)
    }

    // MARK: - URLSessionWebSocketDelegate

    package func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let generation: RealtimeConnectionGeneration? = withBaseState { s in
            guard s.webSocketTask === webSocketTask else { return nil }
            s.socketState = .connected
            return s.connectionGeneration
        }
        guard let generation else { return }

        debugLog("didOpen")
        emit(.connected, from: generation)
        didOpenConnection(on: webSocketTask)
        listenForMessages(on: webSocketTask)
    }

    package func urlSession(
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
            String(data: data, encoding: .utf8)?.trimmed
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

    package func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
            errorMessage: "WebSocket failed: \(describeSocketError(error))"
        )
    }
}
