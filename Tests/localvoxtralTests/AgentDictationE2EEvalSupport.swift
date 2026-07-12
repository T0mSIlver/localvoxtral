import CryptoKit
import Foundation

@testable import localvoxtral

/// Pure helpers for the agent-dictation end-to-end eval harness
/// (`AgentDictationE2EEvalTests`): enablement/marker resolution, WAV-cache key
/// derivation, per-pipeline stage routing, per-stratum polish-profile routing,
/// corpus-contract scoring, `say -v ?` voice picking, and scoreboard
/// rendering. Everything here is deterministic and unit-tested in the plain
/// tier-0 suite (`AgentDictationE2EEvalSupportTests`) — the live suite only
/// adds TTS/ASR/polish I/O around these functions.
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

    static let defaultHelperPath =
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd"
    static let defaultVoxmlxEndpoint = "ws://127.0.0.1:8000/v1/realtime"
    /// The realtime model the build host's voxmlx service serves (same pin as
    /// the tier-1 integration lane in `remote-build.sh integration`).
    static let defaultASRModel = "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit"

    struct MarkerConfig: Decodable, Equatable {
        let helperPath: String?
        let voxmlxEndpoint: String?
        let asrModel: String?
        let polishModel: String?

        init(
            helperPath: String? = nil,
            voxmlxEndpoint: String? = nil,
            asrModel: String? = nil,
            polishModel: String? = nil
        ) {
            self.helperPath = helperPath
            self.voxmlxEndpoint = voxmlxEndpoint
            self.asrModel = asrModel
            self.polishModel = polishModel
        }
    }

    struct Enablement: Equatable {
        let helperPath: String
        let voxmlxEndpoint: URL
        let asrModel: String
        let polishModel: String
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

        let endpointString = pick(
            voxmlxEndpointEnvKey, marker?.voxmlxEndpoint, default: defaultVoxmlxEndpoint
        )
        guard let endpoint = URL(string: endpointString) else { return nil }
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
            )
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

    // MARK: - Pipeline routing

    struct StagePlan: Equatable {
        /// TTS(spokenForm) -> websocket ASR.
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
    /// `tokensFailures`/`exactTextFailures` score the BASELINE run (the
    /// production path, token guard on); `guardOffTokensFailures` is the
    /// diagnostic guard-off column — the same run's RAW model output scored on
    /// the tokens metric, measuring what the token guard saved (how often #101
    /// earns its keep) at zero extra inference cost. More ablation columns
    /// (feature-off runs) slot in as additional optional fields + a line
    /// suffix in `renderLine` (Phase 3).
    struct CaseResult {
        let caseID: String
        let stratum: String
        let pipeline: AgentDictationEvalCorpus.Pipeline
        let lang: AgentDictationEvalCorpus.Language
        let statusByMetric: [String: AgentDictationEvalCorpus.Status]
        /// Environmental skip (e.g. no French TTS voice installed): printed
        /// and counted, never a failure.
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
                    lines.append("SKIP \(row.caseID) — \(reason)")
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
            "== guard-off diagnostic: token guard flipped \(totalGuardSaves) case(s) "
                + "from fail (raw model output) to pass (guarded commit) =="
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
            suffix = " | guard-off tokens: \(guardOff.isEmpty ? "PASS" : "FAIL")"
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
}
