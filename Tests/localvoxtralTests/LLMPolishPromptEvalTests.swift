import Foundation
import XCTest
@testable import localvoxtral

/// Eval harness for the DEFAULT LLM polishing prompt against a live mlx-lm
/// (or any chat/completions) server. It builds requests exactly the way
/// `DictationViewModel+Session` does — bundled default templates through
/// `AppConfigStore`, `renderedUserPrompts`, the production
/// `LLMPolishingService` — and scores a table of tricky punctuation-spacing
/// sentences the prompt must fix (French: one space before ?, !, :, ; —
/// English: none). Voxtral sometimes emits the wrong convention; the polish
/// pass is the fix, and this suite is the regression net for the prompt.
///
/// Enablement (both channels result in the same configuration):
/// - env: LLM_POLISH_EVAL_ENABLE=1, optional LLM_POLISH_EVAL_ENDPOINT /
///   LLM_POLISH_EVAL_MODEL / LLM_POLISH_EVAL_API_KEY
/// - marker file `.llm-polish-eval-enable.json` at the repo root, written by
///   `./scripts/remote-build.sh eval-llm [endpoint]` before rsync. The build
///   gate only allowlists exact `swift test ...` payloads (env prefixes are
///   pinned per-command), so from the Linux box the enablement has to travel
///   inside the synced tree instead of the SSH command line.
///
/// Default endpoint is the build-host eval service `com.localvoxtral.mlxlm`
/// (port 8080, owner runbook: scripts/mac/README.md); the app-managed
/// instance on 8472 works too while the app is running with polishing on.
@MainActor
final class LLMPolishPromptEvalTests: XCTestCase {
    private static let enableEnv = "LLM_POLISH_EVAL_ENABLE"
    private static let endpointEnv = "LLM_POLISH_EVAL_ENDPOINT"
    private static let modelEnv = "LLM_POLISH_EVAL_MODEL"
    private static let apiKeyEnv = "LLM_POLISH_EVAL_API_KEY"
    private static let markerFileName = ".llm-polish-eval-enable.json"
    private static let defaultEndpoint = "http://127.0.0.1:8080/v1/chat/completions"

    /// Guard against the polisher rewriting instead of cleaning: letters/
    /// digits-only word accuracy between input and output must stay high.
    private static let requiredWordAccuracy = 0.7

    private struct EvalCase {
        let id: String
        let input: String
        /// Full expected output, compared by normalized whole-string
        /// equality. Set on required cases — their outputs are
        /// deterministic, and equality (unlike substring needles) also
        /// rejects prepended labels like "Corrected: …" that the prompt
        /// forbids. Nil on known-hard cases, which use the needles below.
        let expectedText: String?
        /// Substrings that must appear in the normalized output.
        let mustContain: [String]
        /// Substrings that must NOT appear in the normalized output.
        let mustNotContain: [String]

        init(
            id: String,
            input: String,
            expectedText: String? = nil,
            mustContain: [String] = [],
            mustNotContain: [String] = []
        ) {
            self.id = id
            self.input = input
            self.expectedText = expectedText
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
        }
    }

    /// Sentences the pinned default model fixed in EVERY server state
    /// observed on 2026-07-06: a warm app-managed instance, a fresh
    /// com.localvoxtral.mlxlm service, and that service in a later state.
    /// mlx_lm.server answers identically for identical requests within one
    /// server state, but a handful of borderline cases were seen flipping
    /// deterministically BETWEEN states (suspected prompt-cache influence
    /// on logits — see the stale-cache issue on the mlx-lm fork), so only
    /// cases stable across all states qualify as required. Every one of
    /// these MUST pass; a failure means the default prompt (or the model
    /// pin, or the server) regressed. Comparison is done on normalized
    /// text (narrow no-break and no-break spaces unified to a plain space,
    /// runs of spaces collapsed, lowercased), so a typographically correct
    /// French narrow no-break space counts as the required space.
    private static let requiredCases: [EvalCase] = [
        // French — space before ":" must be inserted when missing.
        EvalCase(
            id: "fr-colon-missing-space",
            input: "Voici le plan: on commence demain matin.",
            expectedText: "Voici le plan : on commence demain matin."
        ),
        // French — already correct, must be preserved (no over-correction).
        EvalCase(
            id: "fr-already-correct",
            input: "Où est la gare ?",
            expectedText: "Où est la gare ?"
        ),
        // English — stray space before punctuation must be removed.
        EvalCase(
            id: "en-question-extra-space",
            input: "Are you coming to the meeting tomorrow ?",
            expectedText: "Are you coming to the meeting tomorrow?"
        ),
        EvalCase(
            id: "en-comma-extra-space",
            input: "Well , I think we should try again.",
            expectedText: "Well, I think we should try again."
        ),
        EvalCase(
            id: "en-accented-word-question",
            input: "Did you enjoy the café ?",
            expectedText: "Did you enjoy the café?"
        ),
        EvalCase(
            id: "en-multi-questions",
            input: "Is it ready ? Can we ship it ?",
            expectedText: "Is it ready? Can we ship it?"
        ),
        // English — already correct, must be preserved.
        EvalCase(
            id: "en-already-correct",
            input: "What time is it? It is already late!",
            expectedText: "What time is it? It is already late!"
        ),
    ]

    /// Cases the pinned 0.8B model cannot do reliably. Two flavors:
    /// never-pass cases (a probe battery showed the model cannot even
    /// perceive the error — it answers "the spacing is correct" when asked
    /// yes/no with the rule stated in the question) and state-dependent
    /// wobblers that flip between server states (see `requiredCases` doc).
    /// Tracked and printed but NOT asserted, so the suite stays
    /// deterministic-green while these serve as the acceptance list for a
    /// future fine-tune or model-pin bump: promote one to `requiredCases`
    /// only after it passes across server restarts and prompt-cache
    /// configurations.
    private static let knownHardCases: [EvalCase] = [
        EvalCase(
            id: "fr-question-missing-space",
            input: "Tu viens demain?",
            mustContain: ["demain ?"],
            mustNotContain: ["demain?"]
        ),
        EvalCase(
            id: "en-exclamation-extra-space",
            input: "That demo was really impressive !",
            mustContain: ["impressive!"],
            mustNotContain: ["impressive !"]
        ),
        EvalCase(
            id: "fr-exclamation-missing-space",
            input: "C'est vraiment génial!",
            mustContain: ["génial !"],
            mustNotContain: ["génial!"]
        ),
        EvalCase(
            id: "fr-semicolon-missing-space",
            input: "Il pleut beaucoup; on reste à la maison.",
            mustContain: ["beaucoup ;"],
            mustNotContain: ["beaucoup;"]
        ),
        EvalCase(
            id: "fr-multi-sentence",
            input: "Quelle heure est-il? Il est déjà tard!",
            mustContain: ["est-il ?", "tard !"],
            mustNotContain: ["est-il?", "tard!"]
        ),
        EvalCase(
            id: "fr-proper-noun-question",
            input: "As-tu déjà testé localvoxtral?",
            mustContain: ["localvoxtral ?"],
            mustNotContain: ["localvoxtral?"]
        ),
        EvalCase(
            id: "en-colon-extra-space",
            input: "Here is the plan : we ship the fix tomorrow.",
            mustContain: ["plan:"],
            mustNotContain: ["plan :"]
        ),
    ]

    private struct MarkerConfig: Decodable {
        let endpoint: String?
        let model: String?
        let apiKey: String?
    }

    private func evalConfiguration() throws -> LLMPolishingConfiguration {
        let env = ProcessInfo.processInfo.environment
        var endpointString: String?
        var model: String?
        var apiKey: String?

        if env[Self.enableEnv] == "1" {
            endpointString = env[Self.endpointEnv]
            model = env[Self.modelEnv]
            apiKey = env[Self.apiKeyEnv]
        } else if let marker = try loadMarkerConfig() {
            endpointString = marker.endpoint
            model = marker.model
            apiKey = marker.apiKey
        } else {
            throw XCTSkip(
                """
                LLM polish prompt eval is disabled.
                Enable with \(Self.enableEnv)=1 (optional \(Self.endpointEnv), \
                \(Self.modelEnv), \(Self.apiKeyEnv)) or run \
                ./scripts/remote-build.sh eval-llm [endpoint] from the dev box.
                Default endpoint: \(Self.defaultEndpoint)
                """
            )
        }

        let resolvedEndpoint = endpointString?.isEmpty == false
            ? endpointString!
            : Self.defaultEndpoint
        guard let endpointURL = URL(string: resolvedEndpoint), endpointURL.scheme != nil else {
            throw XCTSkip("Invalid eval endpoint: \(resolvedEndpoint)")
        }

        return LLMPolishingConfiguration(
            endpointURL: endpointURL,
            apiKey: apiKey ?? "",
            model: model?.isEmpty == false ? model! : SettingsStore.defaultLLMPolishingModel
        )
    }

    private func loadMarkerConfig() throws -> MarkerConfig? {
        // #filePath walk-up assumes the SwiftPM source layout
        // (Tests/localvoxtralTests/<file>), which holds for `swift test` and
        // remote-build.sh. Under an Xcode-derived build #filePath can point
        // into DerivedData and the marker would not be found — use the env
        // enablement there instead.
        let markerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // localvoxtralTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: markerURL)
            return try JSONDecoder().decode(MarkerConfig.self, from: data)
        } catch {
            // A corrupt marker means "not properly enabled", not "eval
            // regressed" — skip loudly instead of failing the suite.
            throw XCTSkip("Eval marker \(Self.markerFileName) exists but is unreadable: \(error)")
        }
    }

    /// The bundled default templates, loaded through the production config
    /// path (a fresh override directory gets seeded with the bundled files).
    private func defaultPromptTemplates() throws -> LLMPromptTemplates {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-polish-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return AppConfigStore(configDirectoryOverride: directory).loadLLMPromptTemplates()
    }

    /// Unifies the space variants a correct French typography can use
    /// (U+202F narrow no-break, U+00A0 no-break) with a plain space,
    /// collapses runs, and lowercases, so assertions accept any of them.
    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func runCase(
        _ evalCase: EvalCase,
        service: LLMPolishingService,
        templates: LLMPromptTemplates,
        configuration: LLMPolishingConfiguration
    ) async -> (failures: [String], output: String) {
        let request = LLMPolishingRequest(
            inputText: evalCase.input,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: evalCase.input,
                replacementDictionary: ""
            )
        )

        var caseFailures: [String] = []
        var outputForLog = "<no output>"
        do {
            let result = try await service.polish(request: request, configuration: configuration)
            outputForLog = result.polishedText
            let output = normalized(result.polishedText)

            if let expectedText = evalCase.expectedText {
                // Whole-output equality: substring needles would false-pass
                // outputs with prepended labels ("Corrected: …") or trailing
                // commentary that the prompt forbids.
                if output != normalized(expectedText) {
                    caseFailures.append("expected \"\(expectedText)\"")
                }
            } else {
                for needle in evalCase.mustContain where !output.contains(normalized(needle)) {
                    caseFailures.append("missing \"\(needle)\"")
                }
                for needle in evalCase.mustNotContain where output.contains(normalized(needle)) {
                    caseFailures.append("still contains \"\(needle)\"")
                }

                let wordAccuracy = IntegrationTestSupport.wordAccuracy(
                    expected: evalCase.input,
                    actual: result.polishedText
                )
                if wordAccuracy < Self.requiredWordAccuracy {
                    caseFailures.append(
                        "word accuracy \(String(format: "%.2f", wordAccuracy)) < \(Self.requiredWordAccuracy) (rewrote the text)"
                    )
                }
            }
        } catch {
            caseFailures.append("request failed: \(error.localizedDescription)")
        }

        // Keep each output on one physical line — the model can (and does)
        // emit newlines, and multi-line entries hide the tail of the output
        // when the log is grepped.
        return (caseFailures, outputForLog.replacingOccurrences(of: "\n", with: "\\n"))
    }

    func testDefaultPromptFixesPunctuationSpacing() async throws {
        let configuration = try evalConfiguration()
        let templates = try defaultPromptTemplates()
        let service = LLMPolishingService()

        var scoreboard: [String] = []
        var failedRequiredCases: [String] = []
        var passingHardCases: [String] = []

        for evalCase in Self.requiredCases {
            let (failures, output) = await runCase(
                evalCase, service: service, templates: templates, configuration: configuration
            )
            if failures.isEmpty {
                scoreboard.append("PASS \(evalCase.id)")
            } else {
                scoreboard.append(
                    "FAIL \(evalCase.id): \(failures.joined(separator: "; ")) — output: \(output)"
                )
                failedRequiredCases.append(evalCase.id)
            }
        }

        for evalCase in Self.knownHardCases {
            let (failures, output) = await runCase(
                evalCase, service: service, templates: templates, configuration: configuration
            )
            if failures.isEmpty {
                scoreboard.append(
                    "PASS \(evalCase.id) (known-hard — promote only if stable across server restarts)"
                )
                passingHardCases.append(evalCase.id)
            } else {
                scoreboard.append("XFAIL \(evalCase.id) (known-hard) — output: \(output)")
            }
        }

        print(
            """
            == LLM polish prompt eval (model: \(configuration.model), endpoint: \(configuration.endpointURL)) ==
            \(scoreboard.joined(separator: "\n"))
            == required: \(Self.requiredCases.count - failedRequiredCases.count)/\(Self.requiredCases.count), \
            known-hard passing: \(passingHardCases.count)/\(Self.knownHardCases.count) ==
            """
        )

        XCTAssertTrue(
            failedRequiredCases.isEmpty,
            "Default polish prompt regressed on required punctuation-spacing cases: \(failedRequiredCases.joined(separator: ", "))"
        )
    }
}
