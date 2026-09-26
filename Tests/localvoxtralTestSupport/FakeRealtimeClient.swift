import Foundation
import Synchronization
import localvoxtralCore

/// A realtime client that opens no socket: every connect, commit and audio send
/// is recorded, and the test decides when `isConnected` flips.
package final class FakeRealtimeClient: RealtimeClient, @unchecked Sendable {
    private struct State {
        var isConnected = false
        var connectCount = 0
        var disconnectCount = 0
        var connectConfigurations: [RealtimeSessionConfiguration] = []
        var commits: [Bool] = []
        var sentAudioBytes = 0
        var connectionGeneration: RealtimeConnectionGeneration = .none
        var handler: (@Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void)?
    }

    private let state = Mutex(State())

    package init() {}

    package var supportsPeriodicCommit: Bool { true }
    package var isConnected: Bool { state.withLock { $0.isConnected } }
    package var connectionGeneration: RealtimeConnectionGeneration {
        state.withLock { $0.connectionGeneration }
    }
    package var connectCount: Int { state.withLock { $0.connectCount } }
    package var disconnectCount: Int { state.withLock { $0.disconnectCount } }
    package var commits: [Bool] { state.withLock { $0.commits } }
    package var sentAudioBytes: Int { state.withLock { $0.sentAudioBytes } }
    package var connectConfigurations: [RealtimeSessionConfiguration] {
        state.withLock { $0.connectConfigurations }
    }

    package func setConnected(_ connected: Bool) {
        state.withLock { $0.isConnected = connected }
    }

    /// Stamps a fresh generation the way a real `connect` would, without
    /// counting as a dial: the fixture starts every test already on a socket.
    @discardableResult
    package func stampNewConnection() -> RealtimeConnectionGeneration {
        state.withLock {
            $0.connectionGeneration = .next()
            return $0.connectionGeneration
        }
    }

    package func setEventHandler(
        _ handler: @escaping @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void
    ) {
        state.withLock { $0.handler = handler }
    }

    package func connect(configuration: RealtimeSessionConfiguration) throws {
        state.withLock {
            $0.connectCount += 1
            $0.connectConfigurations.append(configuration)
            $0.connectionGeneration = .next()
        }
    }

    package func disconnect() {
        state.withLock {
            $0.disconnectCount += 1
            $0.isConnected = false
        }
    }

    package func sendAudioChunk(_ pcm16Data: Data) {
        state.withLock { $0.sentAudioBytes += pcm16Data.count }
    }

    package func sendCommit(final: Bool) {
        state.withLock { $0.commits.append(final) }
    }
}
