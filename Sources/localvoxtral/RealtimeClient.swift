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
}

protocol RealtimeClient: AnyObject {
    var supportsPeriodicCommit: Bool { get }
    var isConnected: Bool { get }

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeEvent) -> Void)
    func connect(configuration: RealtimeSessionConfiguration) throws
    func disconnect()
    func sendAudioChunk(_ pcm16Data: Data)
    func sendCommit(final: Bool)
}
