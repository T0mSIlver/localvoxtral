import Foundation
import Synchronization

struct RealtimeSessionConfiguration: Sendable {
    let endpoint: URL
    let apiKey: String
    let model: String

    init(endpoint: URL, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }
}

/// Which socket an event came from (#417).
///
/// `RealtimeEvent` says what happened, never which connection it happened to,
/// and both clients report into one handler reached through
/// `DispatchQueue.main.async` — so a socket the session has already retired can
/// report its close, its error or even a transcript long after the session
/// moved on. `connect()` stamps a fresh generation on the socket it opens,
/// every event that socket raises carries that stamp, and the session refuses
/// anything not stamped with the generation it is on.
///
/// Values come from one process-wide counter, so the two clients can never hand
/// out the same one: after a backend-mode switch, the other client's retired
/// socket cannot impersonate the live one.
struct RealtimeConnectionGeneration: Hashable, Sendable, CustomStringConvertible {
    /// No connection: what a client carries before its first `connect()`, and
    /// what the session is on between a socket's death and the next dial.
    static let none = RealtimeConnectionGeneration(value: 0)

    let value: Int

    var description: String { value == 0 ? "none" : "#\(value)" }

    private static let counter = Mutex(0)

    /// The next unused generation. Never equal to `.none`.
    static func next() -> RealtimeConnectionGeneration {
        counter.withLock { current in
            current += 1
            return RealtimeConnectionGeneration(value: current)
        }
    }
}

enum RealtimeEvent: Sendable {
    case connected
    case disconnected
    case status(String)
    case partialTranscript(String)
    case finalTranscript(String)
    case transcriptionFinalized
    case error(String)
    /// The backend stopped transcribing before the final commit (the bundled helper's
    /// utterance limit, or a model end-of-stream). The message is one short sentence meant
    /// for the status line; the connection stays open (#314).
    case transcriptionStopped(String)
}

/// `Sendable` because the session's audio-send and periodic-commit tasks hold
/// the client across a suspension point. Both conformers are final classes
/// whose mutable state lives behind a `Mutex` (`@unchecked Sendable`); the
/// view model reaches them through `any RealtimeClient`, which has to carry the
/// same guarantee for those captures to compile under strict concurrency.
protocol RealtimeClient: AnyObject, Sendable {
    var supportsPeriodicCommit: Bool { get }
    var isConnected: Bool { get }
    /// The generation stamped on the socket the most recent `connect()` opened,
    /// `.none` before the first one. Read right after a successful `connect()`:
    /// that is the connection the session is now on.
    var connectionGeneration: RealtimeConnectionGeneration { get }

    /// The handler is handed the generation of the socket that raised the
    /// event, in the same call — a parallel channel could be dropped or arrive
    /// out of order, and the main-queue FIFO the handler relies on for
    /// back-to-back events only orders what it is given together.
    func setEventHandler(
        _ handler: @escaping @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void)
    func connect(configuration: RealtimeSessionConfiguration) throws
    func disconnect()
    func sendAudioChunk(_ pcm16Data: Data)
    func sendCommit(final: Bool)
}
