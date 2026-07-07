import Foundation
import Network
import Synchronization

/// Minimal loopback-only HTTP/1.1 server: one request per connection,
/// `Connection: close` semantics. This is deliberately not a general web
/// server — it exists to expose /health and /v1/chat/completions to the
/// supervising app on 127.0.0.1.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "localvoxtral.polishd.http")

    /// Pass port 0 to bind an ephemeral port (tests); read `boundPort` after
    /// `start()` returns.
    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        self.listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public var boundPort: UInt16 {
        listener.port?.rawValue ?? 0
    }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let resumeOnce = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    resumeOnce.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    resumeOnce.run { continuation.resume(throwing: error) }
                    self?.listener.cancel()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A continuation may be resumed exactly once, but the listener can emit
    /// `.waiting` and later `.ready` (or several failures) — this collapses
    /// them to the first terminal transition.
    private final class ResumeOnce: Sendable {
        private let resumed = Mutex(false)

        func run(_ body: () -> Void) {
            let first = resumed.withLock { value in
                let previous = value
                value = true
                return !previous
            }
            if first { body() }
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulator: HTTPRequestAccumulator())
    }

    private func receive(on connection: NWConnection, accumulator: HTTPRequestAccumulator) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulator = accumulator
            if let data, !data.isEmpty {
                do {
                    if let request = try accumulator.append(data) {
                        self.respond(to: request, on: connection)
                        return
                    }
                } catch {
                    self.send(
                        HTTPResponse.json(
                            400,
                            ChatCompletionErrorResponse(
                                message: "malformed request: \(error)", type: "invalid_request_error"
                            )
                        ),
                        on: connection
                    )
                    return
                }
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, accumulator: accumulator)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        Task { [handler] in
            let response = await handler(request)
            self.send(response, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
