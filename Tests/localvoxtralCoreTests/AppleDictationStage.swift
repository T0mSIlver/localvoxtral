#if canImport(Speech) && os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech
import localvoxtralTestSupport

/// Apple's on-device `DictationTranscriber` as a term-recall speech engine
/// (LVX-36): no download beyond the system's speech assets, and up to 100
/// contextual strings, the only local engine that takes terms without an
/// engine change.
///
/// Its live text is volatile and gets replaced, so an append-only insertion
/// path could take only finalized results. The stage therefore asks for
/// finals alone and times each one: how long after its audio ended did it
/// arrive. With `.realtime` pacing the audio is fed in 80 ms buffers at the
/// app's cadence, so those times are what a user would wait.
///
/// It runs in process and needs no TCC grant: the audio comes from a buffer,
/// not the microphone. The locale's assets must already be installed unless
/// the caller allows a download (`--allow-asset-download`), since the home
/// line is slow and the run should say so instead of stalling.
@available(macOS 26.0, *)
enum AppleDictationStage {
    static let asrName = "apple"
    static let sampleRate: Double = 16_000
    static let bufferMilliseconds = 80

    enum Pace: String, Decodable {
        /// 80 ms buffers at real time: final lags mean what a user waits.
        case realtime
        /// As fast as the analyzer takes them: text only, lags meaningless.
        case fast
    }

    enum Finalization: String, Decodable {
        /// `.frequentFinalization`: finals at short pauses, what a
        /// finals-only insertion path would ask for.
        case frequent
        /// The default: finals at the analyzer's own phrase ends.
        case standard
    }

    struct Final: Sendable {
        /// Audio time where the final's range ends, from the first sample.
        var audioEndSeconds: Double
        /// When it arrived, on the same timeline (feed start = 0).
        var receivedSeconds: Double
        var lagSeconds: Double { receivedSeconds - audioEndSeconds }
    }

    struct Transcript: Sendable {
        var text: String
        var finals: [Final]
        /// Audio length, so the caller can time the stop tail.
        var audioSeconds: Double
        /// From the last sample fed to the last final.
        var stopTailSeconds: Double?
    }

    /// The installed locale equivalent to `identifier` ("en-US", "fr-FR").
    /// Throws when it is unsupported, or not installed and `allowDownload`
    /// is false.
    static func prepareLocale(_ identifier: String, allowDownload: Bool) async throws -> Locale {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else {
            throw EvalSpeechStage.Failure("DictationTranscriber does not support \(identifier) on this Mac")
        }
        let probe = DictationTranscriber(locale: locale, preset: .shortDictation)
        let status = await AssetInventory.status(forModules: [probe])
        switch status {
        case .installed:
            return locale
        case .supported, .downloading:
            guard allowDownload else {
                throw EvalSpeechStage.Failure(
                    "speech assets for \(locale.identifier) are \(status), not installed; "
                        + "rerun with --allow-asset-download (a download from Apple)"
                )
            }
            print("apple: downloading speech assets for \(locale.identifier)")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
            return locale
        case .unsupported:
            throw EvalSpeechStage.Failure("speech assets for \(locale.identifier) are unsupported")
        @unknown default:
            throw EvalSpeechStage.Failure("speech assets for \(locale.identifier): unknown status \(status)")
        }
    }

    /// Transcribes 16 kHz mono PCM16 with `terms` as the general contextual
    /// strings (empty = none), keeping finalized results only.
    static func transcribe(
        pcm16: Data,
        locale: Locale,
        terms: [String],
        pace: Pace,
        finalization: Finalization
    ) async throws -> Transcript {
        var reporting: Set<DictationTranscriber.ReportingOption> = []
        if finalization == .frequent {
            reporting.insert(.frequentFinalization)
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: reporting,
            attributeOptions: [.audioTimeRange]
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EvalSpeechStage.Failure("DictationTranscriber offered no audio format")
        }
        let chunks = try analyzerBuffers(pcm16: pcm16, format: format)
        let audioSeconds = Double(pcm16.count / 2) / sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !terms.isEmpty {
            let context = AnalysisContext()
            // The API's cap; the case lists are already at most 100.
            context.contextualStrings[.general] = Array(terms.prefix(100))
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let clock = ContinuousClock()
        let start = clock.now
        let elapsed: @Sendable () -> Double = {
            let duration = start.duration(to: clock.now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        let collector = Task { () throws -> (String, [Final]) in
            var text = ""
            var finals: [Final] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                finals.append(Final(audioEndSeconds: result.range.end.seconds, receivedSeconds: elapsed()))
            }
            return (text, finals)
        }

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        let step = Duration.milliseconds(bufferMilliseconds)
        for (index, chunk) in chunks.enumerated() {
            if pace == .realtime {
                // The buffer is fed once its audio has "happened".
                try await clock.sleep(until: start.advanced(by: step * (index + 1)))
            }
            continuation.yield(chunk)
        }
        continuation.finish()
        let fedAt = elapsed()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, finals) = try await collector.value
        let stopTail = finals.last.map { $0.receivedSeconds - max(fedAt, audioSeconds) }
        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            finals: finals,
            audioSeconds: audioSeconds,
            stopTailSeconds: pace == .realtime ? stopTail : nil
        )
    }

    /// The PCM16 cut into 80 ms analyzer inputs in `format`, converted once.
    private static func analyzerBuffers(pcm16: Data, format: AVAudioFormat) throws -> [AnalyzerInput] {
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard frames > 0,
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
            ),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else {
            throw EvalSpeechStage.Failure("empty or unreadable audio")
        }
        source.frameLength = frames
        pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let destination = source.int16ChannelData?[0] else { return }
            memcpy(destination, base, Int(frames) * 2)
        }

        let converted: AVAudioPCMBuffer
        if format == sourceFormat {
            converted = source
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw EvalSpeechStage.Failure("no converter from 16 kHz PCM16 to \(format)")
            }
            let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / sampleRate) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw EvalSpeechStage.Failure("could not allocate a \(format) buffer")
            }
            nonisolated(unsafe) var handedOver = false
            nonisolated(unsafe) let input = source
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if handedOver {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                handedOver = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw EvalSpeechStage.Failure("audio conversion failed: \(conversionError?.localizedDescription ?? "?")")
            }
            converted = output
        }

        let framesPerChunk = AVAudioFrameCount(format.sampleRate * Double(bufferMilliseconds) / 1000)
        var inputs: [AnalyzerInput] = []
        var offset: AVAudioFrameCount = 0
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        while offset < converted.frameLength {
            let count = min(framesPerChunk, converted.frameLength - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw EvalSpeechStage.Failure("could not allocate an 80 ms buffer")
            }
            chunk.frameLength = count
            let sourceList = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
            let chunkList = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for (from, to) in zip(sourceList, chunkList) {
                guard let fromData = from.mData, let toData = to.mData else { continue }
                memcpy(toData, fromData.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
            }
            inputs.append(AnalyzerInput(buffer: chunk))
            offset += count
        }
        return inputs
    }

    /// One line per run: final lags and stop tails, in milliseconds.
    static func lagSummary(_ transcripts: [Transcript]) -> String {
        let lags = transcripts.flatMap { $0.finals.map(\.lagSeconds) }.sorted()
        let tails = transcripts.compactMap(\.stopTailSeconds).sorted()
        func ms(_ values: [Double], _ quantile: Double) -> String {
            guard !values.isEmpty else { return "-" }
            let index = min(values.count - 1, Int((Double(values.count - 1) * quantile).rounded()))
            return String(Int((values[index] * 1000).rounded()))
        }
        return "apple: \(lags.count) final(s) over \(transcripts.count) case(s); "
            + "final lag ms p50 \(ms(lags, 0.5)) p90 \(ms(lags, 0.9)) max \(ms(lags, 1)); "
            + "stop tail ms p50 \(ms(tails, 0.5)) p90 \(ms(tails, 0.9)) max \(ms(tails, 1))"
    }
}
#endif
