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
        var contextBudgets: [RealtimeContextBudget?] = []
        var connectionGeneration: RealtimeConnectionGeneration = .none
        var handler: (@Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void)?
        var onConnect: (@Sendable () -> Void)?
        var onCommit: (@Sendable (_ final: Bool) -> Void)?
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
    /// Every budget the session set, in order.
    package var contextBudgets: [RealtimeContextBudget?] { state.withLock { $0.contextBudgets } }
    package var connectConfigurations: [RealtimeSessionConfiguration] {
        state.withLock { $0.connectConfigurations }
    }

    /// Runs after each `connect`, outside the lock, so it may `emit`.
    package func setOnConnect(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.onConnect = hook }
    }

    /// Runs after each `sendCommit`, outside the lock, so it may `emit`.
    package func setOnCommit(_ hook: (@Sendable (_ final: Bool) -> Void)?) {
        state.withLock { $0.onCommit = hook }
    }

    /// Hands `event` to the handler as the current socket's, the way a real
    /// client reports what its server sent.
    package func emit(_ event: RealtimeEvent) {
        let (handler, generation) = state.withLock { ($0.handler, $0.connectionGeneration) }
        handler?(event, generation)
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
        let hook = state.withLock {
            $0.connectCount += 1
            $0.connectConfigurations.append(configuration)
            $0.connectionGeneration = .next()
            return $0.onConnect
        }
        hook?()
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

    package func setContextBudget(_ budget: RealtimeContextBudget?) {
        state.withLock { $0.contextBudgets.append(budget) }
    }

    package func sendCommit(final: Bool) {
        let hook = state.withLock {
            $0.commits.append(final)
            return $0.onCommit
        }
        hook?(final)
    }
}
