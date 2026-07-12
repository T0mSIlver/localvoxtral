import Foundation
import XCTest

@testable import localvoxtral

/// Tier-0 unit coverage for the deterministic pieces of the agent-dictation
/// E2E eval harness (no gating, no network, no TTS): enablement resolution,
/// WAV-cache key derivation, pipeline/profile routing, corpus-contract
/// scoring, voice picking, and scoreboard rendering. @MainActor because two
/// assertions consult MainActor-isolated production types (SettingsStore's
/// default model pin, TerminalTargetDetector's allowlist).
@MainActor
final class AgentDictationE2EEvalSupportTests: XCTestCase {
    private typealias Support = AgentDictationE2EEvalSupport

    // MARK: - Marker parsing + enablement resolution

    func testParseMarkerReadsAllFields() throws {
        let data = Data(
            """
            {"helperPath": "/tmp/polishd", "voxmlxEndpoint": "ws://127.0.0.1:9000/v1/realtime",
             "asrModel": "acme/asr", "polishModel": "acme/polish"}
            """.utf8
        )
        let marker = try Support.parseMarker(data)
        XCTAssertEqual(marker.helperPath, "/tmp/polishd")
        XCTAssertEqual(marker.voxmlxEndpoint, "ws://127.0.0.1:9000/v1/realtime")
        XCTAssertEqual(marker.asrModel, "acme/asr")
        XCTAssertEqual(marker.polishModel, "acme/polish")
    }

    func testParseMarkerToleratesMissingFields() throws {
        let marker = try Support.parseMarker(Data("{\"helperPath\": \"x\"}".utf8))
        XCTAssertEqual(marker.helperPath, "x")
        XCTAssertNil(marker.voxmlxEndpoint)
        XCTAssertNil(marker.asrModel)
        XCTAssertNil(marker.polishModel)
    }

    func testEnablementNilWithoutEnvOrMarker() {
        XCTAssertNil(Support.resolveEnablement(environment: [:], marker: nil))
        // A "0" env value is not enablement either.
        XCTAssertNil(
            Support.resolveEnablement(
                environment: [Support.enableEnvKey: "0"], marker: nil
            )
        )
    }

    func testEnablementFromMarkerAppliesDefaultsFieldByField() throws {
        let enablement = try XCTUnwrap(
            Support.resolveEnablement(
                environment: [:],
                marker: Support.MarkerConfig(helperPath: "custom/polishd")
            )
        )
        XCTAssertEqual(enablement.helperPath, "custom/polishd")
        XCTAssertEqual(enablement.voxmlxEndpoint.absoluteString, Support.defaultVoxmlxEndpoint)
        XCTAssertEqual(enablement.asrModel, Support.defaultASRModel)
        XCTAssertEqual(enablement.polishModel, SettingsStore.defaultLLMPolishingModel)
    }

    func testEnablementFromEnvOverridesMarker() throws {
        let enablement = try XCTUnwrap(
            Support.resolveEnablement(
                environment: [
                    Support.enableEnvKey: "1",
                    Support.helperPathEnvKey: "/env/polishd",
                ],
                marker: Support.MarkerConfig(helperPath: "marker/polishd", asrModel: "marker/asr")
            )
        )
        XCTAssertEqual(enablement.helperPath, "/env/polishd")
        // Fields the env does not carry still fall through to the marker.
        XCTAssertEqual(enablement.asrModel, "marker/asr")
    }

    // MARK: - WAV cache key

    func testWavCacheKeyIsDeterministicHex() {
        let first = Support.wavCacheKey(text: "open the dot env file", voice: "Samantha")
        let second = Support.wavCacheKey(text: "open the dot env file", voice: "Samantha")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testWavCacheKeyChangesWithEachInput() {
        let base = Support.wavCacheKey(text: "hello", voice: "Samantha")
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello there", voice: "Samantha"))
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello", voice: "Thomas"))
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello", voice: nil))
        XCTAssertNotEqual(
            base, Support.wavCacheKey(text: "hello", voice: "Samantha", dataFormat: "LEI16@22050")
        )
    }

    /// Field boundaries must be unambiguous: text containing a would-be
    /// separator must not collide with a shifted voice value. (This test
    /// caught the original "|"-join derivation doing exactly that; fields are
    /// length-prefixed now.)
    func testWavCacheKeyFieldBoundariesDoNotCollide() {
        XCTAssertNotEqual(
            Support.wavCacheKey(text: "a|Samantha", voice: nil),
            Support.wavCacheKey(text: "a", voice: "Samantha|default")
        )
    }

    // MARK: - Pipeline routing

    func testStagePlanPerPipeline() {
        XCTAssertEqual(
            Support.stagePlan(for: .full),
            Support.StagePlan(runsSpeechRecognition: true, runsPolish: true)
        )
        XCTAssertEqual(
            Support.stagePlan(for: .asrOnly),
            Support.StagePlan(runsSpeechRecognition: true, runsPolish: false)
        )
        XCTAssertEqual(
            Support.stagePlan(for: .polishOnly),
            Support.StagePlan(runsSpeechRecognition: false, runsPolish: true)
        )
    }

    /// Every corpus stratum routes: the migration stratum keeps the STANDARD
    /// profile (its required-case baseline was established under the standard
    /// prompt), everything else is agent dictation and gets the terminal
    /// target -> agent profile.
    func testPolishProfileRoutingPerStratum() throws {
        XCTAssertEqual(
            Support.polishTargetBundleID(forStratum: "punctuation-spacing-migration"),
            Support.textFieldTargetBundleID
        )
        XCTAssertFalse(
            TerminalTargetDetector.isTerminalLikeBundleID(Support.textFieldTargetBundleID)
        )
        for stratum in AgentDictationEvalCorpus.expectedStrata
        where stratum != "punctuation-spacing-migration" {
            XCTAssertEqual(
                Support.polishTargetBundleID(forStratum: stratum),
                Support.terminalTargetBundleID
            )
        }
        XCTAssertTrue(
            TerminalTargetDetector.isTerminalLikeBundleID(Support.terminalTargetBundleID)
        )
    }

    // MARK: - Voice picking

    private let sampleVoices = """
        Alex                en_US    # Most people recognize me by my voice.
        Amélie              fr_CA    # Bonjour! Je m'appelle Amélie.
        Bad News            en_US    # The light you see at the end of the tunnel...
        Samantha            en_US    # Hello! My name is Samantha.
        Thomas              fr_FR    # Bonjour! Je m'appelle Thomas.
        """

    func testPickVoicePrefersNamedVoice() {
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "fr",
                preferred: ["Thomas", "Amélie"]
            ),
            "Thomas"
        )
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "en",
                preferred: ["Samantha"]
            ),
            "Samantha"
        )
    }

    func testPickVoiceFallsBackToFirstLanguageMatch() {
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "fr",
                preferred: ["Nonexistent"]
            ),
            "Amélie"
        )
    }

    func testPickVoiceReturnsNilWhenLanguageAbsent() {
        XCTAssertNil(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "de", preferred: ["Anna"]
            )
        )
    }

    /// Multi-word names ("Bad News") parse whole, and hyphenated locales
    /// (fr-FR, seen on newer macOS) still match the language prefix.
    func testPickVoiceParsesMultiWordNamesAndHyphenLocales() {
        let output = """
            Bad News            en_US    # ...
            Jacques             fr-FR    # ...
            """
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "en", preferred: ["Bad News"]
            ),
            "Bad News"
        )
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "fr", preferred: []
            ),
            "Jacques"
        )
    }

    // MARK: - Scoring

    /// Cases are built through the loader's decoder (the custom init(from:)
    /// suppresses the memberwise init), which also keeps these tests honest
    /// about the schema.
    private func makeCase(
        id: String = "t-en-sample",
        lang: String = "en",
        spokenForm: String = "spoken",
        intendedText: String = "Intended text.",
        requiredTokens: [String] = ["Intended"],
        forbiddenSubstrings: [String]? = nil,
        caseInsensitive: Bool? = nil,
        featuresJSON: String? = nil,
        status: [String: String] = ["tokens": "known-hard"]
    ) throws -> AgentDictationEvalCorpus.Case {
        var fields: [String] = [
            "\"id\": \(jsonString(id))",
            "\"lang\": \(jsonString(lang))",
            "\"spokenForm\": \(jsonString(spokenForm))",
            "\"intendedText\": \(jsonString(intendedText))",
            "\"requiredTokens\": [\(requiredTokens.map(jsonString).joined(separator: ", "))]",
            "\"status\": {\(status.map { "\(jsonString($0.key)): \(jsonString($0.value))" }.joined(separator: ", "))}",
            "\"notes\": \"unit-test case\"",
        ]
        if let forbiddenSubstrings {
            fields.append(
                "\"forbiddenSubstrings\": [\(forbiddenSubstrings.map(jsonString).joined(separator: ", "))]"
            )
        }
        if let caseInsensitive {
            fields.append("\"caseInsensitive\": \(caseInsensitive)")
        }
        if let featuresJSON {
            fields.append("\"features\": \(featuresJSON)")
        }
        let json = "{\(fields.joined(separator: ", "))}"
        return try JSONDecoder().decode(
            AgentDictationEvalCorpus.Case.self, from: Data(json.utf8)
        )
    }

    private func jsonString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    func testTokensRequiredAreCaseSensitiveByDefault() throws {
        let evalCase = try makeCase(requiredTokens: ["UserSessionManager.swift"])
        XCTAssertEqual(
            Support.tokensFailures(
                output: "Open UserSessionManager.swift now.", evalCase: evalCase
            ),
            []
        )
        XCTAssertEqual(
            Support.tokensFailures(
                output: "open usersessionmanager.swift now.", evalCase: evalCase
            ),
            ["missing \"UserSessionManager.swift\""]
        )
    }

    func testTokensRequiredHonorCaseInsensitiveFlag() throws {
        let evalCase = try makeCase(requiredTokens: ["tomorrow?"], caseInsensitive: true)
        XCTAssertEqual(
            Support.tokensFailures(output: "TOMORROW?", evalCase: evalCase),
            []
        )
    }

    func testForbiddenSubstringsAlwaysCaseInsensitive() throws {
        let evalCase = try makeCase(
            requiredTokens: ["retry"],
            forbiddenSubstrings: ["dash dash"]
        )
        XCTAssertEqual(
            Support.tokensFailures(output: "retry with DASH DASH force", evalCase: evalCase),
            ["contains forbidden \"dash dash\""]
        )
    }

    /// Spacing normalization applies to needle and haystack: a French narrow
    /// no-break space in the output satisfies a plain-space needle.
    func testTokensMatchAfterSpacingNormalization() throws {
        let evalCase = try makeCase(requiredTokens: ["plan :"])
        XCTAssertEqual(
            Support.tokensFailures(output: "Voici le plan\u{202F}: demain.", evalCase: evalCase),
            []
        )
    }

    func testExactTextComparesNormalizedWholeString() throws {
        let evalCase = try makeCase(intendedText: "Voici le plan : on commence.")
        XCTAssertNil(
            Support.exactTextFailure(
                output: "Voici le plan\u{202F}:  on commence.", evalCase: evalCase
            )
        )
        XCTAssertNotNil(
            Support.exactTextFailure(
                output: "Voici le plan : on commence. Extra.", evalCase: evalCase
            )
        )
        // Case-sensitive by default.
        XCTAssertNotNil(
            Support.exactTextFailure(
                output: "voici le plan : on commence.", evalCase: evalCase
            )
        )
    }

    func testExactTextHonorsCaseInsensitiveFlag() throws {
        let evalCase = try makeCase(intendedText: "Are you coming?", caseInsensitive: true)
        XCTAssertNil(
            Support.exactTextFailure(output: "are you coming?", evalCase: evalCase)
        )
    }

    func testAntiRewriteGuardTripsOnRewrite() throws {
        let evalCase = try makeCase()
        XCTAssertNotNil(
            Support.antiRewriteFailure(
                polishInput: "fix the bug in the auth module please",
                output: "Certainly! Here is a plan for your authentication improvements",
                evalCase: evalCase
            )
        )
        XCTAssertNil(
            Support.antiRewriteFailure(
                polishInput: "fix the bug in the auth module please",
                output: "Fix the bug in the auth module, please.",
                evalCase: evalCase
            )
        )
    }

    /// Positive macro cases embed the clipboard payload — a legitimate large
    /// insertion that must never trip the anti-rewrite floor.
    func testAntiRewriteGuardExemptsPositiveMacroCases() throws {
        let macroCase = try makeCase(
            featuresJSON: "{\"clipboard\": \"payload\", \"macro\": true}"
        )
        XCTAssertNil(
            Support.antiRewriteFailure(
                polishInput: "fix this $LV_CLIPBOARD_PAYLOAD now",
                output: "Fix this: a very long embedded clipboard payload with many words "
                    + "that dwarfs the dictated sentence entirely now",
                evalCase: macroCase
            )
        )
        // Negative macro cases (macro: false) keep the floor.
        let negativeCase = try makeCase(
            featuresJSON: "{\"clipboard\": \"payload\", \"macro\": false}"
        )
        XCTAssertNotNil(
            Support.antiRewriteFailure(
                polishInput: "do not paste anything",
                output: "Completely unrelated rewritten sentence about other things entirely",
                evalCase: negativeCase
            )
        )
    }

    // MARK: - Scoreboard rendering

    private func makeResult(
        caseID: String,
        stratum: String = "symbol-forms",
        status: [String: AgentDictationEvalCorpus.Status] = ["tokens": .knownHard]
    ) -> Support.CaseResult {
        Support.CaseResult(
            caseID: caseID,
            stratum: stratum,
            pipeline: .full,
            lang: .en,
            statusByMetric: status,
            output: "output text"
        )
    }

    func testScoreboardCollectsRequiredFailuresIndividually() {
        var failing = makeResult(
            caseID: "e-en-question",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        failing.tokensFailures = ["missing \"tomorrow?\""]
        failing.exactTextFailures = []
        var passing = makeResult(
            caseID: "e-fr-colon",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        passing.exactTextFailures = []

        let board = Support.renderScoreboard(
            results: [failing, passing], header: "unit test board"
        )
        XCTAssertEqual(board.requiredFailures.count, 1)
        XCTAssertTrue(board.requiredFailures[0].contains("e-en-question"))
        XCTAssertTrue(board.requiredFailures[0].contains("[tokens]"))
        XCTAssertTrue(board.requiredFailures[0].contains("missing \"tomorrow?\""))
        XCTAssertTrue(board.text.contains("FAIL e-en-question [required]"))
        XCTAssertTrue(board.text.contains("PASS e-fr-colon"))
        XCTAssertTrue(board.text.contains("required: 3/4 metric checks passed"))
    }

    func testScoreboardKnownHardFailureIsXFAILNotRequiredFailure() {
        var xfail = makeResult(caseID: "b-en-flag")
        xfail.tokensFailures = ["missing \"--force\""]
        var pass = makeResult(caseID: "b-en-port")
        pass.guardOffTokensFailures = ["missing \"8080\""]

        let board = Support.renderScoreboard(results: [xfail, pass], header: "h")
        XCTAssertTrue(board.requiredFailures.isEmpty)
        XCTAssertTrue(board.text.contains("XFAIL b-en-flag (known-hard)"))
        XCTAssertTrue(board.text.contains("PASS b-en-port"))
        // Guard-off column annotated, and the flip counted (baseline pass,
        // raw model output fail = the guard earned its keep).
        XCTAssertTrue(board.text.contains("guard-off tokens: FAIL"))
        XCTAssertTrue(board.text.contains("token guard flipped 1 case(s)"))
    }

    func testScoreboardSkipAndInfraErrorRows() {
        var skipped = makeResult(caseID: "b-fr-voice")
        skipped.skipReason = "no French TTS voice installed"
        var errored = makeResult(caseID: "b-en-conn")
        errored.infraFailure = "ASR websocket timed out"

        let board = Support.renderScoreboard(results: [skipped, errored], header: "h")
        XCTAssertTrue(board.text.contains("SKIP b-fr-voice — no French TTS voice installed"))
        XCTAssertTrue(board.text.contains("ERROR b-en-conn — ASR websocket timed out"))
        XCTAssertTrue(board.requiredFailures.isEmpty)
        XCTAssertEqual(board.infraFailures, ["infra error on b-en-conn: ASR websocket timed out"])
        XCTAssertTrue(board.text.contains("skipped 1, errors 1"))
    }

    /// Review finding (2026-07-12): a REQUIRED case that never ran
    /// (environmental skip, e.g. a missing TTS voice after Phase-3 promotes a
    /// TTS-dependent case) must count as a required failure — a required
    /// metric demands a measurement, and silence must never read as a pass.
    /// Known-hard skips stay non-fatal.
    func testScoreboardSkippedRequiredCaseCountsAsRequiredFailure() {
        var requiredSkipped = makeResult(
            caseID: "e-en-question",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        requiredSkipped.skipReason = "no French TTS voice installed"
        var knownHardSkipped = makeResult(caseID: "b-fr-glob")
        knownHardSkipped.skipReason = "no French TTS voice installed"

        let board = Support.renderScoreboard(
            results: [requiredSkipped, knownHardSkipped], header: "h"
        )
        XCTAssertEqual(board.requiredFailures.count, 1)
        XCTAssertTrue(board.requiredFailures[0].contains("e-en-question"))
        XCTAssertTrue(board.requiredFailures[0].contains("skipped without running"))
        XCTAssertTrue(
            board.text.contains(
                "SKIP e-en-question — no French TTS voice installed "
                    + "[required case — skip counts as failure]"
            )
        )
        // The known-hard skip stays a plain, non-fatal SKIP line.
        XCTAssertTrue(board.text.contains("SKIP b-fr-glob — no French TTS voice installed"))
        XCTAssertFalse(board.text.contains("b-fr-glob — no French TTS voice installed [required"))
        XCTAssertTrue(board.text.contains("skipped 2"))
    }

    func testScoreboardWrapsInExtractionMarkers() {
        let board = Support.renderScoreboard(results: [makeResult(caseID: "x")], header: "h")
        XCTAssertTrue(board.text.hasPrefix(Support.scoreboardBeginMarker))
        XCTAssertTrue(board.text.hasSuffix(Support.scoreboardEndMarker))
    }

    func testScoreboardGroupsByStratumWithSummaries() {
        var a = makeResult(caseID: "a-en-one", stratum: "plain-asr-baseline")
        a.wordAccuracyVsIntended = 0.8
        var b = makeResult(caseID: "b-en-two", stratum: "symbol-forms")
        b.wordAccuracyVsIntended = 1.0
        b.exactTextFailures = []

        let board = Support.renderScoreboard(results: [a, b], header: "h")
        XCTAssertTrue(board.text.contains("-- plain-asr-baseline (pipeline full, 1 cases) --"))
        XCTAssertTrue(
            board.text.contains(
                "-- plain-asr-baseline summary: tokens 1/1, exactText 0/0, "
                    + "mean word-accuracy vs intended 0.80 --"
            )
        )
        XCTAssertTrue(
            board.text.contains(
                "-- symbol-forms summary: tokens 1/1, exactText 1/1, "
                    + "mean word-accuracy vs intended 1.00 --"
            )
        )
    }
}
