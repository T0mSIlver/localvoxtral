@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

final class MicrophoneCaptureService: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "supervoxtral.microphone.processing")
    private let targetSampleRate: Double = 16_000
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?
    var onConfigurationChange: (@Sendable () -> Void)?

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
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

    func start(preferredDeviceID: String?, chunkHandler: @escaping ChunkHandler) throws {
        stop()
        configureInputDevice(preferredDeviceID)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sourceSampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let chunk = self.convertToPCM16Mono(buffer: buffer, sourceSampleRate: sourceSampleRate) else {
                return
            }

            self.processingQueue.async {
                chunkHandler(chunk)
            }
        }

        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

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

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.reset()
        }
    }

    private func configureInputDevice(_ preferredDeviceID: String?) {
        if let preferredDeviceID,
           !preferredDeviceID.isEmpty,
           preferredDeviceID != defaultInputDeviceID(),
           let preferredObjectID = audioDeviceID(forUID: preferredDeviceID)
        {
            _ = setInputDevice(preferredObjectID)
        }
    }

    @discardableResult
    private func setInputDevice(_ deviceID: AudioObjectID) -> Bool {
        do {
            try audioEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
            return true
        } catch {
            return false
        }
    }

    private func allInputDevices() -> [MicrophoneInputDevice] {
        allAudioDeviceIDs().compactMap { deviceID in
            guard deviceHasInput(deviceID) else { return nil }
            guard let uid = deviceUID(for: deviceID) else { return nil }
            let name = deviceName(for: deviceID) ?? "Input \(uid)"
            return MicrophoneInputDevice(id: uid, name: name)
        }
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

        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

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

    private func convertToPCM16Mono(buffer: AVAudioPCMBuffer, sourceSampleRate: Double) -> Data? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let monoSamples = extractMonoSamples(from: buffer, frameCount: frameCount)
        guard !monoSamples.isEmpty else { return nil }

        let outputSamples = resample(
            samples: monoSamples,
            sourceRate: sourceSampleRate,
            targetRate: targetSampleRate
        )
        guard !outputSamples.isEmpty else { return nil }

        var pcm16 = [Int16]()
        pcm16.reserveCapacity(outputSamples.count)

        for sample in outputSamples {
            let clamped = max(-1.0, min(1.0, sample))
            pcm16.append(Int16(clamped * Float(Int16.max)))
        }

        return pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer, frameCount: Int) -> [Float] {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: frameCount)

        if let floatChannels = buffer.floatChannelData {
            for frame in 0 ..< frameCount {
                var summed: Float = 0
                for channel in 0 ..< channelCount {
                    summed += floatChannels[channel][frame]
                }
                output[frame] = summed / Float(channelCount)
            }
            return output
        }

        if let int16Channels = buffer.int16ChannelData {
            let scale = 1.0 / Float(Int16.max)
            for frame in 0 ..< frameCount {
                var summed: Float = 0
                for channel in 0 ..< channelCount {
                    summed += Float(int16Channels[channel][frame]) * scale
                }
                output[frame] = summed / Float(channelCount)
            }
            return output
        }

        if let int32Channels = buffer.int32ChannelData {
            let scale = 1.0 / Float(Int32.max)
            for frame in 0 ..< frameCount {
                var summed: Float = 0
                for channel in 0 ..< channelCount {
                    summed += Float(int32Channels[channel][frame]) * scale
                }
                output[frame] = summed / Float(channelCount)
            }
            return output
        }

        return []
    }

    private func resample(samples: [Float], sourceRate: Double, targetRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate > 0, targetRate > 0 else { return samples }

        if abs(sourceRate - targetRate) < 0.001 {
            return samples
        }

        let ratio = targetRate / sourceRate
        let outputCount = max(1, Int(Double(samples.count) * ratio))

        var output = [Float](repeating: 0, count: outputCount)
        let maxInputIndex = samples.count - 1

        for index in 0 ..< outputCount {
            let sourcePosition = Double(index) / ratio
            let lowerIndex = min(maxInputIndex, Int(sourcePosition))
            let upperIndex = min(maxInputIndex, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))

            let lowerSample = samples[lowerIndex]
            let upperSample = samples[upperIndex]
            output[index] = lowerSample + (upperSample - lowerSample) * fraction
        }

        return output
    }
}
