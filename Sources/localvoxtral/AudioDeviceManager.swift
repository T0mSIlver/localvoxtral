import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum AudioDeviceManager {
    static func allInputDevices() -> [MicrophoneInputDevice] {
        allAudioDeviceIDs().compactMap { deviceID in
            guard isSelectableInputDevice(deviceID) else { return nil }
            guard let uid = deviceUID(for: deviceID) else { return nil }
            let name = deviceName(for: deviceID) ?? "Input \(uid)"
            return MicrophoneInputDevice(id: uid, name: name)
        }
    }

    static func defaultInputDeviceObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func defaultInputDeviceID() -> String? {
        guard let objectID = defaultInputDeviceObjectID() else { return nil }
        return deviceUID(for: objectID)
    }

    @discardableResult
    static func setSystemDefaultInputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &newDeviceID
        )

        return status == noErr
    }

    static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedCFString: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &unmanagedCFString
        )
        guard status == noErr, let unmanagedCFString else { return nil }

        let uid = unmanagedCFString.takeUnretainedValue() as String
        return uid.isEmpty ? nil : uid
    }

    static func deviceName(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedCFString: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &unmanagedCFString
        )
        guard status == noErr, let unmanagedCFString else { return nil }

        let name = unmanagedCFString.takeUnretainedValue() as String
        return name.isEmpty ? nil : name
    }

    static func audioDeviceID(forUID uid: String) -> AudioObjectID? {
        let inputMatches = allAudioDeviceIDs().filter { deviceID in
            guard deviceUID(for: deviceID) == uid else { return false }
            return isSelectableInputDevice(deviceID)
        }

        guard !inputMatches.isEmpty else { return nil }
        if let defaultInputID = defaultInputDeviceObjectID(),
           inputMatches.contains(defaultInputID)
        {
            return defaultInputID
        }
        return inputMatches[0]
    }

    static func deviceHasInput(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer)
        guard dataStatus == noErr else { return false }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channelCount = buffers.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }

        return channelCount > 0
    }

    static func isSelectableInputDevice(_ deviceID: AudioObjectID) -> Bool {
        guard deviceHasInput(deviceID) else { return false }
        guard deviceIsAlive(deviceID) else { return false }
        guard !deviceIsHidden(deviceID) else { return false }
        guard deviceCanBeDefaultInput(deviceID) else { return false }
        return true
    }

    static func deviceIsAlive(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    static func deviceIsHidden(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyIsHidden,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    /// Set the input device on an Audio Unit directly, without changing the
    /// system-wide default. This avoids activating the previous default device
    /// on restore and eliminates the need to restore at all.
    @discardableResult
    static func setInputDevice(_ deviceID: AudioObjectID, on audioUnit: AudioUnit) -> Bool {
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        return status == noErr
    }

    static func deviceCanBeDefaultInput(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioDevicePropertyScopeInput,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    static func deviceUInt32Property(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else { return nil }
        return value
    }

    static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)

        let dataStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }

        guard dataStatus == noErr else {
            return []
        }

        return deviceIDs
    }
}
