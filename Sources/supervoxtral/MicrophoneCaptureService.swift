@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

struct MicrophoneInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum MicrophoneAuthorizationStatus {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum MicrophoneCaptureError: LocalizedError {
    case preferredDeviceUnavailable(String)
    case failedToSetPreferredDevice(String)
    case invalidInputFormat
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .preferredDeviceUnavailable(let deviceID):
            return "Selected microphone (\(deviceID)) is no longer available."
        case .failedToSetPreferredDevice(let deviceID):
            return "Failed to activate selected microphone (\(deviceID))."
        case .invalidInputFormat:
            return "Microphone input format is invalid."
        case .converterCreationFailed:
            return "Failed to create audio converter for microphone input."
        }
    }
}

final class MicrophoneCaptureService: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private var audioEngine: AVAudioEngine?
    private let processingQueue = DispatchQueue(label: "supervoxtral.microphone.processing")
    private static let targetSampleRate: Double = 16_000
    private let targetOutputFormat: AVAudioFormat
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?
    private var didInstallInputDeviceListeners = false
    var onConfigurationChange: (@Sendable () -> Void)?
    var onInputDevicesChanged: (@Sendable () -> Void)?

    init() {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("Unable to create PCM16 output format for microphone conversion.")
        }

        targetOutputFormat = outputFormat
        startMonitoringInputDevices()
    }

    deinit {
        stop()
        stopMonitoringInputDevices()
    }

    func authorizationStatus() -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        switch authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        }
    }

    func availableInputDevices() -> [MicrophoneInputDevice] {
        allInputDevices()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInputDeviceID() -> String? {
        guard let objectID = defaultInputDeviceObjectID() else { return nil }
        return deviceUID(for: objectID)
    }

    func isCapturing() -> Bool {
        guard let audioEngine else { return false }
        return audioEngine.isRunning && tapInstalled
    }

    func start(preferredDeviceID: String?, chunkHandler: @escaping ChunkHandler) throws {
        stop()
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        try configureInputDevice(preferredDeviceID, on: audioEngine)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.invalidInputFormat
        }

        let outputFormat = targetOutputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.converterCreationFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let processingQueue = processingQueue

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            guard let chunk = Self.convertToPCM16Mono(buffer: buffer, converter: converter, outputFormat: outputFormat) else {
                return
            }

            processingQueue.async {
                chunkHandler(chunk)
            }
        }

        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            throw error
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let audioEngine {
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
            }

            if audioEngine.isRunning {
                audioEngine.stop()
            }

            audioEngine.reset()
        }

        audioEngine = nil
        tapInstalled = false
    }

    private func configureInputDevice(_ preferredDeviceID: String?, on audioEngine: AVAudioEngine) throws {
        if let preferredDeviceID,
           !preferredDeviceID.isEmpty,
           preferredDeviceID != defaultInputDeviceID(),
           let preferredObjectID = audioDeviceID(forUID: preferredDeviceID)
        {
            guard setInputDevice(preferredObjectID, on: audioEngine) else {
                throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
            }
            return
        }

        if let preferredDeviceID,
           !preferredDeviceID.isEmpty,
           preferredDeviceID != defaultInputDeviceID()
        {
            throw MicrophoneCaptureError.preferredDeviceUnavailable(preferredDeviceID)
        }
    }

    @discardableResult
    private func setInputDevice(_ deviceID: AudioObjectID, on audioEngine: AVAudioEngine) -> Bool {
        do {
            try audioEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
            return true
        } catch {
            return false
        }
    }

    private func allInputDevices() -> [MicrophoneInputDevice] {
        allAudioDeviceIDs().compactMap { deviceID in
            guard isSelectableInputDevice(deviceID) else { return nil }
            guard let uid = deviceUID(for: deviceID) else { return nil }
            let name = deviceName(for: deviceID) ?? "Input \(uid)"
            return MicrophoneInputDevice(id: uid, name: name)
        }
    }

    private func isSelectableInputDevice(_ deviceID: AudioObjectID) -> Bool {
        guard deviceHasInput(deviceID) else { return false }
        guard deviceIsAlive(deviceID) else { return false }
        guard !deviceIsHidden(deviceID) else { return false }
        guard deviceCanBeDefaultInput(deviceID) else { return false }
        return true
    }

    private func deviceIsAlive(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    private func deviceIsHidden(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyIsHidden,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    private func deviceCanBeDefaultInput(_ deviceID: AudioObjectID) -> Bool {
        (deviceUInt32Property(
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioDevicePropertyScopeInput,
            deviceID: deviceID
        ) ?? 0) != 0
    }

    private func deviceUInt32Property(
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

    private func allAudioDeviceIDs() -> [AudioObjectID] {
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

    private func defaultInputDeviceObjectID() -> AudioObjectID? {
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

    private func audioDeviceID(forUID uid: String) -> AudioObjectID? {
        allAudioDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    private func deviceUID(for deviceID: AudioObjectID) -> String? {
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

    private func deviceName(for deviceID: AudioObjectID) -> String? {
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

    private func deviceHasInput(_ deviceID: AudioObjectID) -> Bool {
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

    private static let inputDevicePropertyListener: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        let service = Unmanaged<MicrophoneCaptureService>.fromOpaque(clientData).takeUnretainedValue()
        service.notifyInputDevicesChanged()
        return noErr
    }

    private func startMonitoringInputDevices() {
        guard !didInstallInputDeviceListeners else { return }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let clientData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let devicesStatus = AudioObjectAddPropertyListener(
            systemObject,
            &devicesAddress,
            Self.inputDevicePropertyListener,
            clientData
        )
        let defaultStatus = AudioObjectAddPropertyListener(
            systemObject,
            &defaultInputAddress,
            Self.inputDevicePropertyListener,
            clientData
        )

        if devicesStatus == noErr, defaultStatus == noErr {
            didInstallInputDeviceListeners = true
            return
        }

        if devicesStatus == noErr {
            _ = AudioObjectRemovePropertyListener(
                systemObject,
                &devicesAddress,
                Self.inputDevicePropertyListener,
                clientData
            )
        }
        if defaultStatus == noErr {
            _ = AudioObjectRemovePropertyListener(
                systemObject,
                &defaultInputAddress,
                Self.inputDevicePropertyListener,
                clientData
            )
        }
    }

    private func stopMonitoringInputDevices() {
        guard didInstallInputDeviceListeners else { return }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let clientData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        _ = AudioObjectRemovePropertyListener(
            systemObject,
            &devicesAddress,
            Self.inputDevicePropertyListener,
            clientData
        )
        _ = AudioObjectRemovePropertyListener(
            systemObject,
            &defaultInputAddress,
            Self.inputDevicePropertyListener,
            clientData
        )

        didInstallInputDeviceListeners = false
    }

    private func notifyInputDevicesChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onInputDevicesChanged?()
        }
    }

    private static func convertToPCM16Mono(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) -> Data? {
        guard buffer.frameLength > 0 else { return nil }

        let inputFrameCount = Double(buffer.frameLength)
        let inputSampleRate = max(1, buffer.format.sampleRate)
        let conversionRatio = outputFormat.sampleRate / inputSampleRate
        let estimatedOutputFrames = max(1, Int(ceil(inputFrameCount * conversionRatio)) + 32)

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutputFrames)
        ) else {
            return nil
        }

        let sourceBuffer = buffer
        let didConsume = Mutex(false)
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            let alreadyConsumed = didConsume.withLock { consumed in
                let was = consumed
                consumed = true
                return was
            }
            if !alreadyConsumed {
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            outStatus.pointee = .noDataNow
            return nil
        }

        guard conversionError == nil else { return nil }
        guard status == .haveData || status == .inputRanDry else { return nil }

        let frameCount = Int(convertedBuffer.frameLength)
        guard frameCount > 0,
              let int16ChannelData = convertedBuffer.int16ChannelData
        else {
            return nil
        }

        let byteCount = frameCount * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
        return Data(bytes: int16ChannelData[0], count: byteCount)
    }
}
