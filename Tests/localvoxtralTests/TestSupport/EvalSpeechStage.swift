import Foundation
import XCTest

@testable import localvoxtral

/// The speech stage the live evals share: `say` audio from the cache both
/// sets use, and one utterance through the production realtime client.
/// `AgentDictationE2EEvalTests` and `TermRecallEvalTests` call it, so the two
/// sets hear the same audio and assemble transcripts the same way.
enum EvalSpeechStage {
    struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    struct Endpoint: Equatable {
        let url: URL
        let apiKey: String
        let model: String
    }

    // MARK: - TTS

    /// PCM16 for `text` spoken by `voice` (nil = the system voice), from
    /// `~/Library/Caches/localvoxtral-eval/wav` when a run already made it.
    static func synthesizedPCM16(text: String, voice: String?) throws -> Data {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/localvoxtral-eval/wav", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        let key = AgentDictationE2EEvalSupport.wavCacheKey(text: text, voice: voice)
        let wavURL = cacheDirectory.appendingPathComponent("\(key).wav")

        if FileManager.default.fileExists(atPath: wavURL.path) {
            // A corrupt cached file (crash mid-write on an old run) must not
            // poison the cache: fall through to re-synthesis.
            if let pcm = try? IntegrationTestSupport.extractPCMDataFromWAV(at: wavURL),
                !pcm.isEmpty
            {
                return pcm
            }
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Synthesize to a temp name, then move into place, so a crash
        // mid-`say` never leaves a half-written file under the final key.
        let temporary = cacheDirectory.appendingPathComponent("tmp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = [
            "-o", temporary.path,
            "--file-format=WAVE",
            "--data-format=\(AgentDictationE2EEvalSupport.ttsDataFormat)",
        ]
        if let voice {
            arguments += ["-v", voice]
        }
        arguments.append(text)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(
                "say failed (status \(process.terminationStatus)) for voice \(voice ?? "default")"
            )
        }
        try FileManager.default.moveItem(at: temporary, to: wavURL)
        return try IntegrationTestSupport.extractPCMDataFromWAV(at: wavURL)
    }

    /// `say -v ?` through a temp file (no pipes — descriptor-safe by
    /// construction), parsed by the unit-tested picker.
    static func resolveVoice(languagePrefix: String, preferred: [String]) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-eval-voices-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        try? handle.close()
        guard process.terminationStatus == 0,
            let output = try? String(contentsOf: outputURL, encoding: .utf8)
        else { return nil }
        return AgentDictationE2EEvalSupport.pickVoice(
            fromSayVoicesOutput: output, languagePrefix: languagePrefix, preferred: preferred
        )
    }

    static let englishVoicePreference = ["Samantha", "Alex"]
    static let frenchVoicePreference = ["Thomas", "Amélie", "Aurélie", "Audrey"]

    // MARK: - ASR

    /// One utterance through `client`: every chunk, a non-final then a final
    /// commit, and the non-empty finals joined. Mistral has no partial-commit
    /// concept and ignores the non-final commit, and its `.finalTranscript`
    /// carries the whole utterance in one event, which the join handles as
    /// the one-element case it already is.
    static func transcribe(
        pcm: Data,
        client: any RealtimeClient,
        endpoint: Endpoint,
        timeout: TimeInterval
    ) async throws -> String {
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(pcm, chunkSizeBytes: 3_200)
        let finals = SpeechStageStrings()
        let socketErrors = SpeechStageStrings()
        let firstFinal = XCTestExpectation(description: "final transcript")
        firstFinal.assertForOverFulfill = false

        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                // Safe to enqueue before session.created; the client gates
                // outbound sends until session readiness (tier-1 pattern).
                for chunk in chunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: false)
                client.sendCommit(final: true)
            case .finalTranscript(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                finals.append(trimmed)
                firstFinal.fulfill()
            case .error(let message):
                socketErrors.append(message)
                firstFinal.fulfill()  // fail fast, don't wait the full timeout
            default:
                break
            }
        }

        try client.connect(
            configuration: .init(
                endpoint: endpoint.url,
                apiKey: endpoint.apiKey,
                model: endpoint.model
            )
        )
        let outcome = await XCTWaiter.fulfillment(of: [firstFinal], timeout: timeout)
        // Short grace so trailing final segments of a longer utterance land.
        try? await Task.sleep(for: .seconds(1))
        client.disconnect()

        let transcript = finals.snapshot().joined(separator: " ")
        if !transcript.isEmpty {
            return transcript
        }
        let errors = socketErrors.snapshot()
        if !errors.isEmpty {
            throw Failure("realtime socket error: \(errors.joined(separator: " | "))")
        }
        if outcome != .completed {
            throw Failure("no final transcript within \(Int(timeout))s from \(endpoint.url)")
        }
        throw Failure("empty final transcript from \(endpoint.url)")
    }
}

private final class SpeechStageStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
