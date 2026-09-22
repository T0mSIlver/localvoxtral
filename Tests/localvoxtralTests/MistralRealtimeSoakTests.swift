import Foundation
import XCTest
@testable import localvoxtral

/// Soak lane for the hosted Mistral realtime API: many real-time-paced
/// sessions of real speech through `MistralRealtimeWebSocketClient`, counting
/// sessions where the server went quiet while audio was still going out, or
/// never answered `input_audio.end` with `transcription.done`.
///
/// Enabled only by the gitignored marker `.mistral-soak-enable.json`
/// (`{"apiKey": "...", "sessions"?: 50, "concurrency"?: 4, "seconds"?: 60}`)
/// plus 16 kHz mono s16le speech at `local-notes/mistral-soak/soak.pcm`. It
/// paces audio on the wall clock on purpose — the point is to hold real
/// sockets open as long as a dictation does — and costs 0.006 USD per minute.
final class MistralRealtimeSoakTests: XCTestCase {
    private struct Marker: Decodable {
        let apiKey: String
        let sessions: Int?
        let concurrency: Int?
        let seconds: Int?
    }

    /// Server silence while streaming that counts as a stall. The longest gap
    /// between deltas in healthy read speech is ~1.3 s.
    private static let stallThreshold: Double = 8.0
    private static let doneTimeout: Double = 10.0
    private static let chunkBytes = 3_200  // 100 ms, the app's send cadence

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMistralSessionsNeverStall() async throws {
        let markerURL = repoRoot.appendingPathComponent(".mistral-soak-enable.json")
        let pcmURL = repoRoot.appendingPathComponent("local-notes/mistral-soak/soak.pcm")
        guard FileManager.default.fileExists(atPath: markerURL.path),
            FileManager.default.fileExists(atPath: pcmURL.path)
        else {
            throw XCTSkip("Mistral soak is disabled (needs .mistral-soak-enable.json and soak.pcm).")
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        let pcm = try Data(contentsOf: pcmURL)
        let sessions = marker.sessions ?? 50
        let concurrency = marker.concurrency ?? 4
        let seconds = marker.seconds ?? 60
        let windowBytes = seconds * 32_000
        let windows = max(1, (pcm.count / 32_000 - 40) / seconds)
        let configuration = RealtimeSessionConfiguration(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            apiKey: marker.apiKey,
            model: ""
        )

        var results: [SoakRecord] = []
        await withTaskGroup(of: SoakRecord.self) { group in
            var next = 0
            func launch() {
                let index = next
                next += 1
                let offset = (30 + (index % windows) * seconds) * 32_000
                let audio = pcm.subdata(in: offset..<min(pcm.count, offset + windowBytes))
                group.addTask {
                    await Self.runSession(
                        index: index, windowSeconds: offset / 32_000, audio: audio,
                        configuration: configuration)
                }
            }
            for _ in 0..<min(concurrency, sessions) { launch() }
            for await record in group {
                results.append(record)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if let data = try? encoder.encode(record),
                    let line = String(data: data, encoding: .utf8)
                {
                    print("SOAK \(line)")
                }
                if next < sessions { launch() }
            }
        }

        let failed = results.filter { $0.verdict != "ok" }
        print("SOAK summary sessions=\(results.count) failed=\(failed.count)")
        XCTAssertTrue(failed.isEmpty, "Sessions that stalled or never finished: \(failed)")
    }

    private static func runSession(
        index: Int, windowSeconds: Int, audio: Data, configuration: RealtimeSessionConfiguration
    ) async -> SoakRecord {
        let clock = ContinuousClock()
        let t0 = clock.now
        let elapsed: @Sendable () -> Double = {
            let d = clock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        let log = SoakEventLog()
        let client = MistralRealtimeWebSocketClient()
        client.setEventHandler { event, _ in
            let now = elapsed()
            switch event {
            case .status(let message) where message.localizedCaseInsensitiveContains("session ready"):
                log.mark("ready", at: now)
            case .partialTranscript:
                log.delta(at: now)
            case .finalTranscript(let text):
                log.mark("final", at: now, chars: text.count)
            case .transcriptionFinalized:
                log.mark("finalized", at: now)
            case .error(let message):
                log.error(message, at: now)
            case .disconnected:
                log.mark("disconnected", at: now)
            default:
                break
            }
        }

        var record = SoakRecord(i: index, windowSeconds: windowSeconds)
        do {
            try client.connect(configuration: configuration)
        } catch {
            record.verdict = "connect-threw"
            record.errors = [error.localizedDescription]
            return record
        }

        while log.time("ready") == nil, log.time("disconnected") == nil, elapsed() < 30 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let readyAt = log.time("ready") else {
            client.disconnect()
            record.verdict = "never-ready"
            record.errors = log.errors()
            return record
        }

        let sendStart = clock.now
        var chunkIndex = 0
        for position in stride(from: 0, to: audio.count, by: chunkBytes) {
            try? await clock.sleep(until: sendStart + .milliseconds(100 * chunkIndex))
            if log.time("disconnected") != nil { break }
            client.sendAudioChunk(
                audio.subdata(in: position..<min(audio.count, position + chunkBytes)))
            chunkIndex += 1
        }
        let streamEnd = elapsed()
        client.sendCommit(final: true)
        while log.time("finalized") == nil, log.time("disconnected") == nil,
            elapsed() < streamEnd + doneTimeout
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        client.disconnect()

        let deltas = log.deltaTimes()
        let marks = [readyAt] + deltas.filter { $0 < streamEnd }
        let gaps = zip(marks, marks.dropFirst() + [streamEnd]).map { $1 - $0 }
        let maxGap = gaps.max() ?? 0
        let lastDeltaBeforeEnd = deltas.last(where: { $0 < streamEnd })
        let finalizedAt = log.time("finalized")

        record.readyAt = readyAt
        record.streamEnd = streamEnd
        record.deltaCount = deltas.count
        record.maxGapStreaming = (maxGap * 100).rounded() / 100
        record.lastDeltaBeforeEnd = lastDeltaBeforeEnd
        record.doneLatency = finalizedAt.map { $0 - streamEnd }
        record.chars = log.finalChars()
        record.errors = log.errors()
        if let disconnectedAt = log.time("disconnected"), disconnectedAt < streamEnd {
            record.verdict = "dropped-mid-stream"
        } else if maxGap >= stallThreshold {
            record.verdict = "stalled"
        } else if finalizedAt == nil {
            record.verdict = "no-done"
        } else {
            record.verdict = "ok"
        }
        return record
    }
}

private struct SoakRecord: Codable, Sendable {
    let i: Int
    let windowSeconds: Int
    var verdict = "pending"
    var readyAt: Double?
    var streamEnd: Double?
    var deltaCount = 0
    var maxGapStreaming: Double?
    var lastDeltaBeforeEnd: Double?
    var doneLatency: Double?
    var chars = 0
    var errors: [String] = []
}

private final class SoakEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: Double] = [:]
    private var deltas: [Double] = []
    private var errorMessages: [String] = []
    private var chars = 0

    func mark(_ name: String, at time: Double, chars: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if marks[name] == nil { marks[name] = time }
        if let chars { self.chars = chars }
    }

    func delta(at time: Double) {
        lock.lock()
        deltas.append(time)
        lock.unlock()
    }

    func error(_ message: String, at time: Double) {
        lock.lock()
        errorMessages.append(String(format: "%.2f ", time) + message)
        lock.unlock()
    }

    func time(_ name: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return marks[name]
    }

    func deltaTimes() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return deltas
    }

    func errors() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorMessages
    }

    func finalChars() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return chars
    }
}
