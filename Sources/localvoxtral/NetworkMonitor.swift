import Foundation
import Network
import os

/// Observes system network path changes via `NWPathMonitor` and invokes
/// callbacks when connectivity is lost or restored. Thread-safe and Sendable.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "localvoxtral.network-monitor")
    private let state = NSLock()
    private var _isConnected = true
    private var _onChange: (@Sendable (_ connected: Bool) -> Void)?

    /// Whether the network currently has a satisfied path.
    var isConnected: Bool {
        state.lock()
        defer { state.unlock() }
        return _isConnected
    }

    /// Called on a background queue when connectivity changes.
    /// The boolean is `true` when the network becomes reachable, `false` when lost.
    var onChange: (@Sendable (_ connected: Bool) -> Void)? {
        get {
            state.lock()
            defer { state.unlock() }
            return _onChange
        }
        set {
            state.lock()
            defer { state.unlock() }
            _onChange = newValue
        }
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let callback: (@Sendable (_ connected: Bool) -> Void)?

            self.state.lock()
            let wasConnected = self._isConnected
            self._isConnected = connected
            callback = self._onChange
            self.state.unlock()

            guard connected != wasConnected else { return }
            Log.dictation.info("network path changed: \(connected ? "connected" : "disconnected")")
            callback?(connected)
        }
    }

    func start() {
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
