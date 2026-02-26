import Foundation
import Synchronization
import os

/// Shared base for WebSocket-based realtime clients.
///
/// This class is abstract — do not instantiate directly. Subclasses must override:
///  - `withBaseState(_:)` — provide locked access to the embedded `BaseState`
///  - `handle(json:)` — protocol-specific event dispatch
///  - `didOpenConnection(on:)` — post-connect setup (timers, config flush)
///  - `handleTerminalSocketError(for:errorMessage:)` — full state cleanup on socket failure
///  - `logger` — os.Logger instance for debug output
class BaseRealtimeWebSocketClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate,
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
        var onEvent: (@Sendable (RealtimeEvent) -> Void)?
        var isUserInitiatedDisconnect = false
    }

    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    // MARK: - Abstract interface (override in subclasses)

    /// Protocol-specific JSON event handling.
    func handle(json: [String: Any]) {
        // Subclasses override.
    }

    /// Called when the WebSocket connection opens. Subclasses use this for
    /// post-connect setup (ping timers, initial config flush, etc.).
    func didOpenConnection(on task: URLSessionWebSocketTask) {
        // Subclasses override.
    }

    /// The os.Logger instance to use for debug output.
    var logger: Logger { Log.realtime }

    // MARK: - Must be provided by subclass for state access

    /// Subclasses must return their current base state under their lock.
    func withBaseState<R>(_ body: (inout BaseState) -> R) -> R {
        fatalError("Subclasses must override withBaseState(_:)")
    }

    // MARK: - Shared helpers

    func emit(_ event: RealtimeEvent) {
        let handler: (@Sendable (RealtimeEvent) -> Void)? = withBaseState { $0.onEvent }
        guard let handler else { return }
        handler(event)
    }

    func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        logger.debug("\(message)")
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
        let outcome: (error: String?, disconnected: Bool) = withBaseState { s in
            guard s.socketState != .disconnected, s.webSocketTask === task else {
                return (nil, false)
            }
            let shouldEmitError = !s.isUserInitiatedDisconnect
            self.closeBaseStateLocked(&s, cancelTask: false)
            return (shouldEmitError ? errorMessage : nil, true)
        }

        if let error = outcome.error {
            emit(.error(error))
        }
        if outcome.disconnected {
            emit(.disconnected)
        }
    }

    /// Tears down the base socket fields. Subclasses call this from their own
    /// `closeSocketLocked` after cleaning up subclass-specific state.
    func closeBaseStateLocked(_ s: inout BaseState, cancelTask: Bool) {
        if cancelTask {
            s.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        }
        s.webSocketTask = nil
        s.urlSession?.invalidateAndCancel()
        s.urlSession = nil
        s.socketState = .disconnected
        s.isUserInitiatedDisconnect = false
    }

    func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            let shouldHandleResult: Bool = self.withBaseState { s in
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
                    errorMessage: "WebSocket receive failed: \(self.describeSocketError(error))"
                )
            }
        }
    }

    func handle(message: URLSessionWebSocketTask.Message) {
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

    func handle(text: String) {
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
        sessionConfiguration.waitsForConnectivity = true
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60

        let session = URLSession(
            configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        return (session, task)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let isCurrentTask: Bool = withBaseState { s in
            guard s.webSocketTask === webSocketTask else { return false }
            s.socketState = .connected
            return true
        }
        guard isCurrentTask else { return }

        debugLog("didOpen")
        emit(.connected)
        didOpenConnection(on: webSocketTask)
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
            errorMessage: "WebSocket failed: \(describeSocketError(error))"
        )
    }
}
