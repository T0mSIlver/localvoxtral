import Foundation

protocol RealtimeClient: AnyObject {
    var supportsPeriodicCommit: Bool { get }

    func setEventHandler(_ handler: @escaping @Sendable (RealtimeWebSocketClient.Event) -> Void)
    func connect(configuration: RealtimeWebSocketClient.Configuration) throws
    func disconnect()
    func disconnectAfterFinalCommitIfNeeded()
    func sendAudioChunk(_ pcm16Data: Data)
    func sendCommit(final: Bool)
}
