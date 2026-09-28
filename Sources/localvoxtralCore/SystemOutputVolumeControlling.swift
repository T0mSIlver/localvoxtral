import Foundation

/// An output device and its volume, taken together. The pair is the point: a
/// duck is taken against ONE device, and the restore has to go back to that
/// device rather than to whatever is default by the time the session ends.
package struct OutputVolumeReading: Equatable, Sendable {
    package let deviceUID: String
    package let volume: Float

    package init(deviceUID: String, volume: Float) {
        self.deviceUID = deviceUID
        self.volume = volume
    }
}

/// Reads and writes the main output volume of a specific device. A protocol so
/// the ducking fade is unit-testable without moving the volume of the machine
/// running the tests.
package protocol SystemOutputVolumeControlling: Sendable {
    /// The device the system is playing through and its volume, or nil when
    /// nothing answers — no output device, or a device (HDMI, most digital
    /// outputs) whose volume the Mac does not own. Ducking stays out of the
    /// way in that case rather than guessing a level it could not restore.
    func readDefaultOutput() -> OutputVolumeReading?

    /// That device's volume now, or nil when it is no longer connected.
    func volume(forDeviceUID deviceUID: String) -> Float?

    /// Returns whether the write landed. A failure is reported, never assumed
    /// away: a silent one leaves the user quiet with no dictation running.
    @discardableResult
    func setVolume(_ volume: Float, forDeviceUID deviceUID: String) -> Bool
}

/// Answers "no output volume" to everything, so a view model built without
/// runtime services (every unit test) cannot move the host's volume.
package struct UnavailableSystemOutputVolumeControl: SystemOutputVolumeControlling {
    package init() {}

    package func readDefaultOutput() -> OutputVolumeReading? { nil }
    package func volume(forDeviceUID deviceUID: String) -> Float? { nil }

    @discardableResult
    package func setVolume(_ volume: Float, forDeviceUID deviceUID: String) -> Bool { false }
}
