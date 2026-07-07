import Foundation
import XCTest

@testable import localvoxtral

/// The polish-prompt eval corpus + scoring, shared verbatim between
/// `LLMPolishPromptEvalTests` (scores a live chat/completions endpoint,
/// enabled via remote-build.sh eval-llm) and `PolishHelperIntegrationTests`
/// (scores the bundled localvoxtral-polishd helper it spawns itself). One
/// corpus, one scorer — an engine swap that changes polish behavior must
/// show up as the same required-case failures in both suites.
struct LLMPolishEvalCase {
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

enum LLMPolishEvalSupport {
    /// Guard against the polisher rewriting instead of cleaning: letters/
    /// digits-only word accuracy between input and output must stay high.
    static let requiredWordAccuracy = 0.7

    /// Sentences the pinned default model fixed in EVERY server state
    /// observed on 2026-07-06: a warm app-managed instance, a fresh
    /// com.localvoxtral.mlxlm service, and that service in a later state.
    /// mlx_lm.server answers identically for identical requests within one
    /// server state, but a handful of borderline cases were seen flipping
    /// deterministically BETWEEN states (suspected prompt-cache influence
    /// on logits — see the stale-cache issue on the mlx-lm fork), so only
    /// cases stable across all states qualify as required. Every one of
    /// these MUST pass; a failure means the default prompt (or the model
    /// pin, or the engine) regressed. Comparison is done on normalized
    /// text (narrow no-break and no-break spaces unified to a plain space,
    /// runs of spaces collapsed, lowercased), so a typographically correct
    /// French narrow no-break space counts as the required space.
    static let requiredCases: [LLMPolishEvalCase] = [
        // French — space before ":" must be inserted when missing.
        LLMPolishEvalCase(
            id: "fr-colon-missing-space",
            input: "Voici le plan: on commence demain matin.",
            expectedText: "Voici le plan : on commence demain matin."
        ),
        // French — already correct, must be preserved (no over-correction).
        LLMPolishEvalCase(
            id: "fr-already-correct",
            input: "Où est la gare ?",
            expectedText: "Où est la gare ?"
        ),
        // English — stray space before punctuation must be removed.
        LLMPolishEvalCase(
            id: "en-question-extra-space",
            input: "Are you coming to the meeting tomorrow ?",
            expectedText: "Are you coming to the meeting tomorrow?"
        ),
        LLMPolishEvalCase(
            id: "en-comma-extra-space",
            input: "Well , I think we should try again.",
            expectedText: "Well, I think we should try again."
        ),
        LLMPolishEvalCase(
            id: "en-accented-word-question",
            input: "Did you enjoy the café ?",
            expectedText: "Did you enjoy the café?"
        ),
        LLMPolishEvalCase(
            id: "en-multi-questions",
            input: "Is it ready ? Can we ship it ?",
            expectedText: "Is it ready? Can we ship it?"
        ),
        // English — already correct, must be preserved.
        LLMPolishEvalCase(
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
    /// Tracked and printed but NOT asserted, so the suites stay
    /// deterministic-green while these serve as the acceptance list for a
    /// future fine-tune or model-pin bump: promote one to `requiredCases`
    /// only after it passes across server restarts and prompt-cache
    /// configurations.
    static let knownHardCases: [LLMPolishEvalCase] = [
        LLMPolishEvalCase(
            id: "fr-question-missing-space",
            input: "Tu viens demain?",
            mustContain: ["demain ?"],
            mustNotContain: ["demain?"]
        ),
        LLMPolishEvalCase(
            id: "en-exclamation-extra-space",
            input: "That demo was really impressive !",
            mustContain: ["impressive!"],
            mustNotContain: ["impressive !"]
        ),
        LLMPolishEvalCase(
            id: "fr-exclamation-missing-space",
            input: "C'est vraiment génial!",
            mustContain: ["génial !"],
            mustNotContain: ["génial!"]
        ),
        LLMPolishEvalCase(
            id: "fr-semicolon-missing-space",
            input: "Il pleut beaucoup; on reste à la maison.",
            mustContain: ["beaucoup ;"],
            mustNotContain: ["beaucoup;"]
        ),
        LLMPolishEvalCase(
            id: "fr-multi-sentence",
            input: "Quelle heure est-il? Il est déjà tard!",
            mustContain: ["est-il ?", "tard !"],
            mustNotContain: ["est-il?", "tard!"]
        ),
        LLMPolishEvalCase(
            id: "fr-proper-noun-question",
            input: "As-tu déjà testé localvoxtral?",
            mustContain: ["localvoxtral ?"],
            mustNotContain: ["localvoxtral?"]
        ),
        LLMPolishEvalCase(
            id: "en-colon-extra-space",
            input: "Here is the plan : we ship the fix tomorrow.",
            mustContain: ["plan:"],
            mustNotContain: ["plan :"]
        ),
    ]

    /// The bundled default templates, loaded through the production config
    /// path (a fresh override directory gets seeded with the bundled files).
    /// The caller owns cleanup of the returned directory.
    static func defaultPromptTemplates() throws -> (LLMPromptTemplates, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-polish-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let templates = AppConfigStore(configDirectoryOverride: directory).loadLLMPromptTemplates()
        return (templates, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Unifies the space variants a correct French typography can use
    /// (U+202F narrow no-break, U+00A0 no-break) with a plain space,
    /// collapses runs, and lowercases, so assertions accept any of them.
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .lowercased()
    }

    static func runCase(
        _ evalCase: LLMPolishEvalCase,
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
                if wordAccuracy < requiredWordAccuracy {
                    caseFailures.append(
                        "word accuracy \(String(format: "%.2f", wordAccuracy)) < \(requiredWordAccuracy) (rewrote the text)"
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

    struct ScoreboardResult {
        var lines: [String] = []
        var failedRequiredCases: [String] = []
        var passingHardCases: [String] = []
    }

    /// Runs the full corpus and returns the printable scoreboard plus the
    /// required-case failures the caller must assert on.
    static func runScoreboard(
        service: LLMPolishingService,
        templates: LLMPromptTemplates,
        configuration: LLMPolishingConfiguration
    ) async -> ScoreboardResult {
        var result = ScoreboardResult()

        for evalCase in requiredCases {
            let (failures, output) = await runCase(
                evalCase, service: service, templates: templates, configuration: configuration
            )
            if failures.isEmpty {
                result.lines.append("PASS \(evalCase.id)")
            } else {
                result.lines.append(
                    "FAIL \(evalCase.id): \(failures.joined(separator: "; ")) — output: \(output)"
                )
                result.failedRequiredCases.append(evalCase.id)
            }
        }

        for evalCase in knownHardCases {
            let (failures, output) = await runCase(
                evalCase, service: service, templates: templates, configuration: configuration
            )
            if failures.isEmpty {
                result.lines.append(
                    "PASS \(evalCase.id) (known-hard — promote only if stable across server restarts)"
                )
                result.passingHardCases.append(evalCase.id)
            } else {
                result.lines.append("XFAIL \(evalCase.id) (known-hard) — output: \(output)")
            }
        }

        return result
    }

    static func printScoreboard(
        _ result: ScoreboardResult,
        configuration: LLMPolishingConfiguration,
        header: String
    ) {
        print(
            """
            == \(header) (model: \(configuration.model), endpoint: \(configuration.endpointURL)) ==
            \(result.lines.joined(separator: "\n"))
            == required: \(requiredCases.count - result.failedRequiredCases.count)/\(requiredCases.count), \
            known-hard passing: \(result.passingHardCases.count)/\(knownHardCases.count) ==
            """
        )
    }
}
