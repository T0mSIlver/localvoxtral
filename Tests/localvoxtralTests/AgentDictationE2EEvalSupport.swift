import CryptoKit
import Foundation

@testable import localvoxtral

/// Pure helpers for the agent-dictation end-to-end eval harness
/// (`AgentDictationE2EEvalTests`): enablement/marker resolution, WAV-cache key
/// derivation, per-pipeline stage routing, per-stratum polish-profile routing,
/// corpus-contract scoring, `say -v ?` voice picking, and scoreboard
/// rendering. Everything here is deterministic and unit-tested in the plain
/// tier-0 suite (`AgentDictationE2EEvalSupportTests`) — the live suite only
/// adds recorded-or-TTS audio, ASR, and polish I/O around these functions.
enum AgentDictationE2EEvalSupport {
    // MARK: - Enablement

    /// The gitignored marker file `remote-build.sh eval-e2e` writes at the
    /// repo root (the SSH build gate pins env prefixes per-command, so
    /// enablement travels inside the rsynced tree — same pattern as
    /// `.polishd-integration-enable.json`).
    static let markerFileName = ".agent-eval-e2e-enable.json"
    static let enableEnvKey = "LV_AGENT_EVAL_E2E_ENABLE"
    static let helperPathEnvKey = "LV_AGENT_EVAL_E2E_HELPER_PATH"
    static let voxmlxEndpointEnvKey = "LV_AGENT_EVAL_E2E_VOXMLX_ENDPOINT"
    static let asrModelEnvKey = "LV_AGENT_EVAL_E2E_ASR_MODEL"
    static let polishModelEnvKey = "LV_AGENT_EVAL_E2E_POLISH_MODEL"
    static let polishEndpointEnvKey = "LV_AGENT_EVAL_E2E_POLISH_ENDPOINT"
    static let recordingDirectoryEnvKey = "LV_AGENT_EVAL_E2E_RECORDING_DIRECTORY"
    static let recordingSubsetEnvKey = "LV_AGENT_EVAL_E2E_RECORDING_SUBSET"
    static let caseIDsEnvKey = "LV_AGENT_EVAL_E2E_CASE_IDS"

    static let defaultHelperPath =
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd"
    static let defaultVoxmlxEndpoint = "ws://127.0.0.1:8000/v1/realtime"
    /// The realtime model the build host's speechd STT service serves (same pin
    /// as the tier-1 integration lane in `remote-build.sh integration`).
    static let defaultASRModel = "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"

    struct MarkerConfig: Decodable, Equatable {
        let helperPath: String?
        let voxmlxEndpoint: String?
        let asrModel: String?
        let polishModel: String?
        let polishEndpoint: String?
        let recordingDirectory: String?
        let recordingSubset: Bool?

        init(
            helperPath: String? = nil,
            voxmlxEndpoint: String? = nil,
            asrModel: String? = nil,
            polishModel: String? = nil,
            polishEndpoint: String? = nil,
            recordingDirectory: String? = nil,
            recordingSubset: Bool? = nil
        ) {
            self.helperPath = helperPath
            self.voxmlxEndpoint = voxmlxEndpoint
            self.asrModel = asrModel
            self.polishModel = polishModel
            self.polishEndpoint = polishEndpoint
            self.recordingDirectory = recordingDirectory
            self.recordingSubset = recordingSubset
        }
    }

    struct Enablement: Equatable {
        let helperPath: String
        let voxmlxEndpoint: URL
        let asrModel: String
        let polishModel: String
        /// Non-nil bypasses the bundled helper and sends production-shaped
        /// requests to this OpenAI-compatible chat/completions endpoint.
        let polishEndpoint: URL?
        /// Nil uses cached `say` synthesis. Non-nil is a strict human WAV set:
        /// no missing/stale recording silently falls back to TTS.
        let recordingDirectory: String?
        /// Explicit exploratory mode: score only human-recorded case IDs.
        /// The default/full baseline remains all-or-nothing.
        let recordingSubset: Bool
        /// Optional explicit focused slice. Unlike recordingSubset, this does
        /// not add audio-independent cases: the operator asked for exact IDs.
        let caseIDs: Set<String>?
    }

    static func parseMarker(_ data: Data) throws -> MarkerConfig {
        try JSONDecoder().decode(MarkerConfig.self, from: data)
    }

    /// Resolves the effective configuration from env (when the enable env var
    /// is "1") or a parsed marker (when present); nil = the suite self-skips.
    /// Defaults are applied field-by-field so a marker only carrying
    /// `helperPath` still gets the pinned ASR endpoint/model.
    static func resolveEnablement(
        environment: [String: String],
        marker: MarkerConfig?
    ) -> Enablement? {
        let envEnabled = environment[enableEnvKey] == "1"
        guard envEnabled || marker != nil else { return nil }

        func pick(_ envKey: String, _ markerValue: String?, default defaultValue: String) -> String {
            if envEnabled, let value = environment[envKey], !value.isEmpty {
                return value
            }
            if let markerValue, !markerValue.isEmpty {
                return markerValue
            }
            return defaultValue
        }

        func pickOptional(_ envKey: String, _ markerValue: String?) -> String? {
            if envEnabled, let value = environment[envKey], !value.isEmpty { return value }
            if let markerValue, !markerValue.isEmpty { return markerValue }
            return nil
        }

        let endpointString = pick(
            voxmlxEndpointEnvKey, marker?.voxmlxEndpoint, default: defaultVoxmlxEndpoint
        )
        guard let endpoint = URL(string: endpointString) else { return nil }
        let polishEndpointString = pickOptional(
            polishEndpointEnvKey, marker?.polishEndpoint
        )
        let polishEndpoint = polishEndpointString.flatMap(URL.init(string:))
        if polishEndpointString != nil, polishEndpoint == nil { return nil }
        let recordingSubset: Bool
        if envEnabled, let value = environment[recordingSubsetEnvKey] {
            recordingSubset = value == "1"
        } else {
            recordingSubset = marker?.recordingSubset == true
        }
        let caseIDs: Set<String>?
        if envEnabled, let raw = environment[caseIDsEnvKey] {
            let parsed = Set(raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            caseIDs = parsed.isEmpty ? nil : parsed
        } else {
            caseIDs = nil
        }
        return Enablement(
            helperPath: pick(helperPathEnvKey, marker?.helperPath, default: defaultHelperPath),
            voxmlxEndpoint: endpoint,
            asrModel: pick(asrModelEnvKey, marker?.asrModel, default: defaultASRModel),
            // Same pin as production's default (SettingsStore
            // .defaultLLMPolishingModel resolves to this catalog entry; the
            // settings store itself is MainActor-isolated, the catalog is not).
            polishModel: pick(
                polishModelEnvKey, marker?.polishModel,
                default: PolishModelCatalog.defaultOption.repoID
            ),
            polishEndpoint: polishEndpoint,
            recordingDirectory: pickOptional(
                recordingDirectoryEnvKey, marker?.recordingDirectory
            ),
            recordingSubset: recordingSubset,
            caseIDs: caseIDs
        )
    }

    // MARK: - WAV cache

    static let ttsDataFormat = "LEI16@16000"

    /// Cache key for a synthesized utterance: SHA-256 over the exact
    /// text + voice + data format, so any change to what `say` would produce
    /// changes the key and a rerun over an unchanged corpus is a pure cache
    /// hit (TTS is the slow step across ~150 cases x reruns). `voice == nil`
    /// (the system default voice) keys as "default". Each field is
    /// length-prefixed before hashing — a plain separator join is ambiguous
    /// (text "a|B" + voice nil collides with text "a" + voice "B|default";
    /// caught by the tier-0 collision test).
    static func wavCacheKey(
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

    // MARK: - Human recording sets

    static let recordingManifestFileName = "manifest.json"
    static let recordingSchemaVersion = 1
    static let recordingDataFormat = "pcm_s16le@16000Hz-mono"

    struct RecordingManifest: Codable, Equatable {
        let schemaVersion: Int
        let dataFormat: String
        let recordings: [Recording]
    }

    struct Recording: Codable, Equatable {
        let id: String
        let lang: AgentDictationEvalCorpus.Language
        let spokenForm: String
        let file: String
        let sha256: String
    }

    struct RecordingExpectation: Equatable {
        let id: String
        let lang: AgentDictationEvalCorpus.Language
        let spokenForm: String
    }

    struct RecordingSetError: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static func parseRecordingManifest(_ data: Data) throws -> RecordingManifest {
        try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    /// Validates the manifest against the exact speech-running corpus before
    /// model load. Recorded mode is deliberately all-or-nothing by default:
    /// partial sets, corpus drift, duplicate IDs, unsafe filenames, and stale
    /// extras fail loudly rather than producing a TTS/human hybrid baseline.
    /// `allowSubset` is an explicit exploratory mode that validates and runs
    /// only known recorded IDs; it never fills missing cases with TTS.
    static func validateRecordingManifest(
        _ manifest: RecordingManifest,
        expected: [RecordingExpectation],
        allowSubset: Bool = false
    ) throws -> [String: Recording] {
        guard manifest.schemaVersion == recordingSchemaVersion else {
            throw RecordingSetError(message: "recording manifest schemaVersion must be \(recordingSchemaVersion)")
        }
        guard manifest.dataFormat == recordingDataFormat else {
            throw RecordingSetError(message: "recording manifest dataFormat must be \(recordingDataFormat)")
        }

        var byID: [String: Recording] = [:]
        for recording in manifest.recordings {
            guard byID[recording.id] == nil else {
                throw RecordingSetError(message: "duplicate recording id: \(recording.id)")
            }
            guard recording.file == "\(recording.id).wav",
                  !recording.file.contains("/"), !recording.file.contains("..")
            else {
                throw RecordingSetError(message: "unsafe recording filename for \(recording.id)")
            }
            guard recording.sha256.count == 64,
                  recording.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw RecordingSetError(message: "invalid SHA-256 for recording \(recording.id)")
            }
            byID[recording.id] = recording
        }

        let actualIDs = Set(byID.keys)
        let expectedForRun: [RecordingExpectation]
        if allowSubset {
            guard !actualIDs.isEmpty else {
                throw RecordingSetError(message: "recording subset is empty")
            }
            expectedForRun = expected.filter { actualIDs.contains($0.id) }
        } else {
            expectedForRun = expected
        }
        let expectedIDs = Set(expectedForRun.map(\.id))
        let missing = expectedIDs.subtracting(actualIDs).sorted()
        let extra = actualIDs.subtracting(expectedIDs).sorted()
        guard missing.isEmpty else {
            throw RecordingSetError(message: "recording set is incomplete; missing: \(missing.joined(separator: ", "))")
        }
        guard extra.isEmpty else {
            throw RecordingSetError(message: "recording set has stale/unknown cases: \(extra.joined(separator: ", "))")
        }
        for item in expectedForRun {
            guard let recording = byID[item.id] else { continue }
            guard recording.lang == item.lang, recording.spokenForm == item.spokenForm else {
                throw RecordingSetError(
                    message: "recording \(item.id) is stale; language or spokenForm changed"
                )
            }
        }
        return byID
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Validates the exact format the websocket client expects and returns the
    /// data chunk. The recorder command writes this format directly, avoiding
    /// an implicit resample during eval.
    static func recordedPCM16(fromWAVData wav: Data) throws -> Data {
        guard wav.count >= 44,
              String(data: wav[0..<4], encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE"
        else { throw RecordingSetError(message: "recording is not a RIFF/WAVE file") }

        var format: (code: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var pcm: Data?
        var index = 12
        while index + 8 <= wav.count {
            let chunkID = String(data: wav[index..<(index + 4)], encoding: .ascii) ?? ""
            let size = Int(readLEUInt32(wav, at: index + 4))
            let start = index + 8
            let end = start + size
            guard end <= wav.count else {
                throw RecordingSetError(message: "recording has a truncated WAV chunk")
            }
            if chunkID == "fmt ", size >= 16 {
                format = (
                    readLEUInt16(wav, at: start),
                    readLEUInt16(wav, at: start + 2),
                    readLEUInt32(wav, at: start + 4),
                    readLEUInt16(wav, at: start + 14)
                )
            } else if chunkID == "data" {
                pcm = wav.subdata(in: start..<end)
            }
            index = end + (size % 2)
        }
        guard let format else {
            throw RecordingSetError(message: "recording has no WAV fmt chunk")
        }
        guard format.code == 1, format.channels == 1,
              format.rate == 16_000, format.bits == 16
        else {
            throw RecordingSetError(
                message: "recording must be mono 16-bit PCM at 16000 Hz"
            )
        }
        guard let pcm, pcm.count >= 8_000, pcm.count.isMultiple(of: 2) else {
            throw RecordingSetError(message: "recording is missing or shorter than 0.25 seconds")
        }
        var containsSignal = false
        var sampleOffset = 0
        while sampleOffset < pcm.count {
            if readLEUInt16(pcm, at: sampleOffset) != 0 {
                containsSignal = true
                break
            }
            sampleOffset += 2
        }
        guard containsSignal else {
            throw RecordingSetError(message: "recording is digitally silent")
        }
        return pcm
    }

    private static func readLEUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    // MARK: - Pipeline routing

    struct StagePlan: Equatable {
        /// Recorded speech or TTS(spokenForm) -> websocket ASR.
        let runsSpeechRecognition: Bool
        /// The polish stop-commit path.
        let runsPolish: Bool
    }

    static func stagePlan(for pipeline: AgentDictationEvalCorpus.Pipeline) -> StagePlan {
        switch pipeline {
        case .full:
            return StagePlan(runsSpeechRecognition: true, runsPolish: true)
        case .asrOnly:
            return StagePlan(runsSpeechRecognition: true, runsPolish: false)
        case .polishOnly:
            return StagePlan(runsSpeechRecognition: false, runsPolish: true)
        }
    }

    /// A partial human recording set limits only speech-driven rows. Cases
    /// that do not need audio (notably all polish-only required checks) still
    /// run, so an exploratory subset cannot report green by omitting them.
    static func selectedCaseIDs(
        strata: [AgentDictationEvalCorpus.LoadedStratum],
        recordedCaseIDs: Set<String>,
        isSubset: Bool
    ) -> Set<String>? {
        guard isSubset else { return nil }
        var selected = recordedCaseIDs
        for loaded in strata
        where !stagePlan(for: loaded.stratum.resolvedPipeline).runsSpeechRecognition
        {
            selected.formUnion(loaded.stratum.cases.map(\.id))
        }
        return selected
    }

    // MARK: - Polish-profile routing

    /// A terminal-like bundle ID on the built-in allowlist — the production
    /// profile selector maps it to the AGENT prompt profile.
    static let terminalTargetBundleID = "com.apple.Terminal"
    /// A bundle ID no allowlist knows — the selector keeps the STANDARD
    /// profile.
    static let textFieldTargetBundleID = "com.localvoxtral.eval.textfield"

    /// The commit-target bundle ID injected per stratum, which drives the
    /// production `selectedPolishProfile` switch. The agent-dictation corpus
    /// runs the AGENT profile — except `punctuation-spacing-migration`, whose
    /// cases (including all 7 day-one required cases) are byte-for-byte
    /// migrations of the `LLMPolishEvalSupport` corpus whose required-case
    /// stability was established under the STANDARD profile; asserting them
    /// under a different prompt would be a new, uncalibrated claim (the
    /// promotion rule demands cross-server-state evidence per prompt).
    static func polishTargetBundleID(forStratum stratum: String) -> String {
        stratum == "punctuation-spacing-migration"
            ? textFieldTargetBundleID
            : terminalTargetBundleID
    }

    // MARK: - Voice picking

    /// Picks a TTS voice from `say -v ?` output: the first `preferred` name
    /// present wins, else the first voice whose locale starts with
    /// `languagePrefix` ("en"/"fr"), else nil. Voice names may contain spaces
    /// ("Bad News"), so lines parse as name + 2+ spaces + locale.
    static func pickVoice(
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

    // MARK: - Scoring (corpus contract)

    /// `tokens` metric: every `requiredTokens` entry present (byte-exact after
    /// spacing normalization; case-sensitive unless the case sets
    /// `caseInsensitive`) AND no `forbiddenSubstrings` entry present (always
    /// case-insensitive). Returns human-readable failure descriptions; empty
    /// means pass.
    static func tokensFailures(
        output: String,
        evalCase: AgentDictationEvalCorpus.Case
    ) -> [String] {
        let normalized = LLMPolishEvalSupport.normalizedSpacing(output)
        let requiredHaystack = evalCase.isCaseInsensitive ? normalized.lowercased() : normalized
        var failures: [String] = []
        for token in evalCase.requiredTokens {
            var needle = LLMPolishEvalSupport.normalizedSpacing(token)
            if evalCase.isCaseInsensitive { needle = needle.lowercased() }
            if !requiredHaystack.contains(needle) {
                failures.append("missing \"\(token)\"")
            }
        }
        let forbiddenHaystack = normalized.lowercased()
        for needle in evalCase.forbidden {
            let normalizedNeedle = LLMPolishEvalSupport.normalizedSpacing(needle).lowercased()
            if forbiddenHaystack.contains(normalizedNeedle) {
                failures.append("contains forbidden \"\(needle)\"")
            }
        }
        return failures
    }

    /// `exactText` metric: normalized whole-output equality with
    /// `intendedText` (spacing normalization; lowercased when the case is
    /// `caseInsensitive` — the migrated punctuation cases keep the old
    /// scorer's semantics). nil = pass.
    static func exactTextFailure(
        output: String,
        evalCase: AgentDictationEvalCorpus.Case
    ) -> String? {
        var actual = LLMPolishEvalSupport.normalizedSpacing(output)
        var expected = LLMPolishEvalSupport.normalizedSpacing(evalCase.intendedText)
        if evalCase.isCaseInsensitive {
            actual = actual.lowercased()
            expected = expected.lowercased()
        }
        guard actual != expected else { return nil }
        let expectedForLog = evalCase.intendedText.replacingOccurrences(of: "\n", with: "\\n")
        return "expected \"\(expectedForLog)\""
    }

    /// Anti-rewrite guard (scorer behavior per the corpus README, not corpus
    /// data): letters/digits word accuracy between the polish INPUT and the
    /// final output must clear `LLMPolishEvalSupport.requiredWordAccuracy`,
    /// or the polisher rewrote instead of cleaning. Positive macro cases are
    /// exempt — embedding the clipboard payload legitimately explodes the
    /// token count. nil = pass.
    static func antiRewriteFailure(
        polishInput: String,
        output: String,
        evalCase: AgentDictationEvalCorpus.Case
    ) -> String? {
        guard evalCase.features?.macro != true else { return nil }
        let accuracy = IntegrationTestSupport.wordAccuracy(expected: polishInput, actual: output)
        guard accuracy < LLMPolishEvalSupport.requiredWordAccuracy else { return nil }
        return "word accuracy vs input \(String(format: "%.2f", accuracy)) "
            + "< \(LLMPolishEvalSupport.requiredWordAccuracy) (rewrote the text)"
    }

    // MARK: - Case results + scoreboard

    /// The outcome of one corpus case, one row of the scoreboard. Columns:
    /// `tokensFailures`/`exactTextFailures` score the BASELINE production path;
    /// `guardOffTokensFailures` retains its schema name for compatibility but
    /// is the raw-model diagnostic column — the same run's model output before
    /// clipboard safety checks (for macro cases, after commit-time payload
    /// substitution) scored on the tokens metric. More ablation columns slot in as
    /// additional optional fields + a line suffix in `renderLine` (Phase 3).
    struct CaseResult {
        let caseID: String
        let stratum: String
        let pipeline: AgentDictationEvalCorpus.Pipeline
        let lang: AgentDictationEvalCorpus.Language
        let statusByMetric: [String: AgentDictationEvalCorpus.Status]
        /// Environmental skip (e.g. no French TTS voice installed): printed
        /// and counted; non-fatal for known-hard rows, but a skip on a row
        /// carrying a REQUIRED metric is counted as a required failure by
        /// `renderScoreboard` — a required case must be measured, not
        /// silently passed over.
        var skipReason: String?
        /// Pipeline infrastructure error (say failed, ASR connect/timeout,
        /// polish request failed): fails the suite — infra rot must redden
        /// the nightly lane, not silently degrade it.
        var infraFailure: String?
        var tokensFailures: [String]
        /// nil when the case carries no exactText status.
        var exactTextFailures: [String]?
        /// nil when no polish ran (asr-only) or no raw output was captured.
        var guardOffTokensFailures: [String]?
        /// Anti-rewrite failure kept separate from token preservation so the
        /// inspection report can classify model rewrites directly.
        var rewriteFailure: String?
        /// True when the rewrite failure contributes to a required metric.
        var rewriteIsFatal: Bool?
        /// Informational: word accuracy of the final output vs intendedText.
        var wordAccuracyVsIntended: Double?
        var output: String

        init(
            caseID: String,
            stratum: String,
            pipeline: AgentDictationEvalCorpus.Pipeline,
            lang: AgentDictationEvalCorpus.Language,
            statusByMetric: [String: AgentDictationEvalCorpus.Status],
            skipReason: String? = nil,
            infraFailure: String? = nil,
            tokensFailures: [String] = [],
            exactTextFailures: [String]? = nil,
            guardOffTokensFailures: [String]? = nil,
            rewriteFailure: String? = nil,
            rewriteIsFatal: Bool? = nil,
            wordAccuracyVsIntended: Double? = nil,
            output: String = ""
        ) {
            self.caseID = caseID
            self.stratum = stratum
            self.pipeline = pipeline
            self.lang = lang
            self.statusByMetric = statusByMetric
            self.skipReason = skipReason
            self.infraFailure = infraFailure
            self.tokensFailures = tokensFailures
            self.exactTextFailures = exactTextFailures
            self.guardOffTokensFailures = guardOffTokensFailures
            self.rewriteFailure = rewriteFailure
            self.rewriteIsFatal = rewriteIsFatal
            self.wordAccuracyVsIntended = wordAccuracyVsIntended
            self.output = output
        }

        /// Metrics whose status is `required` and whose baseline column
        /// failed — each one is asserted individually by the suite.
        var failedRequiredMetrics: [(metric: String, failures: [String])] {
            var failed: [(String, [String])] = []
            if statusByMetric["tokens"] == .required, !tokensFailures.isEmpty {
                failed.append(("tokens", tokensFailures))
            }
            if statusByMetric["exactText"] == .required,
                let exactTextFailures, !exactTextFailures.isEmpty
            {
                failed.append(("exactText", exactTextFailures))
            }
            return failed
        }

        var scoredMetricsAllPass: Bool {
            tokensFailures.isEmpty && (exactTextFailures?.isEmpty ?? true)
        }

        var carriesRequiredMetric: Bool {
            statusByMetric.values.contains(.required)
        }
    }

    struct RenderedScoreboard {
        let text: String
        /// One entry per failed REQUIRED metric, ready for XCTFail — names the
        /// case, the metric, the failures, and the output.
        let requiredFailures: [String]
        /// One entry per infrastructure error, ready for XCTFail.
        let infraFailures: [String]
    }

    // Scoreboard delimiters — eval-e2e.yml extracts the section between them
    // into the run's step summary; keep in sync with the workflow.
    static let scoreboardBeginMarker = "== agent-dictation E2E eval scoreboard =="
    static let scoreboardEndMarker = "== end agent-dictation E2E eval scoreboard =="

    static func renderScoreboard(
        results: [CaseResult],
        header: String
    ) -> RenderedScoreboard {
        var lines: [String] = [scoreboardBeginMarker, header]
        var requiredFailures: [String] = []
        var infraFailures: [String] = []

        // Preserve corpus order; group rows by stratum in first-seen order.
        var strataOrder: [String] = []
        var byStratum: [String: [CaseResult]] = [:]
        for result in results {
            if byStratum[result.stratum] == nil {
                strataOrder.append(result.stratum)
            }
            byStratum[result.stratum, default: []].append(result)
        }

        var totalRequired = 0
        var totalRequiredPassed = 0
        var totalKnownHardScored = 0
        var totalKnownHardPassed = 0
        var totalGuardSaves = 0
        var totalSkipped = 0
        var totalErrors = 0

        for stratum in strataOrder {
            let rows = byStratum[stratum] ?? []
            let pipeline = rows.first?.pipeline.rawValue ?? "full"
            lines.append("-- \(stratum) (pipeline \(pipeline), \(rows.count) cases) --")

            var tokensPassed = 0
            var tokensScored = 0
            var exactPassed = 0
            var exactScored = 0
            var accuracies: [Double] = []
            var skipped = 0
            var errors = 0

            for row in rows {
                if let reason = row.skipReason {
                    // A required case that never RAN must not pass silently:
                    // environmental skips are tolerable for known-hard rows,
                    // but a required metric demands a measurement. (No
                    // required case is TTS-dependent today — all 7 are
                    // polish-only — but Phase-3 promotion may change that.)
                    if row.carriesRequiredMetric {
                        lines.append(
                            "SKIP \(row.caseID) — \(reason) [required case — skip counts as failure]"
                        )
                        requiredFailures.append(
                            "required case \(row.caseID) was skipped without running: \(reason)"
                        )
                    } else {
                        lines.append("SKIP \(row.caseID) — \(reason)")
                    }
                    skipped += 1
                    continue
                }
                if let infra = row.infraFailure {
                    lines.append("ERROR \(row.caseID) — \(infra)")
                    infraFailures.append("infra error on \(row.caseID): \(infra)")
                    errors += 1
                    continue
                }

                tokensScored += 1
                if row.tokensFailures.isEmpty { tokensPassed += 1 }
                if let exactTextFailures = row.exactTextFailures {
                    exactScored += 1
                    if exactTextFailures.isEmpty { exactPassed += 1 }
                }
                if let accuracy = row.wordAccuracyVsIntended {
                    accuracies.append(accuracy)
                }

                let failedRequired = row.failedRequiredMetrics
                totalRequired += row.statusByMetric.values.count { $0 == .required }
                totalRequiredPassed +=
                    row.statusByMetric.values.count { $0 == .required } - failedRequired.count
                if !row.carriesRequiredMetric {
                    totalKnownHardScored += 1
                    if row.scoredMetricsAllPass { totalKnownHardPassed += 1 }
                }

                lines.append(renderLine(row: row))

                for (metric, failures) in failedRequired {
                    requiredFailures.append(
                        "required case \(row.caseID) failed [\(metric)]: "
                            + "\(failures.joined(separator: "; ")) — output: \(row.output)"
                    )
                }
                if let guardOff = row.guardOffTokensFailures,
                    row.tokensFailures.isEmpty, !guardOff.isEmpty
                {
                    totalGuardSaves += 1
                }
            }

            let meanAccuracy =
                accuracies.isEmpty
                ? "n/a"
                : String(format: "%.2f", accuracies.reduce(0, +) / Double(accuracies.count))
            lines.append(
                "-- \(stratum) summary: tokens \(tokensPassed)/\(tokensScored), "
                    + "exactText \(exactPassed)/\(exactScored), "
                    + "mean word-accuracy vs intended \(meanAccuracy)"
                    + (skipped > 0 ? ", skipped \(skipped)" : "")
                    + (errors > 0 ? ", errors \(errors)" : "") + " --"
            )
            totalSkipped += skipped
            totalErrors += errors
        }

        lines.append(
            "== required: \(totalRequiredPassed)/\(totalRequired) metric checks passed, "
                + "known-hard cases fully passing: \(totalKnownHardPassed)/\(totalKnownHardScored), "
                + "skipped \(totalSkipped), errors \(totalErrors) =="
        )
        lines.append(
            "== raw-model diagnostic: post-model safety changed \(totalGuardSaves) case(s) "
                + "from token fail (raw model output) to pass (production commit) =="
        )
        lines.append(scoreboardEndMarker)

        return RenderedScoreboard(
            text: lines.joined(separator: "\n"),
            requiredFailures: requiredFailures,
            infraFailures: infraFailures
        )
    }

    private static func renderLine(row: CaseResult) -> String {
        var failureParts: [String] = []
        if !row.tokensFailures.isEmpty {
            failureParts.append("[tokens] \(row.tokensFailures.joined(separator: "; "))")
        }
        if let exactTextFailures = row.exactTextFailures, !exactTextFailures.isEmpty {
            failureParts.append("[exactText] \(exactTextFailures.joined(separator: "; "))")
        }

        var suffix = ""
        if let guardOff = row.guardOffTokensFailures {
            suffix = " | raw-model tokens: \(guardOff.isEmpty ? "PASS" : "FAIL")"
        }

        let flatOutput = row.output.replacingOccurrences(of: "\n", with: "\\n")
        if failureParts.isEmpty {
            let annotation =
                row.carriesRequiredMetric
                ? ""
                : " (known-hard — promote only with cross-server-state evidence)"
            return "PASS \(row.caseID)\(annotation)\(suffix)"
        }
        let failedRequired = !row.failedRequiredMetrics.isEmpty
        let label =
            failedRequired ? "FAIL \(row.caseID) [required]" : "XFAIL \(row.caseID) (known-hard)"
        return "\(label): \(failureParts.joined(separator: " ")) — output: \(flatOutput)\(suffix)"
    }

    // MARK: - Per-case inspection report

    /// Sentinels bracketing the JSONL inspection report in the suite's
    /// stdout. The SSH build gate has no file fetch-back channel, so the
    /// remote log (`.build/last-remote.log`) is the transport: between the
    /// sentinels, line 1 is the `ReportHeader` and every further line is one
    /// `CaseReportRecord`.
    static let reportBeginSentinel = "=== AGENT-E2E-INSPECTION-REPORT-BEGIN ==="
    static let reportEndSentinel = "=== AGENT-E2E-INSPECTION-REPORT-END ==="

    /// Line 1 of the report: run metadata plus the deduplicated system-prompt
    /// table — two profiles means two entries, so per-case records reference
    /// an index instead of repeating kilobytes 150+ times.
    struct ReportHeader: Codable, Equatable {
        let polishModel: String
        let asrModel: String
        let audioSource: String?
        let systemPrompts: [String]

        init(
            polishModel: String,
            asrModel: String,
            audioSource: String? = nil,
            systemPrompts: [String]
        ) {
            self.polishModel = polishModel
            self.asrModel = asrModel
            self.audioSource = audioSource
            self.systemPrompts = systemPrompts
        }
    }

    /// Intermediate pipeline artifacts the live suite observes for one case,
    /// beyond what `CaseResult` scores: the ASR transcript, the exact polish
    /// request, and the model output before deterministic post-model steps.
    struct CaseCapture {
        /// ASR output (nil when the pipeline skipped speech recognition).
        var transcript: String?
        /// The system prompt exactly as the production request carried it.
        var polishSystemPrompt: String?
        var polishUserPrompts: [String]?
        var polishInputText: String?
        /// Raw model output (macro cases: still placeholder-form).
        var rawModelOutput: String?
        /// Raw-model diagnostic text as scored (macro payload substituted).
        var guardOffOutput: String?
    }

    /// Everything the harness saw for one case, for offline inspection:
    /// corpus inputs, pipeline artifacts, and the scored verdicts.
    struct CaseReportRecord: Codable {
        let caseID: String
        let stratum: String
        let pipeline: AgentDictationEvalCorpus.Pipeline
        let lang: AgentDictationEvalCorpus.Language
        let statusByMetric: [String: AgentDictationEvalCorpus.Status]
        let spokenForm: String
        let intendedText: String
        let requiredTokens: [String]
        let forbiddenSubstrings: [String]
        let caseInsensitive: Bool
        let features: AgentDictationEvalCorpus.Features?
        let transcript: String?
        /// Index into `ReportHeader.systemPrompts`; nil when no polish ran.
        let systemPromptIndex: Int?
        let userPrompts: [String]?
        let polishInputText: String?
        let rawModelOutput: String?
        let guardOffOutput: String?
        let output: String
        let skipReason: String?
        let infraFailure: String?
        let tokensFailures: [String]
        let exactTextFailures: [String]?
        let guardOffTokensFailures: [String]?
        let rewriteFailure: String?
        let rewriteIsFatal: Bool?
        let wordAccuracyVsIntended: Double?
    }

    static func makeReportRecord(
        evalCase: AgentDictationEvalCorpus.Case,
        result: CaseResult,
        capture: CaseCapture,
        systemPromptIndex: Int?
    ) -> CaseReportRecord {
        CaseReportRecord(
            caseID: result.caseID,
            stratum: result.stratum,
            pipeline: result.pipeline,
            lang: result.lang,
            statusByMetric: result.statusByMetric,
            spokenForm: evalCase.spokenForm,
            intendedText: evalCase.intendedText,
            requiredTokens: evalCase.requiredTokens,
            forbiddenSubstrings: evalCase.forbidden,
            caseInsensitive: evalCase.isCaseInsensitive,
            features: evalCase.features,
            transcript: capture.transcript,
            systemPromptIndex: systemPromptIndex,
            userPrompts: capture.polishUserPrompts,
            polishInputText: capture.polishInputText,
            rawModelOutput: capture.rawModelOutput,
            guardOffOutput: capture.guardOffOutput,
            output: result.output,
            skipReason: result.skipReason,
            infraFailure: result.infraFailure,
            tokensFailures: result.tokensFailures,
            exactTextFailures: result.exactTextFailures,
            guardOffTokensFailures: result.guardOffTokensFailures,
            rewriteFailure: result.rewriteFailure,
            rewriteIsFatal: result.rewriteIsFatal,
            wordAccuracyVsIntended: result.wordAccuracyVsIntended
        )
    }

    static func renderReport(
        header: ReportHeader, records: [CaseReportRecord]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines: [String] = [reportBeginSentinel]
        lines.append(String(decoding: try encoder.encode(header), as: UTF8.self))
        for record in records {
            lines.append(String(decoding: try encoder.encode(record), as: UTF8.self))
        }
        lines.append(reportEndSentinel)
        return lines.joined(separator: "\n")
    }
}
