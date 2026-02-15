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

    private struct InputFormatDescriptor: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let isInterleaved: Bool
    }

    private final class ConverterState {
        var inputFormatDescriptor: InputFormatDescriptor?
        var converter: AVAudioConverter?
        var consecutiveFailureCount = 0
    }

    private var audioEngine: AVAudioEngine?
    private let processingQueue = DispatchQueue(label: "supervoxtral.microphone.processing")
    private let lastCapturedAudioAt = Mutex<Date?>(nil)
    private let hasCapturedAudioInCurrentRunFlag = Mutex(false)
    private static let targetSampleRate: Double = 16_000
    private let targetOutputFormat: AVAudioFormat
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?
    private var didInstallInputDeviceListeners = false
    private var previousDefaultInputDeviceObjectID: AudioObjectID?
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["SUPERVOXTRAL_DEBUG"] == "1"
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

    func hasRecentCapturedAudio(within interval: TimeInterval) -> Bool {
        guard interval > 0 else { return false }
        let recentCutoff = Date().addingTimeInterval(-interval)
        return lastCapturedAudioAt.withLock { timestamp in
            guard let timestamp else { return false }
            return timestamp >= recentCutoff
        }
    }

    func hasCapturedAudioInCurrentRun() -> Bool {
        hasCapturedAudioInCurrentRunFlag.withLock { $0 }
    }

    @discardableResult
    func resumeIfNeeded() -> Bool {
        guard let audioEngine else { return false }
        guard !audioEngine.isRunning else {
            return false
        }

        do {
            try audioEngine.start()
            let resumed = audioEngine.isRunning && tapInstalled
            debugLog("resumeIfNeeded resumed=\(resumed)")
            return resumed
        } catch {
            debugLog("resumeIfNeeded failed error=\(error.localizedDescription)")
            return false
        }
    }

    func start(preferredDeviceID: String?, chunkHandler: @escaping ChunkHandler) throws {
        stop(restoreDefaultInput: false)
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }
        debugLog("start preferredDeviceID=\(preferredDeviceID ?? "default")")
        // Important: select/switch the input route before creating AVAudioEngine.
        // Creating the engine first can bind to a stale route and cause -10868 on start.
        try configureInputDevice(preferredDeviceID)

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let outputFormat = targetOutputFormat

        let processingQueue = processingQueue
        let hasLoggedFirstChunk = Mutex(false)
        let converterState = ConverterState()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            let inputFormat = buffer.format
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                return
            }

            let inputFormatDescriptor = Self.inputFormatDescriptor(for: inputFormat)
            if converterState.converter == nil || converterState.inputFormatDescriptor != inputFormatDescriptor {
                guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                    if self.debugLoggingEnabled {
                        self.debugLog(
                            "converter creation failed sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
                        )
                    }
                    return
                }
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converterState.converter = converter
                converterState.inputFormatDescriptor = inputFormatDescriptor
                converterState.consecutiveFailureCount = 0
                self.debugLog(
                    "converter configured sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved)"
                )
            }

            guard let converter = converterState.converter,
                  let chunk = Self.convertToPCM16Mono(buffer: buffer, converter: converter, outputFormat: outputFormat)
            else {
                converterState.consecutiveFailureCount += 1
                if self.debugLoggingEnabled,
                   (converterState.consecutiveFailureCount == 1
                       || converterState.consecutiveFailureCount % 50 == 0)
                {
                    self.debugLog(
                        "converter produced no PCM chunk sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
                    )
                }
                return
            }

            converterState.consecutiveFailureCount = 0
            processingQueue.async {
                self.lastCapturedAudioAt.withLock { $0 = Date() }
                self.hasCapturedAudioInCurrentRunFlag.withLock { $0 = true }
                if self.debugLoggingEnabled {
                    let shouldLog = hasLoggedFirstChunk.withLock { hasLogged in
                        if hasLogged { return false }
                        hasLogged = true
                        return true
                    }
                    if shouldLog {
                        self.debugLog("received first microphone chunk bytes=\(chunk.count)")
                    }
                }
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
            self?.debugLog("AVAudioEngineConfigurationChange observed")
            self?.onConfigurationChange?()
        }
    }

    func stop(restoreDefaultInput: Bool = true) {
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
        if restoreDefaultInput {
            restoreDefaultInputDeviceIfNeeded()
        }
        lastCapturedAudioAt.withLock { $0 = nil }
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }
        debugLog("stop")
    }

    private func configureInputDevice(_ preferredDeviceID: String?) throws {
        if let preferredDeviceID,
           !preferredDeviceID.isEmpty
        {
            guard let preferredObjectID = audioDeviceID(forUID: preferredDeviceID) else {
                throw MicrophoneCaptureError.preferredDeviceUnavailable(preferredDeviceID)
            }

            guard let currentDefaultInputID = defaultInputDeviceObjectID() else {
                throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
            }

            if preferredObjectID == currentDefaultInputID {
                debugLog("preferred input matches current default uid=\(preferredDeviceID)")
                return
            }

            let preferredName = deviceName(for: preferredObjectID) ?? preferredDeviceID
            debugLog(
                "attempting set preferred input uid=\(preferredDeviceID) name=\(preferredName) objectID=\(preferredObjectID) via default-input route"
            )
            previousDefaultInputDeviceObjectID = currentDefaultInputID
            guard setSystemDefaultInputDevice(preferredObjectID) else {
                previousDefaultInputDeviceObjectID = nil
                throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
            }

            guard waitForDefaultInputDevice(preferredObjectID) else {
                debugLog("default input did not settle to objectID=\(preferredObjectID)")
                previousDefaultInputDeviceObjectID = nil
                throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
            }

            // Give CoreAudio a short moment to settle after route switch.
            Thread.sleep(forTimeInterval: 0.06)
            debugLog("set preferred input succeeded uid=\(preferredDeviceID)")
            return
        }

        previousDefaultInputDeviceObjectID = nil
    }

    @discardableResult
    private func setSystemDefaultInputDevice(_ deviceID: AudioObjectID) -> Bool {
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

        guard status == noErr else {
            debugLog("setSystemDefaultInputDevice failed objectID=\(deviceID) status=\(status)")
            return false
        }

        return true
    }

    private func restoreDefaultInputDeviceIfNeeded() {
        guard let previousDefaultInputDeviceObjectID else { return }
        defer {
            self.previousDefaultInputDeviceObjectID = nil
        }

        guard defaultInputDeviceObjectID() != previousDefaultInputDeviceObjectID else { return }
        guard setSystemDefaultInputDevice(previousDefaultInputDeviceObjectID) else { return }
        debugLog("restored previous default input objectID=\(previousDefaultInputDeviceObjectID)")
    }

    private func waitForDefaultInputDevice(
        _ expectedDeviceID: AudioObjectID,
        timeout: TimeInterval = 0.8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if defaultInputDeviceObjectID() == expectedDeviceID {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        return defaultInputDeviceObjectID() == expectedDeviceID
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
            self?.debugLog("input devices changed")
            self?.onInputDevicesChanged?()
        }
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("[SuperVoxtral][Microphone] \(message)")
    }

    private static func inputFormatDescriptor(for format: AVAudioFormat) -> InputFormatDescriptor {
        InputFormatDescriptor(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            commonFormat: format.commonFormat,
            isInterleaved: format.isInterleaved
        )
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
