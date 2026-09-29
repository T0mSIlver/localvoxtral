#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Synchronization
import localvoxtralCore

/// The speech stage the live evals share: `say` audio from the cache both
/// sets use, and one utterance through the production realtime client.
/// `AgentDictationE2EEvalTests` and `TermRecallEvalTests` call it, so the two
/// sets hear the same audio and assemble transcripts the same way. `say`
/// exists only on macOS; on Linux the audio comes from a recorded set.
package enum EvalSpeechStage {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String
        /// The service never answered: a socket error or no final transcript
        /// within the timeout. An empty transcript is an answer.
        package let serviceStalled: Bool

        package init(_ description: String, serviceStalled: Bool = false) {
            self.description = description
            self.serviceStalled = serviceStalled
        }
    }

    /// Ends a live eval once the STT service stops answering. Each utterance
    /// otherwise waits out its own timeout, and a corpus of ~150 at 90 s each
    /// held the Mac for two hours with no output (#821).
    package struct ServiceWatch {
        package let endpoint: URL
        package let limit: Int
        package private(set) var consecutiveStalls = 0

        package init(endpoint: URL, limit: Int = 3) {
            self.endpoint = endpoint
            self.limit = limit
        }

        package mutating func recordAnswer() {
            consecutiveStalls = 0
        }

        /// Throws once `limit` utterances in a row got no answer. Any other
        /// error (a failed `say`, an empty transcript) leaves the count.
        package mutating func record(_ error: any Error) throws {
            guard let failure = error as? Failure, failure.serviceStalled else { return }
            consecutiveStalls += 1
            if consecutiveStalls >= limit {
                throw Failure(
                    "STT service at \(endpoint) stopped answering: \(consecutiveStalls) utterances "
                        + "in a row got no transcript; last: \(failure.description)",
                    serviceStalled: true
                )
            }
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

    /// In order of preference. Scores compare only between runs with the
    /// same voices. Since macOS 27 the Mac's Actions runner lists neither
    /// Samantha nor Alex and gets Daniel (en_GB) (#960).
    package static let englishVoicePreference = ["Samantha", "Alex", "Daniel"]
    package static let frenchVoicePreference = ["Thomas", "Jacques", "Amélie"]

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

        let status = try EvalChildProcess.run("/usr/bin/say", arguments: arguments)
        guard status == 0 else {
            throw Failure(
                "say failed (status \(status)) for voice \(voice ?? "default")"
            )
        }
        try FileManager.default.moveItem(at: temporary, to: wavURL)
        return try IntegrationTestSupport.extractPCMDataFromWAV(at: wavURL)
    }

    /// What xctest hands its children, printed once to compare with eval-e2e's
    /// "Voices the runner's shell lists" step (#960).
    private static let reportEnvironmentOnce: Void = {
        for line in EvalChildProcess.currentEnvironmentReport() {
            print("eval TTS env: \(line)")
        }
    }()

    /// `say -v ?` through a temp file (no pipes — descriptor-safe by
    /// construction), parsed by the unit-tested picker. Throws when `say`
    /// fails or lists none of `preferred`.
    package static func resolveVoice(languagePrefix: String, preferred: [String]) throws -> String {
        _ = reportEnvironmentOnce
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-eval-voices-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let status = try EvalChildProcess.run(
            "/usr/bin/say", arguments: ["-v", "?"],
            standardOutput: outputURL.path, discardStandardError: true
        )
        guard status == 0 else {
            throw Failure("`say -v ?` failed (status \(status))")
        }
        let voice = try requireVoice(
            fromSayVoicesOutput: String(contentsOf: outputURL, encoding: .utf8),
            languagePrefix: languagePrefix, preferred: preferred
        )
        if let note = fallbackNote(chosen: voice, preferred: preferred) {
            print("eval TTS: \(note)")
        }
        return voice
    }
    #endif

    // MARK: - Voice picking

    /// Picks a TTS voice from `say -v ?` output: the first `preferred` name
    /// listed for a locale starting with `languagePrefix` ("en"/"fr"), else
    /// nil. It returns the name as listed, which `say -v` needs: macOS 27
    /// suffixes most names with their language, "Samantha (English (US))"
    /// (#960). Voice names may contain spaces ("Bad News"), so lines parse
    /// as name + 2+ spaces + locale.
    package static func pickVoice(
        fromSayVoicesOutput output: String,
        languagePrefix: String,
        preferred: [String]
    ) -> String? {
        let listed = voiceNames(fromSayVoicesOutput: output, languagePrefix: languagePrefix)
        for name in preferred {
            if let voice = listed.first(where: { isVoice($0, named: name) }) {
                return voice
            }
        }
        return nil
    }

    /// One line naming the preferred voices `say` did not list, when
    /// `chosen` is not the first preference; nil otherwise.
    package static func fallbackNote(chosen: String, preferred: [String]) -> String? {
        guard let index = preferred.firstIndex(where: { isVoice(chosen, named: $0) }), index > 0
        else { return nil }
        return "\(preferred[..<index].joined(separator: ", ")) not listed by `say -v ?`, using \(chosen)"
    }

    /// "Samantha" or, as macOS 27 lists it, "Samantha (English (US))".
    private static func isVoice(_ listed: String, named name: String) -> Bool {
        listed == name || listed.hasPrefix(name + " (")
    }

    /// `pickVoice`, failing with the voices on offer when it finds none. No
    /// fallback to another voice of the language: on macOS 27 that was the
    /// novelty voice Albert, which speechd could not transcribe (#960).
    package static func requireVoice(
        fromSayVoicesOutput output: String,
        languagePrefix: String,
        preferred: [String]
    ) throws -> String {
        if let voice = pickVoice(
            fromSayVoicesOutput: output, languagePrefix: languagePrefix, preferred: preferred
        ) {
            return voice
        }
        let offered = voiceNames(fromSayVoicesOutput: output, languagePrefix: languagePrefix)
        throw Failure(
            "no \(languagePrefix) TTS voice named \(preferred.joined(separator: " or ")); "
                + "`say -v ?` offered: \(offered.isEmpty ? "none" : offered.joined(separator: ", "))"
        )
    }

    private static func voiceNames(
        fromSayVoicesOutput output: String,
        languagePrefix: String
    ) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let (name, locale) = parseVoiceLine(String(line)) else { return nil }
            let normalizedLocale = locale.replacingOccurrences(of: "-", with: "_").lowercased()
            return normalizedLocale.hasPrefix(languagePrefix.lowercased()) ? name : nil
        }
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
    /// The final commit's completion (`.transcriptionFinalized`) with no text
    /// ends the utterance at once. It returns "" when `allowsEmptyTranscript`,
    /// a result the ASR-only eval scores. Otherwise it fails as an answer,
    /// not a stall (#961): the end-to-end eval keeps the failure, since
    /// polish has nothing to work on, but `ServiceWatch` does not count it.
    ///
    /// `clock` times the wait for an answer and the grace after it; tests
    /// pass a `ManualSessionClock`.
    package static func transcribe(
        pcm: Data,
        client: any RealtimeClient,
        endpoint: Endpoint,
        timeout: TimeInterval,
        allowsEmptyTranscript: Bool = false,
        clock: SessionClock = .live
    ) async throws -> String {
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(pcm, chunkSizeBytes: 3_200)
        let finals = SpeechStageStrings()
        let socketErrors = SpeechStageStrings()
        let finalized = SpeechStageStrings()
        let firstAnswer = SpeechStageWait()

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
                firstAnswer.finish(answered: true)
            case .transcriptionFinalized:
                // The final commit's `transcription.done`. With no text
                // before it, the service answered with nothing.
                finalized.append("")
                firstAnswer.finish(answered: true)
            case .error(let message):
                socketErrors.append(message)
                firstAnswer.finish(answered: true)  // fail fast, don't wait the full timeout
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
        let answered = await firstAnswer.value(timeout: timeout, clock: clock)
        if answered {
            // Short grace so trailing final segments of a longer utterance land.
            await clock.sleep(.seconds(1))
        }
        client.disconnect()

        let transcript = finals.snapshot().joined(separator: " ")
        if !transcript.isEmpty {
            return transcript
        }
        let errors = socketErrors.snapshot()
        if !errors.isEmpty {
            throw Failure(
                "realtime socket error: \(errors.joined(separator: " | "))", serviceStalled: true
            )
        }
        if allowsEmptyTranscript, !finalized.snapshot().isEmpty {
            return ""
        }
        if !answered {
            throw Failure(
                "no final transcript within \(Int(timeout))s from \(endpoint.url)", serviceStalled: true
            )
        }
        throw Failure("empty final transcript from \(endpoint.url)")
    }
}

/// Ends once: `true` on the first answer, `false` when `timeout` passes on
/// the clock first or the waiting task is cancelled. The timer is armed only
/// when no answer is in yet, so a test's clock sees no sleep for an answer
/// that came with `connect`.
private final class SpeechStageWait: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Bool, Never>?)
        case done(Bool)
    }

    private let state = Mutex(State.waiting(nil))

    func finish(answered: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard case .waiting(let continuation) = state else { return nil }
            state = .done(answered)
            return continuation
        }
        continuation?.resume(returning: answered)
    }

    func value(timeout: TimeInterval, clock: SessionClock) async -> Bool {
        let isDone = state.withLock { state in
            if case .done = state { return true }
            return false
        }
        let timer: Task<Void, Never>? =
            isDone
            ? nil
            : Task { [self] in
                await clock.sleep(.seconds(timeout))
                finish(answered: false)
            }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let done = state.withLock { state -> Bool? in
                    if case .done(let answered) = state { return answered }
                    state = .waiting(continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        } onCancel: {
            finish(answered: false)
        }
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
