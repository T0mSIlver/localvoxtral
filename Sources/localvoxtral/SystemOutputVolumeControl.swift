import CoreAudio
import Foundation

/// Reads and writes the main output volume of whatever the system is playing
/// through. A protocol so the ducking fade is unit-testable without moving the
/// volume of the machine running the tests.
protocol SystemOutputVolumeControlling: Sendable {
    /// Current output volume in 0...1, or nil when nothing answers — no output
    /// device, or a device (HDMI, most digital outputs) whose volume the Mac
    /// does not own. Ducking stays out of the way in that case rather than
    /// guessing a level it could not restore.
    func currentVolume() -> Float?

    /// Returns whether the write landed. A failure is reported, never assumed
    /// away: a silent one leaves the user quiet with no dictation running.
    @discardableResult
    func setVolume(_ volume: Float) -> Bool
}

/// The real control, over the default output device.
///
/// `kAudioDevicePropertyVolumeScalar` on the main element is what the volume
/// keys move, but plenty of devices (aggregates, some interfaces) expose no
/// settable main element and only per-channel ones — hence the channel
/// fallback. Deliberately not `AudioHardwareService…VirtualMainVolume`, which
/// papers over the same distinction and is deprecated since macOS 12.
struct CoreAudioSystemOutputVolumeControl: SystemOutputVolumeControlling {
    /// The stereo pair to fall back on when the main element is not settable.
    private static let fallbackChannels: [AudioObjectPropertyElement] = [1, 2]

    func currentVolume() -> Float? {
        guard let deviceID = Self.defaultOutputDeviceID() else { return nil }

        if Self.isVolumeSettable(deviceID, element: kAudioObjectPropertyElementMain),
           let main = Self.readVolume(deviceID, element: kAudioObjectPropertyElementMain)
        {
            return main
        }

        let channelVolumes = Self.fallbackChannels.compactMap { element -> Float? in
            guard Self.isVolumeSettable(deviceID, element: element) else { return nil }
            return Self.readVolume(deviceID, element: element)
        }
        guard !channelVolumes.isEmpty else { return nil }
        return channelVolumes.reduce(0, +) / Float(channelVolumes.count)
    }

    @discardableResult
    func setVolume(_ volume: Float) -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        let clamped = min(max(volume, 0), 1)

        if Self.isVolumeSettable(deviceID, element: kAudioObjectPropertyElementMain) {
            return Self.writeVolume(clamped, deviceID: deviceID, element: kAudioObjectPropertyElementMain)
        }

        // Every settable channel has to take the write, or the pair drifts
        // apart and the restore leaves one side quiet.
        let settable = Self.fallbackChannels.filter { Self.isVolumeSettable(deviceID, element: $0) }
        guard !settable.isEmpty else { return false }
        return settable.allSatisfy {
            Self.writeVolume(clamped, deviceID: deviceID, element: $0)
        }
    }

    // MARK: - CoreAudio

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

    private static func volumeAddress(element: AudioObjectPropertyElement)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func isVolumeSettable(
        _ deviceID: AudioObjectID, element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readVolume(
        _ deviceID: AudioObjectID, element: AudioObjectPropertyElement
    ) -> Float? {
        var address = volumeAddress(element: element)
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func writeVolume(
        _ volume: Float, deviceID: AudioObjectID, element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        var value = Float32(volume)
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        return status == noErr
    }
}

/// Answers "no readable volume" to everything, so a view model built without
/// runtime services (every unit test) cannot move the host's volume.
struct UnavailableSystemOutputVolumeControl: SystemOutputVolumeControlling {
    func currentVolume() -> Float? { nil }

    @discardableResult
    func setVolume(_ volume: Float) -> Bool { false }
}
