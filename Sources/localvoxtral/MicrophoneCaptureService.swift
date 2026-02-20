@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import os

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

    /// Mutable state that must be accessed under `stateLock`.
    private struct ProtectedState {
        var audioEngine: AVAudioEngine?
        var tapInstalled = false
        var activeChunkHandler: ChunkHandler?
        var configChangeObserver: NSObjectProtocol?
        var didInstallInputDeviceListeners = false
        var onConfigurationChange: (@Sendable () -> Void)?
        var onInputDevicesChanged: (@Sendable () -> Void)?
        var onError: (@Sendable (String) -> Void)?
    }

    private let stateLock = NSLock()
    private var _state = ProtectedState()

    /// Access protected state under the lock. All reads/writes of mutable
    /// instance properties must go through this accessor.
    private func withState<R>(_ body: (inout ProtectedState) -> R) -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&_state)
    }

    private let processingQueue = DispatchQueue(label: "localvoxtral.microphone.processing")
    private let lastCapturedAudioAt = Mutex<Date?>(nil)
    private let hasCapturedAudioInCurrentRunFlag = Mutex(false)
    private static let targetSampleRate: Double = 16_000
    private let targetOutputFormat: AVAudioFormat
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    var onConfigurationChange: (@Sendable () -> Void)? {
        get { withState { $0.onConfigurationChange } }
        set { withState { $0.onConfigurationChange = newValue } }
    }

    var onInputDevicesChanged: (@Sendable () -> Void)? {
        get { withState { $0.onInputDevicesChanged } }
        set { withState { $0.onInputDevicesChanged = newValue } }
    }

    /// Called when the audio pipeline encounters a non-recoverable error
    /// (e.g. converter creation failure). The message is suitable for display.
    var onError: (@Sendable (String) -> Void)? {
        get { withState { $0.onError } }
        set { withState { $0.onError = newValue } }
    }

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
        AudioDeviceManager.allInputDevices()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInputDeviceID() -> String? {
        AudioDeviceManager.defaultInputDeviceID()
    }

    func isCapturing() -> Bool {
        withState { s in
            guard let audioEngine = s.audioEngine else { return false }
            return audioEngine.isRunning && s.tapInstalled
        }
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
        let (engine, isTapInstalled) = withState { s in (s.audioEngine, s.tapInstalled) }
        guard let engine else { return false }
        guard !engine.isRunning else { return false }

        do {
            try engine.start()
            let resumed = engine.isRunning && isTapInstalled
            debugLog("resumeIfNeeded resumed=\(resumed)")
            return resumed
        } catch {
            debugLog("resumeIfNeeded failed error=\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func refreshInputTapIfNeeded() -> Bool {
        let (engine, handler, isTapInstalled) = withState { s in
            (s.audioEngine, s.activeChunkHandler, s.tapInstalled)
        }
        guard let engine, let handler else { return false }

        let inputNode = engine.inputNode
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
        }
        installInputTap(on: inputNode, chunkHandler: handler)
        withState { s in s.tapInstalled = true }
        debugLog("refreshed input tap")
        return true
    }

    func start(preferredDeviceID: String?, chunkHandler: @escaping ChunkHandler) throws {
        stop()
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }
        debugLog("start preferredDeviceID=\(preferredDeviceID ?? "default")")

        // Set the system default input device BEFORE creating the engine so the
        // engine picks up the correct device. We intentionally do NOT restore
        // the previous default on stop — restoring activates the old device
        // (e.g. a headset mic) even though our app is done recording.
        try configureInputDevice(preferredDeviceID)

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        installInputTap(on: inputNode, chunkHandler: chunkHandler)

        withState { s in
            s.audioEngine = audioEngine
            s.activeChunkHandler = chunkHandler
            s.tapInstalled = true
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            throw error
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.debugLog("AVAudioEngineConfigurationChange observed")
            let callback = self.withState { $0.onConfigurationChange }
            callback?()
        }
        withState { $0.configChangeObserver = observer }
    }

    func stop() {
        let (observer, engine, isTapInstalled) = withState { s in
            let obs = s.configChangeObserver
            s.configChangeObserver = nil
            let eng = s.audioEngine
            let tap = s.tapInstalled
            s.audioEngine = nil
            s.tapInstalled = false
            s.activeChunkHandler = nil
            return (obs, eng, tap)
        }

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        if let engine {
            // Order matters: remove tap first to release the closure, then stop
            // the engine to release audio hardware, then reset the graph.
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }

        lastCapturedAudioAt.withLock { $0 = nil }
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }
        debugLog("stop")
    }

    private func installInputTap(
        on inputNode: AVAudioInputNode,
        chunkHandler: @escaping ChunkHandler
    ) {
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
                    self.debugLog(
                        "converter creation failed sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
                    )
                    let errorCallback = self.withState { $0.onError }
                    errorCallback?(
                        "Audio converter failed for microphone format (rate=\(Int(inputFormat.sampleRate)), ch=\(inputFormat.channelCount)). Try a different input device."
                    )
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
    }

    private func configureInputDevice(_ preferredDeviceID: String?) throws {
        guard let preferredDeviceID, !preferredDeviceID.isEmpty else {
            debugLog("using system default input device")
            return
        }

        guard let preferredObjectID = AudioDeviceManager.audioDeviceID(forUID: preferredDeviceID) else {
            throw MicrophoneCaptureError.preferredDeviceUnavailable(preferredDeviceID)
        }

        // Skip if already the system default.
        if AudioDeviceManager.defaultInputDeviceObjectID() == preferredObjectID {
            debugLog("preferred device already system default; no change needed")
            return
        }

        let preferredName = AudioDeviceManager.deviceName(for: preferredObjectID) ?? preferredDeviceID
        debugLog("setting system default input uid=\(preferredDeviceID) name=\(preferredName)")

        guard AudioDeviceManager.setSystemDefaultInputDevice(preferredObjectID) else {
            throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
        }

        // The system default change is asynchronous; wait for it to take effect
        // before creating the AVAudioEngine.
        guard waitForDefaultInputDevice(preferredObjectID) else {
            let currentDefault = AudioDeviceManager.defaultInputDeviceObjectID()
            let currentDefaultName = currentDefault.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "unknown"
            debugLog(
                "system default input did not settle expected=\(preferredObjectID) actual=\(currentDefault.map { String($0) } ?? "nil") name=\(currentDefaultName)"
            )
            throw MicrophoneCaptureError.failedToSetPreferredDevice(preferredDeviceID)
        }
        debugLog("system default input device updated")
    }

    private func waitForDefaultInputDevice(
        _ expectedDeviceID: AudioObjectID,
        timeout: TimeInterval = 0.8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AudioDeviceManager.defaultInputDeviceObjectID() == expectedDeviceID {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static let inputDevicePropertyListener: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        let service = Unmanaged<MicrophoneCaptureService>.fromOpaque(clientData).takeUnretainedValue()
        service.notifyInputDevicesChanged()
        return noErr
    }

    private func startMonitoringInputDevices() {
        let alreadyInstalled = withState { $0.didInstallInputDeviceListeners }
        guard !alreadyInstalled else { return }

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
            withState { $0.didInstallInputDeviceListeners = true }
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
        let wasInstalled = withState { s in
            let was = s.didInstallInputDeviceListeners
            s.didInstallInputDeviceListeners = false
            return was
        }
        guard wasInstalled else { return }

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
    }

    private func notifyInputDevicesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debugLog("input devices changed")
            let callback = self.withState { $0.onInputDevicesChanged }
            callback?()
        }
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.microphone.debug("\(message)")
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
