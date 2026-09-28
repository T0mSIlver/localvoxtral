import Foundation
import Synchronization
import localvoxtralCore

/// Records what the ducking fade writes, per device, and can refuse writes or
/// make a device vanish the way an unplugged one does.
package final class FakeOutputVolumeControl: SystemOutputVolumeControlling, @unchecked Sendable {
    private struct State {
        var defaultDeviceUID: String
        var volumes: [String: Float]
        var writes: [Float] = []
        var attemptedWrites = 0
        var refuseWrites = false
    }

    private let state: Mutex<State>

    /// A device whose volume the Mac does not own is simply absent from
    /// `volumes`, which is how the real control reports it.
    package init(defaultDeviceUID: String = "device-a", volume: Float?) {
        state = Mutex(
            State(
                defaultDeviceUID: defaultDeviceUID,
                volumes: volume.map { [defaultDeviceUID: $0] } ?? [:]
            ))
    }

    package var writes: [Float] { state.withLock { $0.writes } }
    package var attemptedWrites: Int { state.withLock { $0.attemptedWrites } }

    package var refuseWrites: Bool {
        get { state.withLock { $0.refuseWrites } }
        set { state.withLock { $0.refuseWrites = newValue } }
    }

    package func clearWrites() {
        state.withLock {
            $0.writes.removeAll()
            $0.attemptedWrites = 0
        }
    }

    /// The user switched outputs, or plugged in headphones.
    package func switchDefault(to deviceUID: String, volume: Float) {
        state.withLock {
            $0.defaultDeviceUID = deviceUID
            $0.volumes[deviceUID] = volume
        }
    }

    /// The device was unplugged: it answers nothing and takes no writes.
    package func disconnect(_ deviceUID: String) {
        state.withLock { $0.volumes[deviceUID] = nil }
    }

    package func volume(of deviceUID: String) -> Float? {
        state.withLock { $0.volumes[deviceUID] }
    }

    package func readDefaultOutput() -> OutputVolumeReading? {
        state.withLock {
            guard let volume = $0.volumes[$0.defaultDeviceUID] else { return nil }
            return OutputVolumeReading(deviceUID: $0.defaultDeviceUID, volume: volume)
        }
    }

    package func volume(forDeviceUID deviceUID: String) -> Float? {
        state.withLock { $0.volumes[deviceUID] }
    }

    @discardableResult
    package func setVolume(_ volume: Float, forDeviceUID deviceUID: String) -> Bool {
        state.withLock {
            $0.attemptedWrites += 1
            guard !$0.refuseWrites, $0.volumes[deviceUID] != nil else { return false }
            $0.volumes[deviceUID] = volume
            $0.writes.append(volume)
            return true
        }
    }
}
