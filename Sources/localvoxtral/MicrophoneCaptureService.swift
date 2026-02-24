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
    case auHALComponentNotFound
    case auHALCreationFailed(OSStatus)
    case auHALConfigurationFailed(String, OSStatus)

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
        case .auHALComponentNotFound:
            return "Audio HAL output component not found."
        case .auHALCreationFailed(let status):
            return "Failed to create audio input unit (OSStatus \(status))."
        case .auHALConfigurationFailed(let step, let status):
            return "Failed to configure audio input unit at \(step) (OSStatus \(status))."
        }
    }
}

// MARK: - AUHAL Render Context

/// Holds state shared between the AUHAL input callback and the service.
/// Passed to the callback via `Unmanaged` pointer as `inRefCon`.
private final class RenderContext: @unchecked Sendable {
    weak var service: MicrophoneCaptureService?
    let auHAL: AudioUnit
    var deviceAVFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let chunkHandler: MicrophoneCaptureService.ChunkHandler
    let converterState: MicrophoneCaptureService.ConverterState
    let processingQueue: DispatchQueue
    let hasLoggedFirstChunk = Mutex(false)
    let debugLoggingEnabled: Bool

    init(
        service: MicrophoneCaptureService,
        auHAL: AudioUnit,
        deviceFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        chunkHandler: @escaping MicrophoneCaptureService.ChunkHandler,
        processingQueue: DispatchQueue,
        debugLoggingEnabled: Bool
    ) {
        self.service = service
        self.auHAL = auHAL
        self.deviceAVFormat = deviceFormat
        self.outputFormat = outputFormat
        self.chunkHandler = chunkHandler
        self.converterState = MicrophoneCaptureService.ConverterState()
        self.processingQueue = processingQueue
        self.debugLoggingEnabled = debugLoggingEnabled
    }

    func updateDeviceFormat(_ format: AVAudioFormat) {
        deviceAVFormat = format
        converterState.converter = nil
        converterState.inputFormatDescriptor = nil
    }
}

// MARK: - AUHAL Input Callback

/// CoreAudio IO-thread callback invoked when the AUHAL has input data available.
private func auhalInputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: context.deviceAVFormat,
        frameCapacity: inNumberFrames
    ) else {
        return noErr
    }

    // Set frameLength BEFORE render so the AudioBufferList reports the correct
    // mDataByteSize — otherwise it's 0 and AudioUnitRender returns -50.
    pcmBuffer.frameLength = inNumberFrames

    let renderStatus = AudioUnitRender(
        context.auHAL,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        pcmBuffer.mutableAudioBufferList
    )
    guard renderStatus == noErr else { return renderStatus }

    let inputFormat = pcmBuffer.format
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        return noErr
    }

    let converterState = context.converterState
    let inputFormatDescriptor = MicrophoneCaptureService.inputFormatDescriptor(for: inputFormat)

    if converterState.converter == nil || converterState.inputFormatDescriptor != inputFormatDescriptor {
        guard let converter = AVAudioConverter(from: inputFormat, to: context.outputFormat) else {
            if context.debugLoggingEnabled {
                context.service?.debugLog(
                    "converter creation failed sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
                )
            }
            if let errorCallback = context.service?.onError {
                errorCallback(
                    "Audio converter failed for microphone format (rate=\(Int(inputFormat.sampleRate)), ch=\(inputFormat.channelCount)). Try a different input device."
                )
            }
            return noErr
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converterState.converter = converter
        converterState.inputFormatDescriptor = inputFormatDescriptor
        converterState.consecutiveFailureCount = 0
        if context.debugLoggingEnabled {
            context.service?.debugLog(
                "converter configured sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved)"
            )
        }
    }

    guard let converter = converterState.converter,
          let chunk = MicrophoneCaptureService.convertToPCM16Mono(
              buffer: pcmBuffer, converter: converter, outputFormat: context.outputFormat)
    else {
        converterState.consecutiveFailureCount += 1
        if context.debugLoggingEnabled,
           (converterState.consecutiveFailureCount == 1
               || converterState.consecutiveFailureCount % 50 == 0)
        {
            context.service?.debugLog(
                "converter produced no PCM chunk sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
            )
        }
        return noErr
    }

    converterState.consecutiveFailureCount = 0
    context.processingQueue.async { [weak service = context.service] in
        service?.lastCapturedAudioAt.withLock { $0 = Date() }
        service?.hasCapturedAudioInCurrentRunFlag.withLock { $0 = true }
        if context.debugLoggingEnabled {
            let shouldLog = context.hasLoggedFirstChunk.withLock { hasLogged in
                if hasLogged { return false }
                hasLogged = true
                return true
            }
            if shouldLog {
                service?.debugLog("received first microphone chunk bytes=\(chunk.count)")
            }
        }
        context.chunkHandler(chunk)
    }

    return noErr
}

// MARK: - MicrophoneCaptureService

final class MicrophoneCaptureService: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    fileprivate struct InputFormatDescriptor: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let isInterleaved: Bool
    }

    fileprivate final class ConverterState {
        var inputFormatDescriptor: InputFormatDescriptor?
        var converter: AVAudioConverter?
        var consecutiveFailureCount = 0
    }

    /// Mutable state that must be accessed under `stateLock`.
    private struct ProtectedState {
        var auHAL: AudioUnit?
        var auHALRunning = false
        var activeDeviceID: AudioObjectID?
        var renderContext: Unmanaged<RenderContext>?
        var activeChunkHandler: ChunkHandler?
        var pendingFormatChangeWork: DispatchWorkItem?
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
    fileprivate let lastCapturedAudioAt = Mutex<Date?>(nil)
    fileprivate let hasCapturedAudioInCurrentRunFlag = Mutex(false)
    private static let targetSampleRate: Double = 16_000
    private let targetOutputFormat: AVAudioFormat
    fileprivate let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

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
        withState { $0.auHAL != nil && $0.auHALRunning }
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
        let (auHAL, alreadyRunning) = withState { ($0.auHAL, $0.auHALRunning) }
        guard let auHAL else { return false }
        guard !alreadyRunning else { return false }

        let status = AudioOutputUnitStart(auHAL)
        let resumed = status == noErr
        if resumed {
            withState { $0.auHALRunning = true }
        }
        debugLog("resumeIfNeeded resumed=\(resumed) status=\(status)")
        return resumed
    }

    @discardableResult
    func refreshInputTapIfNeeded() -> Bool {
        let (auHAL, unmanagedCtx) = withState { ($0.auHAL, $0.renderContext) }
        guard let auHAL, let unmanagedCtx else { return false }

        // Query the current device format to see if it actually changed.
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioUnitGetProperty(
            auHAL,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &asbd,
            &asbdSize
        )

        if formatStatus == noErr, asbd.mSampleRate > 0,
           let newFormat = AVAudioFormat(streamDescription: &asbd)
        {
            let ctx = unmanagedCtx.takeUnretainedValue()
            let currentDescriptor = Self.inputFormatDescriptor(for: ctx.deviceAVFormat)
            let newDescriptor = Self.inputFormatDescriptor(for: newFormat)

            guard currentDescriptor != newDescriptor else {
                debugLog("refreshInputTapIfNeeded: format unchanged, skipping reinit")
                return true
            }

            // Format actually changed — stop, reconfigure, and restart.
            AudioOutputUnitStop(auHAL)
            withState { $0.auHALRunning = false }
            AudioUnitUninitialize(auHAL)

            ctx.updateDeviceFormat(newFormat)

            // Mirror on output scope element 1 so the callback receives
            // raw device samples without internal AUHAL conversion.
            AudioUnitSetProperty(
                auHAL,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        } else {
            // Can't read format — do a full reinit to recover.
            AudioOutputUnitStop(auHAL)
            withState { $0.auHALRunning = false }
            AudioUnitUninitialize(auHAL)
        }

        guard AudioUnitInitialize(auHAL) == noErr else {
            debugLog("refreshInputTapIfNeeded: AudioUnitInitialize failed")
            return false
        }
        guard AudioOutputUnitStart(auHAL) == noErr else {
            debugLog("refreshInputTapIfNeeded: AudioOutputUnitStart failed")
            return false
        }

        withState { $0.auHALRunning = true }
        debugLog("refreshed AUHAL after format change")
        return true
    }

    func start(preferredDeviceID: String?, chunkHandler: @escaping ChunkHandler) throws {
        debugLog("start preferredDeviceID=\(preferredDeviceID ?? "default")")

        // Resolve the target input device without changing the system default.
        let deviceID = try resolveInputDevice(preferredDeviceID)

        // If the AUHAL is already running on the same device, skip
        // teardown + rebuild. This avoids a visible mic-indicator flicker
        // when the health monitor restarts capture on the same device
        // (common during BT SCO codec renegotiation delays).
        if isCapturing(), withState({ $0.activeDeviceID }) == deviceID {
            debugLog("start: already capturing on device \(deviceID), skipping restart")
            return
        }

        stop()
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }

        // Find the HALOutput audio component.
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw MicrophoneCaptureError.auHALComponentNotFound
        }

        // Create the AUHAL instance.
        var optionalAUHAL: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &optionalAUHAL)
        guard createStatus == noErr, let auHAL = optionalAUHAL else {
            throw MicrophoneCaptureError.auHALCreationFailed(createStatus)
        }

        // From here on, any failure must dispose the AUHAL before throwing.
        do {
            // Enable input on element 1, disable output on element 0.
            var enableInput: UInt32 = 1
            let enableInputStatus = AudioUnitSetProperty(
                auHAL,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard enableInputStatus == noErr else {
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "enable input", enableInputStatus)
            }

            var disableOutput: UInt32 = 0
            let disableOutputStatus = AudioUnitSetProperty(
                auHAL,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard disableOutputStatus == noErr else {
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "disable output", disableOutputStatus)
            }

            // Route to the target device (per-unit, no system default change).
            guard AudioDeviceManager.setInputDevice(deviceID, on: auHAL) else {
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "set device", OSStatus(kAudioUnitErr_InvalidProperty))
            }

            // Query the device's native input format.
            var deviceASBD = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let getFormatStatus = AudioUnitGetProperty(
                auHAL,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                1,
                &deviceASBD,
                &asbdSize
            )
            guard getFormatStatus == noErr, deviceASBD.mSampleRate > 0 else {
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "get device format", getFormatStatus)
            }

            guard let deviceFormat = AVAudioFormat(streamDescription: &deviceASBD) else {
                throw MicrophoneCaptureError.invalidInputFormat
            }

            // Mirror the device format on the output scope of element 1
            // so the callback receives raw device samples (no internal conversion).
            let setFormatStatus = AudioUnitSetProperty(
                auHAL,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &deviceASBD,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard setFormatStatus == noErr else {
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "set output format", setFormatStatus)
            }

            // Create render context and register the input callback.
            let renderCtx = RenderContext(
                service: self,
                auHAL: auHAL,
                deviceFormat: deviceFormat,
                outputFormat: targetOutputFormat,
                chunkHandler: chunkHandler,
                processingQueue: processingQueue,
                debugLoggingEnabled: debugLoggingEnabled
            )
            let unmanagedCtx = Unmanaged.passRetained(renderCtx)

            var callbackStruct = AURenderCallbackStruct(
                inputProc: auhalInputCallback,
                inputProcRefCon: unmanagedCtx.toOpaque()
            )
            let callbackStatus = AudioUnitSetProperty(
                auHAL,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callbackStruct,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard callbackStatus == noErr else {
                unmanagedCtx.release()
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "set input callback", callbackStatus)
            }

            // Initialize and start.
            let initStatus = AudioUnitInitialize(auHAL)
            guard initStatus == noErr else {
                unmanagedCtx.release()
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "initialize", initStatus)
            }

            let startStatus = AudioOutputUnitStart(auHAL)
            guard startStatus == noErr else {
                AudioUnitUninitialize(auHAL)
                unmanagedCtx.release()
                throw MicrophoneCaptureError.auHALConfigurationFailed(
                    "start", startStatus)
            }

            // Store state and install device property listeners.
            withState { s in
                s.auHAL = auHAL
                s.auHALRunning = true
                s.activeDeviceID = deviceID
                s.renderContext = unmanagedCtx
                s.activeChunkHandler = chunkHandler
            }

            installDevicePropertyListener(deviceID: deviceID)
            debugLog(
                "AUHAL started device=\(deviceID) sampleRate=\(deviceASBD.mSampleRate) channels=\(deviceASBD.mChannelsPerFrame)"
            )
        } catch {
            AudioComponentInstanceDispose(auHAL)
            throw error
        }
    }

    func stop() {
        let (auHAL, deviceID, unmanagedCtx, pendingWork) = withState { s in
            let hal = s.auHAL
            let dev = s.activeDeviceID
            let ctx = s.renderContext
            let work = s.pendingFormatChangeWork
            s.auHAL = nil
            s.auHALRunning = false
            s.activeDeviceID = nil
            s.renderContext = nil
            s.activeChunkHandler = nil
            s.pendingFormatChangeWork = nil
            return (hal, dev, ctx, work)
        }

        pendingWork?.cancel()

        if let deviceID {
            removeDevicePropertyListener(deviceID: deviceID)
        }

        if let auHAL {
            AudioOutputUnitStop(auHAL)
            AudioUnitUninitialize(auHAL)
            AudioComponentInstanceDispose(auHAL)
        }

        // Release the render context AFTER disposing the AUHAL, which
        // guarantees the callback will never fire again.
        unmanagedCtx?.release()

        lastCapturedAudioAt.withLock { $0 = nil }
        hasCapturedAudioInCurrentRunFlag.withLock { $0 = false }
        debugLog("stop")
    }

    // MARK: - Device Resolution

    private func resolveInputDevice(_ preferredDeviceID: String?) throws -> AudioObjectID {
        if let preferredDeviceID, !preferredDeviceID.isEmpty {
            guard let objectID = AudioDeviceManager.audioDeviceID(forUID: preferredDeviceID) else {
                throw MicrophoneCaptureError.preferredDeviceUnavailable(preferredDeviceID)
            }
            debugLog("resolved preferred device uid=\(preferredDeviceID) objectID=\(objectID)")
            return objectID
        }

        guard let defaultID = AudioDeviceManager.defaultInputDeviceObjectID() else {
            throw MicrophoneCaptureError.invalidInputFormat
        }
        debugLog("using system default input device objectID=\(defaultID)")
        return defaultID
    }

    // MARK: - Device Format Change Listener

    /// Debounce interval for device format change notifications. BT devices
    /// commonly fire rapid bursts of sample-rate / stream-configuration
    /// changes during SCO codec renegotiation. Coalescing into a single
    /// callback avoids a visible mic-indicator flicker from the stop/start
    /// cycle in `refreshInputTapIfNeeded`.
    private static let formatChangeDebounceSeconds: TimeInterval = 0.5

    private static let deviceFormatChangeListener: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        let service = Unmanaged<MicrophoneCaptureService>.fromOpaque(clientData).takeUnretainedValue()
        service.debounceFormatChange()
        return noErr
    }

    private func debounceFormatChange() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debugLog("device format change observed (debounced)")
            let callback = self.withState { s in
                s.pendingFormatChangeWork = nil
                return s.onConfigurationChange
            }
            callback?()
        }

        withState { s in
            s.pendingFormatChangeWork?.cancel()
            s.pendingFormatChangeWork = workItem
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.formatChangeDebounceSeconds,
            execute: workItem
        )
    }

    private func installDevicePropertyListener(deviceID: AudioObjectID) {
        let clientData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamConfigAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListener(
            deviceID, &sampleRateAddress, Self.deviceFormatChangeListener, clientData)
        AudioObjectAddPropertyListener(
            deviceID, &streamConfigAddress, Self.deviceFormatChangeListener, clientData)
    }

    private func removeDevicePropertyListener(deviceID: AudioObjectID) {
        let clientData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamConfigAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectRemovePropertyListener(
            deviceID, &sampleRateAddress, Self.deviceFormatChangeListener, clientData)
        _ = AudioObjectRemovePropertyListener(
            deviceID, &streamConfigAddress, Self.deviceFormatChangeListener, clientData)
    }

    // MARK: - Input Device List Monitoring

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

    fileprivate func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.microphone.debug("\(message)")
    }

    fileprivate static func inputFormatDescriptor(for format: AVAudioFormat) -> InputFormatDescriptor {
        InputFormatDescriptor(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            commonFormat: format.commonFormat,
            isInterleaved: format.isInterleaved
        )
    }

    fileprivate static func convertToPCM16Mono(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) -> Data? {
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
