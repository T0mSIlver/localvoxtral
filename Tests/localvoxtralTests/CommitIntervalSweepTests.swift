import Foundation
import XCTest
@testable import localvoxtral

/// Measurement harness, not a CI gate: streams synthetic spoken audio at
/// real-time pace with a periodic non-final commit loop that mirrors
/// `DictationViewModel.restartCommitTask`, once per candidate commit
/// interval, and reports latency + accuracy per interval so the default
/// `commitIntervalSeconds` can be chosen from data.
///
/// Enable with VLLM_REALTIME_TEST_COMMIT_SWEEP=1 (plus the usual
/// VLLM_REALTIME_TEST_* endpoint/model vars — the VLLM_REALTIME_TEST_ prefix
/// is what the Mac build-gate allowlists). Override the tested intervals with
/// VLLM_REALTIME_TEST_COMMIT_SWEEP_INTERVALS=0.1,0.3,0.9. Self-skips
/// everywhere else, including CI.
final class CommitIntervalSweepTests: XCTestCase {
    private static let sweepEnableEnv = "VLLM_REALTIME_TEST_COMMIT_SWEEP"
    private static let sweepIntervalsEnv = "VLLM_REALTIME_TEST_COMMIT_SWEEP_INTERVALS"
    private static let endpointEnv = "VLLM_REALTIME_TEST_ENDPOINT"
    private static let modelEnv = "VLLM_REALTIME_TEST_MODEL"
    private static let apiKeyEnv = "VLLM_REALTIME_TEST_API_KEY"

    fileprivate struct SweepResult {
        let interval: Double
        let firstPartialSeconds: Double?
        let firstFinalSeconds: Double?
        let partialCount: Int
        let finalCount: Int
        let medianTextGapSeconds: Double?
        let finalizeTailSeconds: Double?
        let errorCount: Int
        let wordAccuracy: Double
        let transcript: String
    }

    func testCommitIntervalSweep() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.sweepEnableEnv] == "1" else {
            throw XCTSkip("Commit-interval sweep disabled. Enable with \(Self.sweepEnableEnv)=1.")
        }

        let endpointString = env[Self.endpointEnv] ?? "ws://127.0.0.1:8000/v1/realtime"
        guard let endpoint = URL(string: endpointString) else {
            throw XCTSkip("Invalid \(Self.endpointEnv): \(endpointString)")
        }
        let configuration = RealtimeSessionConfiguration(
            endpoint: endpoint,
            apiKey: env[Self.apiKeyEnv] ?? "",
            model: env[Self.modelEnv] ?? "mistralai/Voxtral-Mini-4B-Realtime-2602"
        )

        let intervals: [Double] = env[Self.sweepIntervalsEnv]?
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            ?? [0.1, 0.2, 0.3, 0.5, 0.9]

        let phrase = [
            "hello from localvoxtral realtime test.",
            "this is a longer synthetic audio passage for integration testing.",
            "we are verifying that the vllm realtime server performs generation and returns transcript text.",
            "the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks.",
            "if this transcript is non empty, end to end processing is confirmed.",
        ].joined(separator: " ")
        let spokenPCM16 = try makeSpokenPCM16Data(phrase: phrase)
        // 3200 bytes = 100 ms of 16 kHz PCM16 — the pacing unit below.
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(spokenPCM16, chunkSizeBytes: 3_200)
        let audioSeconds = Double(chunks.count) * 0.1

        var results: [SweepResult] = []
        for interval in intervals {
            let result = try await runSweepPass(
                interval: interval,
                chunks: chunks,
                phrase: phrase,
                configuration: configuration
            )
            results.append(result)
            print(Self.formatRow(result))
            // Let the backend fully settle between passes.
            try await Task.sleep(for: .seconds(2))
        }

        print("")
        print("=== commit-interval sweep (\(String(format: "%.1f", audioSeconds))s audio, real-time pacing) ===")
        print("interval | 1st text | 1st final | texts (p/f) | median gap | finalize tail | errors | accuracy")
        for result in results {
            print(Self.formatRow(result))
        }
        for result in results {
            print("--- interval \(result.interval)s transcript: \(result.transcript)")
        }

        for result in results {
            XCTAssertGreaterThan(
                result.finalCount, 0,
                "interval \(result.interval)s produced no final transcript at all"
            )
        }
    }

    private func runSweepPass(
        interval: Double,
        chunks: [Data],
        phrase: String,
        configuration: RealtimeSessionConfiguration
    ) async throws -> SweepResult {
        let client = RealtimeAPIWebSocketClient()
        let recorder = SweepEventRecorder()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let finalized = expectation(description: "transcription finalized")
        finalized.assertForOverFulfill = false
        let disconnected = expectation(description: "disconnected")

        client.setEventHandler { event in
            switch event {
            case .connected:
                connected.fulfill()
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    sessionReady.fulfill()
                }
            case .partialTranscript(let text):
                recorder.record(.partial, text: text)
            case .finalTranscript(let text):
                recorder.record(.final, text: text)
            case .transcriptionFinalized:
                finalized.fulfill()
            case .error(let message):
                recorder.record(.error, text: message)
            case .disconnected:
                disconnected.fulfill()
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [connected, sessionReady], timeout: 20.0)

        recorder.markStreamStart()

        // Periodic non-final commits, mirroring restartCommitTask.
        let commitTask = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                client.sendCommit(final: false)
            }
        }

        // Stream at real-time pace: one 100 ms chunk every 100 ms.
        for chunk in chunks {
            client.sendAudioChunk(chunk)
            try await Task.sleep(for: .milliseconds(100))
        }

        commitTask.cancel()
        recorder.markFinalCommit()
        client.sendCommit(final: true)
        await fulfillment(of: [finalized], timeout: 30.0)
        // Catch stragglers after the finalized signal.
        try await Task.sleep(for: .seconds(1))

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)

        return recorder.result(interval: interval, phrase: phrase)
    }

    private static func formatRow(_ r: SweepResult) -> String {
        func fmt(_ value: Double?) -> String {
            value.map { String(format: "%6.2fs", $0) } ?? "     —"
        }
        return String(
            format: "  %.1fs  | %@ |  %@ |   %3d/%-3d  |    %@ |       %@ |    %2d  |  %.3f",
            r.interval,
            fmt(r.firstPartialSeconds),
            fmt(r.firstFinalSeconds),
            r.partialCount, r.finalCount,
            fmt(r.medianTextGapSeconds),
            fmt(r.finalizeTailSeconds),
            r.errorCount,
            r.wordAccuracy
        )
    }

    private func makeSpokenPCM16Data(phrase: String) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("svxt-sweep-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", tempURL.path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            phrase,
        ]
        do {
            try process.run()
        } catch {
            throw XCTSkip("Failed to execute /usr/bin/say for the sweep: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("System TTS (say) failed with status \(process.terminationStatus).")
        }
        return try IntegrationTestSupport.extractPCMDataFromWAV(at: tempURL)
    }
}

private final class SweepEventRecorder: @unchecked Sendable {
    enum Kind {
        case partial
        case final
        case error
    }

    private let lock = NSLock()
    private var streamStart: Date?
    private var finalCommitAt: Date?
    private var events: [(kind: Kind, at: Date, text: String)] = []

    func markStreamStart() {
        lock.lock()
        streamStart = Date()
        lock.unlock()
    }

    func markFinalCommit() {
        lock.lock()
        finalCommitAt = Date()
        lock.unlock()
    }

    func record(_ kind: Kind, text: String) {
        lock.lock()
        events.append((kind, Date(), text))
        lock.unlock()
    }

    func result(interval: Double, phrase: String) -> CommitIntervalSweepResultBuilder.Output {
        lock.lock()
        defer { lock.unlock() }
        return CommitIntervalSweepResultBuilder.build(
            interval: interval,
            phrase: phrase,
            streamStart: streamStart,
            finalCommitAt: finalCommitAt,
            events: events
        )
    }
}

private enum CommitIntervalSweepResultBuilder {
    typealias Output = CommitIntervalSweepTests.SweepResult

    static func build(
        interval: Double,
        phrase: String,
        streamStart: Date?,
        finalCommitAt: Date?,
        events: [(kind: SweepEventRecorder.Kind, at: Date, text: String)]
    ) -> Output {
        let start = streamStart ?? Date()
        let textEvents = events.filter { $0.kind != .error }
        let partials = events.filter { $0.kind == .partial }
        let finals = events.filter { $0.kind == .final }
        let errors = events.filter { $0.kind == .error }

        let textTimes = textEvents.map { $0.at.timeIntervalSince(start) }.sorted()
        let gaps = zip(textTimes.dropFirst(), textTimes).map(-)
        let medianGap: Double? = gaps.isEmpty ? nil : gaps.sorted()[gaps.count / 2]

        let finalizeTail: Double?
        if let finalCommitAt, let lastText = textEvents.map(\.at).max() {
            finalizeTail = max(0, lastText.timeIntervalSince(finalCommitAt))
        } else {
            finalizeTail = nil
        }

        let transcript = finals
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return .init(
            interval: interval,
            firstPartialSeconds: partials.first.map { $0.at.timeIntervalSince(start) },
            firstFinalSeconds: finals.first.map { $0.at.timeIntervalSince(start) },
            partialCount: partials.count,
            finalCount: finals.count,
            medianTextGapSeconds: medianGap,
            finalizeTailSeconds: finalizeTail,
            errorCount: errors.count,
            wordAccuracy: IntegrationTestSupport.wordAccuracy(expected: phrase, actual: transcript),
            transcript: transcript
        )
    }
}
