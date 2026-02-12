@preconcurrency import AVFoundation
import Foundation

final class MicrophoneCaptureService: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (Data) -> Void

    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "supervoxtral.microphone.processing")
    private let targetSampleRate: Double = 16_000
    private var tapInstalled = false

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

    func start(chunkHandler: @escaping ChunkHandler) throws {
        stop()

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
    }

    func stop() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
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
