import Foundation
import XCTest
@testable import localvoxtral

// MARK: - Stabilization Replay (mirrors DictationViewModel mlx logic without @MainActor)

/// Replays the mlx hypothesis stabilization pipeline outside of DictationViewModel,
/// using the same `TextMergingAlgorithms` functions. This lets us inspect every step
/// without needing a full @MainActor orchestrator.
private final class MlxStabilizationReplay {
    struct Step {
        let eventIndex: Int
        let elapsed: TimeInterval
        let isFinal: Bool
        let rawHypothesis: String
        let normalizedHypothesis: String
        let committedPrefixBefore: String
        let committedPrefixAfter: String
        let newlyCommittedDelta: String
        let committedEventText: String
        let livePartial: String
    }

    private(set) var committedPrefix = ""
    private(set) var previousHypothesis = ""
    private(set) var latestHypothesis = ""
    private(set) var committedEventText = ""
    private(set) var committedSinceLastFinal = ""
    private(set) var steps: [Step] = []

    func processPartial(_ rawText: String, eventIndex: Int, elapsed: TimeInterval) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !hypothesis.isEmpty else { return }
        let prefixBefore = committedPrefix
        let delta = commitHypothesis(hypothesis, isFinal: false)
        let livePartial: String
        if hypothesis.hasPrefix(committedPrefix) {
            let start = hypothesis.index(hypothesis.startIndex, offsetBy: committedPrefix.count)
            livePartial = String(hypothesis[start...])
        } else {
            livePartial = hypothesis
        }

        steps.append(Step(
            eventIndex: eventIndex,
            elapsed: elapsed,
            isFinal: false,
            rawHypothesis: rawText,
            normalizedHypothesis: hypothesis,
            committedPrefixBefore: prefixBefore,
            committedPrefixAfter: committedPrefix,
            newlyCommittedDelta: delta,
            committedEventText: committedEventText,
            livePartial: livePartial
        ))
    }

    func processFinal(_ rawText: String, eventIndex: Int, elapsed: TimeInterval) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !hypothesis.isEmpty else { return }
        let prefixBefore = committedPrefix
        let delta = commitHypothesis(hypothesis, isFinal: true)

        steps.append(Step(
            eventIndex: eventIndex,
            elapsed: elapsed,
            isFinal: true,
            rawHypothesis: rawText,
            normalizedHypothesis: hypothesis,
            committedPrefixBefore: prefixBefore,
            committedPrefixAfter: committedPrefix,
            newlyCommittedDelta: delta,
            committedEventText: committedEventText,
            livePartial: ""
        ))

        // Reset segment state (like handleMlxFinalTranscript)
        committedSinceLastFinal = ""
        latestHypothesis = ""
        previousHypothesis = ""
        committedPrefix = ""
    }

    // Mirrors DictationViewModel.commitMlxHypothesis
    private func commitHypothesis(_ hypothesis: String, isFinal: Bool) -> String {
        guard !hypothesis.isEmpty else { return "" }

        // Final mismatch path
        if isFinal,
           !committedPrefix.isEmpty,
           !hypothesis.hasPrefix(committedPrefix)
        {
            let safeDelta = resolvedFinalMismatchDelta(
                previousHypothesis: latestHypothesis,
                finalHypothesis: hypothesis
            )
            let appended = appendDeltaToEvent(safeDelta)
            committedPrefix = hypothesis
            latestHypothesis = hypothesis
            previousHypothesis = hypothesis
            return appended
        }

        let prevHyp = previousHypothesis
        var commitTarget = committedPrefix

        if isFinal {
            if hypothesis.hasPrefix(committedPrefix) {
                commitTarget = hypothesis
            }
        } else if !prevHyp.isEmpty {
            let stableLength = TextMergingAlgorithms.longestCommonPrefixLength(
                lhs: prevHyp,
                rhs: hypothesis
            )
            let boundaryLength = TextMergingAlgorithms.stableWordBoundaryLength(
                in: hypothesis,
                upTo: stableLength
            )
            if boundaryLength > committedPrefix.count {
                commitTarget = String(hypothesis.prefix(boundaryLength))
            }
        }

        var appendedDelta = ""
        if commitTarget.count > committedPrefix.count,
           commitTarget.hasPrefix(committedPrefix)
        {
            let start = commitTarget.index(
                commitTarget.startIndex,
                offsetBy: committedPrefix.count
            )
            let newlyStableDelta = String(commitTarget[start...])
            appendedDelta = appendDeltaToEvent(newlyStableDelta)
            committedPrefix = commitTarget
        }

        latestHypothesis = hypothesis
        previousHypothesis = hypothesis
        return appendedDelta
    }

    // Mirrors DictationViewModel.appendCommittedMlxDeltaToEvent
    private func appendDeltaToEvent(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        let merged = TextMergingAlgorithms.appendWithTailOverlap(
            existing: committedEventText,
            incoming: delta
        )
        committedEventText = merged.merged
        guard !merged.appendedDelta.isEmpty else { return "" }
        let finalBuf = TextMergingAlgorithms.appendWithTailOverlap(
            existing: committedSinceLastFinal,
            incoming: merged.appendedDelta
        )
        committedSinceLastFinal = finalBuf.merged
        return merged.appendedDelta
    }

    // Mirrors DictationViewModel.resolvedMlxFinalMismatchDelta
    private func resolvedFinalMismatchDelta(
        previousHypothesis: String,
        finalHypothesis: String
    ) -> String {
        let previous = previousHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { return finalHypothesis }

        if finalHypothesis.hasPrefix(previous) {
            let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: previous.count)
            return String(finalHypothesis[start...])
        }
        if previous.hasPrefix(finalHypothesis) || previous.contains(finalHypothesis) {
            return ""
        }
        if let range = finalHypothesis.range(of: previous) {
            return String(finalHypothesis[range.upperBound...])
        }
        let overlap = TextMergingAlgorithms.longestSuffixPrefixOverlap(
            lhs: previous,
            rhs: finalHypothesis
        )
        guard overlap > 0 else { return "" }
        let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: overlap)
        return String(finalHypothesis[start...])
    }
}

// MARK: - Test Class

final class MlxAudioTranscriptionTests: XCTestCase {
    private static let enableEnv = "MLX_AUDIO_REALTIME_TEST_ENABLE"
    private static let endpointEnv = "MLX_AUDIO_REALTIME_TEST_ENDPOINT"
    private static let modelEnv = "MLX_AUDIO_REALTIME_TEST_MODEL"
    private static let audioPathEnv = "MLX_AUDIO_TEST_AUDIO_PATH"
    private static let transcriptPathEnv = "MLX_AUDIO_TEST_TRANSCRIPT_PATH"
    private static let delayEnv = "MLX_AUDIO_REALTIME_TRANSCRIPTION_DELAY_MS"

    // MARK: - Configuration

    private func mlxConfiguration(delayMsOverride: Int? = nil) throws -> (
        config: RealtimeSessionConfiguration,
        audioPath: String,
        referenceTranscript: String?
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.enableEnv] == "1" else {
            throw XCTSkip(
                """
                mlx-audio transcription tests are disabled.
                Enable with \(Self.enableEnv)=1.
                Optional env vars:
                  \(Self.endpointEnv)=ws://127.0.0.1:8000/v1/audio/transcriptions/realtime
                  \(Self.modelEnv)=mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit
                  \(Self.audioPathEnv)=<path to .m4a or .wav file>
                  \(Self.transcriptPathEnv)=<path to reference transcript .txt>
                  \(Self.delayEnv)=900
                """
            )
        }

        let endpointString = env[Self.endpointEnv]
            ?? "ws://127.0.0.1:8000/v1/audio/transcriptions/realtime"
        guard let endpoint = URL(string: endpointString) else {
            throw XCTSkip("Invalid \(Self.endpointEnv): \(endpointString)")
        }

        let model = env[Self.modelEnv]
            ?? "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

        let delayMs: Int? = delayMsOverride ?? env[Self.delayEnv].flatMap { Int($0) }

        let config = RealtimeSessionConfiguration(
            endpoint: endpoint,
            apiKey: "",
            model: model,
            transcriptionDelayMilliseconds: delayMs
        )

        // Audio path: env var or default M4A in project root
        let audioPath: String
        if let envPath = env[Self.audioPathEnv], !envPath.isEmpty {
            audioPath = envPath
        } else {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let defaultM4A = projectRoot.appendingPathComponent("20260220 131619.m4a")
            guard FileManager.default.fileExists(atPath: defaultM4A.path) else {
                throw XCTSkip("No audio file found. Set \(Self.audioPathEnv) or place an M4A in the project root.")
            }
            audioPath = defaultM4A.path
        }

        // Reference transcript (optional)
        var referenceTranscript: String?
        if let envTranscript = env[Self.transcriptPathEnv], !envTranscript.isEmpty {
            referenceTranscript = try? String(contentsOfFile: envTranscript, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let defaultTranscript = projectRoot.appendingPathComponent("transcript.txt")
            referenceTranscript = try? String(contentsOf: defaultTranscript, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (config, audioPath, referenceTranscript)
    }

    // MARK: - Audio Conversion

    private func convertToPCM16(inputPath: String) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("svxt-pcm-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            inputPath,
            tempURL.path,
        ]

        do {
            try process.run()
        } catch {
            throw XCTSkip("Failed to run afconvert: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("afconvert failed with status \(process.terminationStatus).")
        }

        return try extractPCMDataFromWAV(at: tempURL)
    }

    private func extractPCMDataFromWAV(at url: URL) throws -> Data {
        let wavData = try Data(contentsOf: url)
        guard wavData.count >= 44 else {
            throw XCTSkip("Generated WAV audio is unexpectedly short.")
        }

        var index = 12
        while index + 8 <= wavData.count {
            let chunkIDData = wavData[index ..< index + 4]
            let chunkID = String(data: chunkIDData, encoding: .ascii) ?? ""
            let chunkSize = Int(readLEUInt32(in: wavData, at: index + 4))
            let chunkStart = index + 8
            let chunkEnd = chunkStart + chunkSize

            guard chunkEnd <= wavData.count else { break }

            if chunkID == "data" {
                return wavData.subdata(in: chunkStart ..< chunkEnd)
            }

            index = chunkEnd
            if index % 2 == 1 { index += 1 }
        }

        throw XCTSkip("WAV audio does not contain a valid data chunk.")
    }

    private func readLEUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func splitPCM16IntoChunks(_ pcm: Data, chunkSizeBytes: Int) -> [Data] {
        guard chunkSizeBytes > 0, !pcm.isEmpty else { return pcm.isEmpty ? [] : [pcm] }
        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, pcm.count / chunkSizeBytes))
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSizeBytes, pcm.count)
            chunks.append(pcm.subdata(in: offset ..< end))
            offset = end
        }
        return chunks
    }

    // MARK: - Diagnostic Runner

    struct DiagnosticConfig {
        var label: String
        var delayMs: Int?
        var trailingSilenceSeconds: Double = 2.0
        var finalWaitTimeoutSeconds: TimeInterval = 30.0
        var postFinalQuietSeconds: TimeInterval = 8.0
        var showStabilizationReplay: Bool = true
    }

    @discardableResult
    private func runDiagnostic(_ diag: DiagnosticConfig) async throws -> DiagnosticResult {
        let (config, audioPath, referenceTranscript) = try mlxConfiguration(delayMsOverride: diag.delayMs)

        let pcm16 = try convertToPCM16(inputPath: audioPath)
        let audioDurationSeconds = Double(pcm16.count) / (16_000.0 * 2.0)
        let chunkSizeBytes = 3_200
        let chunks = splitPCM16IntoChunks(pcm16, chunkSizeBytes: chunkSizeBytes)

        print("\n" + String(repeating: "=", count: 80))
        print("MLX-AUDIO DIAGNOSTIC: \(diag.label)")
        print(String(repeating: "=", count: 80))
        print("Audio: \(audioPath) (\(String(format: "%.1f", audioDurationSeconds))s)")
        print("Chunks: \(chunks.count) x \(chunkSizeBytes)B | Trailing silence: \(diag.trailingSilenceSeconds)s")
        print("Endpoint: \(config.endpoint.absoluteString)")
        if let delay = config.transcriptionDelayMilliseconds {
            print("Transcription delay: \(delay)ms")
        } else {
            print("Transcription delay: server default")
        }
        print("Post-final quiet wait: \(diag.postFinalQuietSeconds)s")
        if let ref = referenceTranscript {
            print("Reference: \(ref)")
        }
        print(String(repeating: "-", count: 80))

        let client = MlxAudioRealtimeWebSocketClient()
        let events = EventCollector()
        let connected = expectation(description: "connected")
        let disconnected = expectation(description: "disconnected")

        // Track finals with a counter instead of a single expectation
        let finalTracker = FinalTracker()

        client.setEventHandler { [events, finalTracker] event in
            events.append(event)
            switch event {
            case .connected:
                connected.fulfill()
            case .finalTranscript:
                finalTracker.receivedFinal()
            case .disconnected:
                disconnected.fulfill()
            default:
                break
            }
        }

        try client.connect(configuration: config)
        await fulfillment(of: [connected], timeout: 10.0)

        // Stream audio at real-time pace
        print("\nStreaming audio...")
        let streamStart = CFAbsoluteTimeGetCurrent()
        for (i, chunk) in chunks.enumerated() {
            client.sendAudioChunk(chunk)
            if i < chunks.count - 1 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Send trailing silence
        let silenceSamples = Int(diag.trailingSilenceSeconds * 16_000)
        let silenceBytes = silenceSamples * 2
        let silenceChunkSize = 3_200
        var silenceRemaining = silenceBytes
        while silenceRemaining > 0 {
            let sz = min(silenceChunkSize, silenceRemaining)
            client.sendAudioChunk(Data(count: sz))
            silenceRemaining -= sz
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let streamElapsed = CFAbsoluteTimeGetCurrent() - streamStart
        print("Streaming complete in \(String(format: "%.1f", streamElapsed))s")

        // Wait for finals: keep waiting until no new final arrives for postFinalQuietSeconds
        print("Waiting for all finals (quiet period: \(diag.postFinalQuietSeconds)s)...")
        let waitStart = CFAbsoluteTimeGetCurrent()
        let maxWait = diag.finalWaitTimeoutSeconds
        while CFAbsoluteTimeGetCurrent() - waitStart < maxWait {
            let lastFinalTime = finalTracker.lastFinalTime
            let now = CFAbsoluteTimeGetCurrent()
            if lastFinalTime > 0, (now - lastFinalTime) >= diag.postFinalQuietSeconds {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let waitElapsed = CFAbsoluteTimeGetCurrent() - waitStart
        print("Wait complete in \(String(format: "%.1f", waitElapsed))s (\(finalTracker.count) finals received)")

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)

        // Analyze events
        let capturedEvents = events.allEvents()

        print("\n" + String(repeating: "=", count: 80))
        print("RAW EVENTS (\(capturedEvents.count) total)")
        print(String(repeating: "=", count: 80))

        var partialCount = 0
        var finalCount = 0
        var allFinalTexts: [String] = []
        var lastPartialText = ""

        for (i, te) in capturedEvents.enumerated() {
            switch te.event {
            case .connected:
                print("[\(formatTime(te.elapsed))] #\(i) CONNECTED")
            case .disconnected:
                print("[\(formatTime(te.elapsed))] #\(i) DISCONNECTED")
            case .status(let msg):
                print("[\(formatTime(te.elapsed))] #\(i) STATUS: \(msg)")
            case .partialTranscript(let text):
                partialCount += 1
                lastPartialText = text
                print("[\(formatTime(te.elapsed))] #\(i) PARTIAL[\(partialCount)]: \(text)")
            case .finalTranscript(let text):
                finalCount += 1
                allFinalTexts.append(text)
                print("[\(formatTime(te.elapsed))] #\(i) FINAL[\(finalCount)]: \(text)")
            case .error(let msg):
                print("[\(formatTime(te.elapsed))] #\(i) ERROR: \(msg)")
            }
        }

        // Stabilization replay
        let replay = MlxStabilizationReplay()
        for (i, te) in capturedEvents.enumerated() {
            switch te.event {
            case .partialTranscript(let text):
                replay.processPartial(text, eventIndex: i, elapsed: te.elapsed)
            case .finalTranscript(let text):
                replay.processFinal(text, eventIndex: i, elapsed: te.elapsed)
            default:
                break
            }
        }

        if diag.showStabilizationReplay {
            print("\n" + String(repeating: "=", count: 80))
            print("STABILIZATION REPLAY")
            print(String(repeating: "=", count: 80))

            for step in replay.steps {
                let typeLabel = step.isFinal ? "FINAL" : "PARTIAL"
                print("[\(formatTime(step.elapsed))] #\(step.eventIndex) \(typeLabel)")
                print("  raw:        \(step.rawHypothesis)")
                if step.normalizedHypothesis != step.rawHypothesis {
                    print("  normalized: \(step.normalizedHypothesis)")
                }
                if !step.newlyCommittedDelta.isEmpty {
                    print("  +committed: \"\(step.newlyCommittedDelta)\"")
                }
                print("  prefix:     \"\(step.committedPrefixAfter)\"")
                if !step.livePartial.isEmpty {
                    print("  partial:    \"\(step.livePartial)\"")
                }
                print("  eventText:  \"\(step.committedEventText)\"")
                print()
            }
        }

        // Summary
        let concatenatedFinals = allFinalTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        print(String(repeating: "=", count: 80))
        print("SUMMARY")
        print(String(repeating: "=", count: 80))
        print("Partial events:     \(partialCount)")
        print("Final events:       \(finalCount)")
        print("Final segments:     \(allFinalTexts.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n                    "))")
        print()
        print("Concatenated finals: \(concatenatedFinals)")
        print("Stabilized output:   \(replay.committedEventText)")
        print("Last raw partial:    \(lastPartialText)")
        if let ref = referenceTranscript {
            print("Reference:           \(ref)")
            print()
            let normalizedStabilized = replay.committedEventText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedStabilized == normalizedRef {
                print("MATCH: Stabilized output exactly matches reference.")
            } else {
                print("DIFF: Stabilized output differs from reference.")
                printDiff(expected: normalizedRef, actual: normalizedStabilized)
            }

            let normalizedConcat = TextMergingAlgorithms.normalizeTranscriptionFormatting(
                concatenatedFinals.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            print()
            if normalizedConcat == normalizedRef {
                print("CONCAT FINALS MATCH: Concatenated finals match reference.")
            } else {
                print("CONCAT FINALS DIFF:")
                printDiff(expected: normalizedRef, actual: normalizedConcat)
            }
        }
        print(String(repeating: "=", count: 80))

        XCTAssertGreaterThan(partialCount, 0, "Expected at least one partial transcript")
        XCTAssertGreaterThan(finalCount, 0, "Expected at least one final transcript")
        XCTAssertFalse(replay.committedEventText.isEmpty, "Stabilization should produce non-empty output")

        return DiagnosticResult(
            partialCount: partialCount,
            finalCount: finalCount,
            allFinalTexts: allFinalTexts,
            concatenatedFinals: concatenatedFinals,
            stabilizedOutput: replay.committedEventText,
            lastPartialText: lastPartialText,
            referenceTranscript: referenceTranscript
        )
    }

    struct DiagnosticResult {
        let partialCount: Int
        let finalCount: Int
        let allFinalTexts: [String]
        let concatenatedFinals: String
        let stabilizedOutput: String
        let lastPartialText: String
        let referenceTranscript: String?
    }

    // MARK: - Tests

    /// Baseline test: real-time streaming with default settings, generous wait for all finals.
    func testMlxAudioReferenceTranscription() async throws {
        try await runDiagnostic(DiagnosticConfig(
            label: "Baseline (real-time streaming, default delay)",
            trailingSilenceSeconds: 4.0,
            finalWaitTimeoutSeconds: 60.0,
            postFinalQuietSeconds: 10.0
        ))
    }

    /// Low latency: transcription_delay_ms=0. Tests how much accuracy degrades
    /// when the model has no right-context lookahead.
    func testMlxAudioLowLatency() async throws {
        try await runDiagnostic(DiagnosticConfig(
            label: "Low latency (delay=0ms)",
            delayMs: 0,
            trailingSilenceSeconds: 4.0,
            finalWaitTimeoutSeconds: 60.0,
            postFinalQuietSeconds: 10.0,
            showStabilizationReplay: false
        ))
    }

    /// High accuracy: transcription_delay_ms=1500. Tests whether more right-context
    /// improves the final transcript quality.
    func testMlxAudioHighAccuracy() async throws {
        try await runDiagnostic(DiagnosticConfig(
            label: "High accuracy (delay=1500ms)",
            delayMs: 1500,
            trailingSilenceSeconds: 4.0,
            finalWaitTimeoutSeconds: 60.0,
            postFinalQuietSeconds: 10.0,
            showStabilizationReplay: false
        ))
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        String(format: "%6.2fs", seconds)
    }

    private func printDiff(expected: String, actual: String) {
        let expChars = Array(expected)
        let actChars = Array(actual)
        var firstDiff = 0
        while firstDiff < min(expChars.count, actChars.count),
              expChars[firstDiff] == actChars[firstDiff]
        {
            firstDiff += 1
        }

        let contextStart = max(0, firstDiff - 20)
        let contextEnd = min(max(expChars.count, actChars.count), firstDiff + 40)

        let expSlice = String(expChars[contextStart ..< min(contextEnd, expChars.count)])
        let actSlice = String(actChars[contextStart ..< min(contextEnd, actChars.count)])

        print("  First difference at character \(firstDiff):")
        print("  expected: ...\(expSlice)...")
        print("  actual:   ...\(actSlice)...")
        print("  expected length: \(expected.count)")
        print("  actual length:   \(actual.count)")
    }
}

// MARK: - Thread-safe event collector

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(elapsed: TimeInterval, event: RealtimeEvent)] = []
    private let startTime = CFAbsoluteTimeGetCurrent()

    func append(_ event: RealtimeEvent) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        lock.lock()
        events.append((elapsed, event))
        lock.unlock()
    }

    func allEvents() -> [(elapsed: TimeInterval, event: RealtimeEvent)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// MARK: - Thread-safe final transcript tracker

private final class FinalTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _lastFinalTime: CFAbsoluteTime = 0

    func receivedFinal() {
        lock.lock()
        _count += 1
        _lastFinalTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var lastFinalTime: CFAbsoluteTime {
        lock.lock()
        defer { lock.unlock() }
        return _lastFinalTime
    }
}
