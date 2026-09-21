import CoreAudio
import Foundation

/// An output device and its volume, taken together. The pair is the point: a
/// duck is taken against ONE device, and the restore has to go back to that
/// device rather than to whatever is default by the time the session ends.
struct OutputVolumeReading: Equatable, Sendable {
    let deviceUID: String
    let volume: Float
}

/// Reads and writes the main output volume of a specific device. A protocol so
/// the ducking fade is unit-testable without moving the volume of the machine
/// running the tests.
protocol SystemOutputVolumeControlling: Sendable {
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

/// The real control, over CoreAudio.
///
/// `kAudioDevicePropertyVolumeScalar` on the main element is what the volume
/// keys move. A device that does not offer a settable main element — some
/// aggregates and interfaces expose per-channel scalars only — is reported as
/// having no volume at all, and left alone: ducking its channels together
/// would flatten a stereo balance the user set, and restoring them would not
/// give it back. Deliberately not `AudioHardwareService…VirtualMainVolume`,
/// which papers over the same distinction and is deprecated since macOS 12.
struct CoreAudioSystemOutputVolumeControl: SystemOutputVolumeControlling {
    func readDefaultOutput() -> OutputVolumeReading? {
        guard let deviceID = Self.defaultOutputDeviceID(),
              let deviceUID = AudioDeviceManager.deviceUID(for: deviceID),
              let volume = Self.readMainVolume(deviceID)
        else { return nil }
        return OutputVolumeReading(deviceUID: deviceUID, volume: volume)
    }

    func volume(forDeviceUID deviceUID: String) -> Float? {
        guard let deviceID = Self.outputDeviceID(forUID: deviceUID) else { return nil }
        return Self.readMainVolume(deviceID)
    }

    @discardableResult
    func setVolume(_ volume: Float, forDeviceUID deviceUID: String) -> Bool {
        guard let deviceID = Self.outputDeviceID(forUID: deviceUID) else { return false }
        guard Self.isMainVolumeSettable(deviceID) else { return false }

        var address = Self.mainVolumeAddress
        var value = Float32(min(max(volume, 0), 1))
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        return status == noErr
    }

    // MARK: - CoreAudio

    private static let mainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// By UID rather than by "whatever is default now": a restore must reach
    /// the device the duck was taken against even after the user switched
    /// outputs mid-session.
    private static func outputDeviceID(forUID deviceUID: String) -> AudioObjectID? {
        AudioDeviceManager.allAudioDeviceIDs().first { candidate in
            AudioDeviceManager.deviceUID(for: candidate) == deviceUID
        }
    }

    /// Settable is part of the question, not a separate one: a level this app
    /// can read but not write is a level it could never put back.
    private static func isMainVolumeSettable(_ deviceID: AudioObjectID) -> Bool {
        var address = mainVolumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readMainVolume(_ deviceID: AudioObjectID) -> Float? {
        guard isMainVolumeSettable(deviceID) else { return nil }
        var address = mainVolumeAddress
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }
}

/// Answers "no output volume" to everything, so a view model built without
/// runtime services (every unit test) cannot move the host's volume.
struct UnavailableSystemOutputVolumeControl: SystemOutputVolumeControlling {
    func readDefaultOutput() -> OutputVolumeReading? { nil }
    func volume(forDeviceUID deviceUID: String) -> Float? { nil }

    @discardableResult
    func setVolume(_ volume: Float, forDeviceUID deviceUID: String) -> Bool { false }
}
