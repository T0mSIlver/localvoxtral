import Foundation
import Synchronization
import localvoxtralCore

/// A realtime client that opens no socket: every connect, commit and audio send
/// is recorded, and the test decides when `isConnected` flips.
package final class FakeRealtimeClient: RealtimeClient, @unchecked Sendable {
    private struct State {
        var isConnected = false
        /// Nil: ready whenever connected, as a server that answers at once.
        var sessionReady: Bool?
        var connectCount = 0
        var disconnectCount = 0
        var connectConfigurations: [RealtimeSessionConfiguration] = []
        var commits: [Bool] = []
        var sentAudio = Data()
        var unsentAudio = Data()
        var refusesAudio = false
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
    package var isSessionReady: Bool { state.withLock { $0.sessionReady ?? $0.isConnected } }
    package var connectionGeneration: RealtimeConnectionGeneration {
        state.withLock { $0.connectionGeneration }
    }
    package var connectCount: Int { state.withLock { $0.connectCount } }
    package var disconnectCount: Int { state.withLock { $0.disconnectCount } }
    package var commits: [Bool] { state.withLock { $0.commits } }
    package var sentAudioBytes: Int { state.withLock { $0.sentAudio.count } }
    /// Every PCM byte the client took, in order.
    package var sentAudio: Data { state.withLock { $0.sentAudio } }
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

    /// Holds `isSessionReady` at `ready` whatever `isConnected` says; nil
    /// goes back to following it.
    package func setSessionReady(_ ready: Bool?) {
        state.withLock { $0.sessionReady = ready }
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

    @discardableResult
    package func sendAudioChunk(_ pcm16Data: Data) -> Bool {
        state.withLock {
            guard !$0.refusesAudio else { return false }
            $0.sentAudio.append(pcm16Data)
            return true
        }
    }

    /// While set, audio is dropped as a client whose socket just died drops
    /// it, whatever `isConnected` still says.
    package func setRefusesAudio(_ refuses: Bool) {
        state.withLock { $0.refusesAudio = refuses }
    }

    /// What the next `takeUnsentAudio` hands back, as a socket that closed
    /// before its handshake leaves it.
    package func setUnsentAudio(_ audio: Data) {
        state.withLock { $0.unsentAudio = audio }
    }

    package func takeUnsentAudio() -> Data {
        state.withLock { s in
            defer { s.unsentAudio = Data() }
            return s.unsentAudio
        }
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
