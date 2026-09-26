#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import XCTest
import localvoxtralCore

/// The speech stage the live evals share: `say` audio from the cache both
/// sets use, and one utterance through the production realtime client.
/// `AgentDictationE2EEvalTests` and `TermRecallEvalTests` call it, so the two
/// sets hear the same audio and assemble transcripts the same way. `say`
/// exists only on macOS; on Linux the audio comes from a recorded set.
package enum EvalSpeechStage {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String

        package init(_ description: String) {
            self.description = description
        }
    }

    package struct Endpoint: Equatable {
        package let url: URL
        package let apiKey: String
        package let model: String

        package init(url: URL, apiKey: String, model: String) {
            self.url = url
            self.apiKey = apiKey
            self.model = model
        }
    }

    // MARK: - TTS

    package static let englishVoicePreference = ["Samantha", "Alex"]
    package static let frenchVoicePreference = ["Thomas", "Amélie", "Aurélie", "Audrey"]

    #if os(macOS)
    package static let ttsDataFormat = "LEI16@16000"

    /// Cache key for a synthesized utterance: SHA-256 over the exact
    /// text + voice + data format, so any change to what `say` would produce
    /// changes the key and a rerun over an unchanged corpus is a pure cache
    /// hit (TTS is the slow step across ~150 cases x reruns). `voice == nil`
    /// (the system default voice) keys as "default". Each field is
    /// length-prefixed before hashing — a plain separator join is ambiguous
    /// (text "a|B" + voice nil collides with text "a" + voice "B|default";
    /// caught by the tier-0 collision test).
    package static func wavCacheKey(
        text: String,
        voice: String?,
        dataFormat: String = ttsDataFormat
    ) -> String {
        var hasher = SHA256()
        for field in [text, voice ?? "default", dataFormat] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: bytes)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// PCM16 for `text` spoken by `voice` (nil = the system voice), from
    /// `~/Library/Caches/localvoxtral-eval/wav` when a run already made it.
    package static func synthesizedPCM16(text: String, voice: String?) throws -> Data {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/localvoxtral-eval/wav", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        let key = wavCacheKey(text: text, voice: voice)
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
            "--data-format=\(ttsDataFormat)",
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
    package static func resolveVoice(languagePrefix: String, preferred: [String]) -> String? {
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
        return pickVoice(
            fromSayVoicesOutput: output, languagePrefix: languagePrefix, preferred: preferred
        )
    }
    #endif

    // MARK: - Voice picking

    /// Picks a TTS voice from `say -v ?` output: the first `preferred` name
    /// present wins, else the first voice whose locale starts with
    /// `languagePrefix` ("en"/"fr"), else nil. Voice names may contain spaces
    /// ("Bad News"), so lines parse as name + 2+ spaces + locale.
    package static func pickVoice(
        fromSayVoicesOutput output: String,
        languagePrefix: String,
        preferred: [String]
    ) -> String? {
        var candidates: [String] = []
        for line in output.split(separator: "\n") {
            guard let (name, locale) = parseVoiceLine(String(line)) else { continue }
            let normalizedLocale = locale.replacingOccurrences(of: "-", with: "_").lowercased()
            guard normalizedLocale.hasPrefix(languagePrefix.lowercased()) else { continue }
            candidates.append(name)
        }
        for name in preferred where candidates.contains(name) {
            return name
        }
        return candidates.first
    }

    private static func parseVoiceLine(_ line: String) -> (name: String, locale: String)? {
        // "Thomas              fr_FR    # Bonjour! ..." — name up to the first
        // run of 2+ spaces, locale is the next token.
        guard let separator = line.range(of: "  ") else { return nil }
        let name = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let locale = rest.split(whereSeparator: \.isWhitespace).first else { return nil }
        // Locale tokens look like en_US / fr-FR / fr_CA.
        guard locale.contains("_") || locale.contains("-") else { return nil }
        return (name, String(locale))
    }

    // MARK: - ASR

    /// One utterance through `client`: every chunk, a non-final then a final
    /// commit, and the non-empty finals joined. Mistral has no partial-commit
    /// concept and ignores the non-final commit, and its `.finalTranscript`
    /// carries the whole utterance in one event, which the join handles as
    /// the one-element case it already is.
    ///
    /// An empty transcript is a failure unless `allowsEmptyTranscript`: then
    /// the final commit's completion (`.transcriptionFinalized`) with no text
    /// returns "", a result the ASR-only eval scores. The end-to-end eval
    /// keeps the failure, since polish has nothing to work on.
    package static func transcribe(
        pcm: Data,
        client: any RealtimeClient,
        endpoint: Endpoint,
        timeout: TimeInterval,
        allowsEmptyTranscript: Bool = false
    ) async throws -> String {
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(pcm, chunkSizeBytes: 3_200)
        let finals = SpeechStageStrings()
        let socketErrors = SpeechStageStrings()
        let finalized = SpeechStageStrings()
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
            case .transcriptionFinalized where allowsEmptyTranscript:
                finalized.append("")
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
        if allowsEmptyTranscript, !finalized.snapshot().isEmpty {
            return ""
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
