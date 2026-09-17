import Foundation

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

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeEvent) -> Void)
    func connect(configuration: RealtimeSessionConfiguration) throws
    func disconnect()
    func sendAudioChunk(_ pcm16Data: Data)
    func sendCommit(final: Bool)
}
