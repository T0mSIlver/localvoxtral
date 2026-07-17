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
    /// Technical fidelity cases must score identifier and acronym casing.
    /// Existing punctuation-spacing cases keep case-insensitive scoring.
    let caseSensitive: Bool

    init(
        id: String,
        input: String,
        expectedText: String? = nil,
        mustContain: [String] = [],
        mustNotContain: [String] = [],
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.input = input
        self.expectedText = expectedText
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.caseSensitive = caseSensitive
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

    /// Cases the original 0.8B default could not do reliably (the 4B default
    /// since 2026-07-11 passes many of them — promotion still requires
    /// stability across TWO server states, see below). Two flavors:
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
        // Token protection: a CLI flag must survive the punctuation cleanup
        // byte-exact — the model must not fold "--force" into an en/single dash
        // (needles are normalized/lowercased, matching the scorer).
        LLMPolishEvalCase(
            id: "en-flag-survives-cleanup",
            input: "run the deploy script with --force , then check the logs .",
            mustContain: ["--force"],
            mustNotContain: ["– force", "- force"]
        ),
        // A filesystem path must keep its slashes and case-fold-sensitive
        // segments (compared against the lowercased output, so the needle is
        // the lowercased path).
        LLMPolishEvalCase(
            id: "en-path-survives-cleanup",
            input: "open the file src/auth/useAuth.ts and fix the the import .",
            mustContain: ["src/auth/useauth.ts"]
        ),
        // A backtick-delimited command must survive with its backticks intact.
        LLMPolishEvalCase(
            id: "en-backtick-command-survives",
            input: "then run `git rebase -i` to squash the commits .",
            mustContain: ["`git rebase -i`"]
        ),
    ]

    /// Print-only technical-dictation cases for model differentiation.
    /// These intentionally do NOT gate CI while the pinned small default
    /// models are expected to miss identifier, command, and markdown
    /// transforms; the same two-server-state rule gates any promotion.
    static let technicalCases: [LLMPolishEvalCase] = [
        // Filename + SwiftUI lifecycle identifier spoken as natural words.
        LLMPolishEvalCase(
            id: "tech-filename-swift-onappear",
            input: "open settings view dot swift and check the on appear handler",
            expectedText: "Open SettingsView.swift and check the onAppear handler.",
            caseSensitive: true
        ),
        // Common package filename plus backend acronyms that should be cased.
        LLMPolishEvalCase(
            id: "tech-filename-json-api-url",
            input: "update package dot json so the api url uses https",
            expectedText: "Update package.json so the API URL uses HTTPS.",
            caseSensitive: true
        ),
        // camelCase rename target assembled from dictated words.
        LLMPolishEvalCase(
            id: "tech-camelcase-rename",
            input: "rename fetch user profile to fetch user profile async",
            expectedText: "Rename fetchUserProfile to fetchUserProfileAsync.",
            caseSensitive: true
        ),
        // PascalCase type name from a natural class description.
        LLMPolishEvalCase(
            id: "tech-pascalcase-class",
            input: "create a user session manager class in swift",
            expectedText: "Create a UserSessionManager class in Swift.",
            caseSensitive: true
        ),
        // snake_case fields from explicit underscore dictation.
        LLMPolishEvalCase(
            id: "tech-snake-case-fields",
            input: "store user underscore id and access token in the json payload",
            expectedText: "Store user_id and access_token in the JSON payload.",
            caseSensitive: true
        ),
        // Git commit command, short flag, and quoted message.
        LLMPolishEvalCase(
            id: "tech-cli-git-commit",
            input: "run git commit dash m quote fix login race quote",
            expectedText: "Run `git commit -m \"fix login race\"`.",
            caseSensitive: true
        ),
        // npm long flag with repeated dash dictation.
        LLMPolishEvalCase(
            id: "tech-cli-npm-save-dev",
            input: "run npm install dash dash save dev vitest",
            expectedText: "Run `npm install --save-dev vitest`.",
            caseSensitive: true
        ),
        // Test command with a long flag and PascalCase test target.
        LLMPolishEvalCase(
            id: "tech-cli-filter-target",
            input: "run pnpm test dash dash filter auth service",
            expectedText: "Run `pnpm test --filter AuthService`.",
            caseSensitive: true
        ),
        // Markdown heading dictated structurally, not as literal hashes.
        LLMPolishEvalCase(
            id: "tech-markdown-heading",
            input: "write a markdown heading level two known issues",
            expectedText: "## Known issues",
            caseSensitive: true
        ),
        // Markdown checklist-style bullets from repeated todo words.
        LLMPolishEvalCase(
            id: "tech-markdown-todo-bullets",
            input: "add bullets todo write tests todo update read me",
            expectedText: "- TODO: Write tests\n- TODO: Update README",
            caseSensitive: true
        ),
        // Inline Swift control-flow terms and a code-ish property name.
        LLMPolishEvalCase(
            id: "tech-inline-do-catch",
            input: "wrap it in a do catch block and log the localized description",
            expectedText: "Wrap it in a `do`/`catch` block and log the localizedDescription.",
            caseSensitive: true
        ),
        // Inline Swift guard pattern with braces inferred from dictation.
        LLMPolishEvalCase(
            id: "tech-inline-guard-self",
            input: "use guard let self else return before awaiting the task",
            expectedText: "Use `guard let self else { return }` before awaiting the task.",
            caseSensitive: true
        ),
        // Platform and tooling jargon with mixed casing.
        LLMPolishEvalCase(
            id: "tech-acronyms-ios-xcode-github",
            input: "the ios build fails in xcode when github actions sets the sdk root",
            expectedText: "The iOS build fails in Xcode when GitHub Actions sets the SDKROOT.",
            caseSensitive: true
        ),
        // Already-correct camelCase must not be expanded or title-cased.
        LLMPolishEvalCase(
            id: "tech-preserve-camelcase",
            input: "Keep fetchUserProfile as fetchUserProfile.",
            expectedText: "Keep fetchUserProfile as fetchUserProfile.",
            caseSensitive: true
        ),
        // Already-correct mixed-case identifiers must be left untouched.
        LLMPolishEvalCase(
            id: "tech-preserve-mixed-identifiers",
            input: "Do not change URLSessionConfiguration or apiClient.",
            expectedText: "Do not change URLSessionConfiguration or apiClient.",
            caseSensitive: true
        ),
        // French technical sentence with filename, onAppear, API, and colon typography.
        LLMPolishEvalCase(
            id: "tech-fr-swift-api-colon",
            input: "corrige settings view dot swift: le modifier on appear appelle l api trop tôt",
            expectedText: "Corrige SettingsView.swift : le modifier onAppear appelle l'API trop tôt.",
            caseSensitive: true
        ),
        // French command sentence with CLI flag, package name, and Xcode casing.
        LLMPolishEvalCase(
            id: "tech-fr-cli-xcode",
            input: "lance npm install dash dash save dev vitest puis relance xcode",
            expectedText: "Lance `npm install --save-dev vitest`, puis relance Xcode.",
            caseSensitive: true
        ),
    ]

    /// Eval-lane configuration builder: mirrors how production builds the
    /// managed configuration for a model (`SettingsStore
    /// .llmPolishingConfiguration`) — a catalog model carries its catalog
    /// sampling defaults AND chat-template kwargs. Without this the 4B
    /// default would be evaluated with its template's thinking mode ON while
    /// the shipped request disables it (`enable_thinking: false`), so the
    /// eval would score a request shape production never sends.
    static func configuration(
        endpointURL: URL,
        apiKey: String,
        model: String,
        requestShapeModel: String? = nil,
        thinkingBudgetTokens: Int? = nil,
        passthroughExtraParameters: Bool = false
    ) -> LLMPolishingConfiguration {
        let option = PolishModelCatalog.option(forRepoID: requestShapeModel ?? model)
        return LLMPolishingConfiguration(
            endpointURL: endpointURL,
            apiKey: apiKey,
            model: model,
            samplingDefaults: option?.samplingDefaults,
            chatTemplateArguments: option?.chatTemplateArguments,
            thinkingBudgetTokens: thinkingBudgetTokens,
            passthroughExtraParameters: passthroughExtraParameters
        )
    }

    // MARK: - Agent-profile corpus

    /// Required agent-profile cases — asserted in BOTH eval suites, so kept
    /// minimal and safe. The most important agent guarantee is a FIDELITY one:
    /// the dictated text is a prompt for another AI and the small model must
    /// NEVER answer, expand, or restyle it. `agent-flag-spoken` started here
    /// too but was DEMOTED to `agentKnownHardCases` (2026-07-09): the pinned
    /// 0.8B echoes the input verbatim on the agent prompt and does not
    /// normalize the spoken flag (`--force`), so spoken-symbol normalization
    /// is aspirational at this model size — see the demotion note below.
    static let agentRequiredCases: [LLMPolishEvalCase] = [
        // The model must leave a terse instruction untouched — never answer or
        // expand it, and no gratuitous backticking of prose words (whole-string
        // equality rejects "`auth`" and any prepended/appended commentary).
        LLMPolishEvalCase(
            id: "agent-no-expansion",
            input: "fix the bug in the auth module",
            expectedText: "fix the bug in the auth module"
        ),
    ]

    /// Agent-profile duties the pinned 0.8B does not do reliably: tracked and
    /// printed, never asserted (same contract as `knownHardCases`). Inputs are
    /// sized so a CORRECT answer clears the `requiredWordAccuracy` floor
    /// (spoken->written normalization changes token counts, so several were
    /// lengthened with shared context vs the terse originals).
    static let agentKnownHardCases: [LLMPolishEvalCase] = [
        // DEMOTED from agentRequiredCases (2026-07-09): the pinned 0.8B leaves
        // "dash dash force" verbatim on the agent prompt instead of writing
        // "--force". Spoken-flag normalization is a known-hard aspiration at
        // this model size; promote back to required only after a model-pin bump
        // does it reliably across server restarts.
        LLMPolishEvalCase(
            id: "agent-flag-spoken",
            input: "run it with dash dash force please",
            mustContain: ["--force"],
            mustNotContain: ["dash dash"]
        ),
        // "dot <word>" as a file reference -> ".<word>".
        LLMPolishEvalCase(
            id: "agent-dotfile-spoken",
            input: "add that to the dot env file",
            mustContain: [".env"]
        ),
        // Spoken port number -> digits.
        LLMPolishEvalCase(
            id: "agent-port-number",
            input: "start the dev server on port eighty eighty please",
            mustContain: ["8080"]
        ),
        // "slash" between path words -> "/". Shortened vs a fully spelled-out
        // filename so a correct collapse still clears the word-accuracy floor.
        LLMPolishEvalCase(
            id: "agent-path-spoken",
            input: "look in src slash auth for the bug",
            mustContain: ["src/auth"]
        ),
        // Filler removal ("um"), keeping the discourse "so".
        LLMPolishEvalCase(
            id: "agent-filler-removal",
            input: "um so we need to retry the connection now",
            mustContain: ["retry the connection"],
            mustNotContain: ["um "]
        ),
        // Self-correction resolved to the final intent. Lengthened with shared
        // context so removing "three retries actually no" stays above the floor.
        LLMPolishEvalCase(
            id: "agent-self-correction",
            input: "when you set up the retry logic use three retries actually no five retries for the connection",
            mustContain: ["five retries"],
            mustNotContain: ["three retries"]
        ),
        // Explicit enumeration -> markdown numbered list (loose: list style
        // varies, so only content needles plus one structure needle).
        LLMPolishEvalCase(
            id: "agent-list-structuring",
            input: "first fix the failing test second update the docs third ship it",
            mustContain: ["fix the failing test", "update the docs", "2."]
        ),
        // French prompt, spoken flag -> written flag.
        LLMPolishEvalCase(
            id: "agent-fr-flag",
            input: "lance le script avec dash dash verbose",
            mustContain: ["--verbose"]
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

    /// The bundled AGENT-profile templates, loaded through the production
    /// config path (fresh override directory seeded with the bundled files,
    /// then `loadLLMPromptTemplates(profile: .agent)`). Caller owns cleanup.
    static func agentPromptTemplates() throws -> (LLMPromptTemplates, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-polish-eval-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let templates = AppConfigStore(configDirectoryOverride: directory)
            .loadLLMPromptTemplates(profile: .agent)
        return (templates, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Unifies the space variants a correct French typography can use
    /// (U+202F narrow no-break, U+00A0 no-break) with a plain space,
    /// collapses runs, and lowercases, so assertions accept any of them.
    static func normalized(_ text: String) -> String {
        normalizedSpacing(text)
            .lowercased()
    }

    static func normalizedSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    static func runCase(
        _ evalCase: LLMPolishEvalCase,
        service: any LLMPolishingServicing,
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
            let output = evalCase.caseSensitive
                ? normalizedSpacing(result.polishedText)
                : normalized(result.polishedText)

            if let expectedText = evalCase.expectedText {
                // Whole-output equality: substring needles would false-pass
                // outputs with prepended labels ("Corrected: …") or trailing
                // commentary that the prompt forbids.
                let expected = evalCase.caseSensitive
                    ? normalizedSpacing(expectedText)
                    : normalized(expectedText)
                if output != expected {
                    let expectedForLog = expectedText.replacingOccurrences(of: "\n", with: "\\n")
                    caseFailures.append("expected \"\(expectedForLog)\"")
                }
            } else {
                for needle in evalCase.mustContain
                where !output.contains(
                    evalCase.caseSensitive ? normalizedSpacing(needle) : normalized(needle)
                ) {
                    caseFailures.append("missing \"\(needle)\"")
                }
                for needle in evalCase.mustNotContain
                where output.contains(
                    evalCase.caseSensitive ? normalizedSpacing(needle) : normalized(needle)
                ) {
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
        var passingTechnicalCases: [String] = []
        var requiredCaseCount = 0
        var knownHardCaseCount = 0
        var technicalCaseCount = 0
    }

    /// Runs a corpus and returns the printable scoreboard plus the
    /// required-case failures the caller must assert on. Defaults to the
    /// standard corpus; pass `requiredCases:`/`knownHardCases:` (e.g. the
    /// `agent*` arrays) to score the agent-profile corpus instead.
    static func runScoreboard(
        service: any LLMPolishingServicing,
        templates: LLMPromptTemplates,
        configuration: LLMPolishingConfiguration,
        requiredCases: [LLMPolishEvalCase] = LLMPolishEvalSupport.requiredCases,
        knownHardCases: [LLMPolishEvalCase] = LLMPolishEvalSupport.knownHardCases,
        technicalCases: [LLMPolishEvalCase] = LLMPolishEvalSupport.technicalCases
    ) async -> ScoreboardResult {
        var result = ScoreboardResult()
        result.requiredCaseCount = requiredCases.count
        result.knownHardCaseCount = knownHardCases.count
        result.technicalCaseCount = technicalCases.count

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

        for evalCase in technicalCases {
            let (failures, output) = await runCase(
                evalCase, service: service, templates: templates, configuration: configuration
            )
            if failures.isEmpty {
                result.lines.append("PASS \(evalCase.id) (technical)")
                result.passingTechnicalCases.append(evalCase.id)
            } else {
                result.lines.append("XFAIL \(evalCase.id) (technical) — output: \(output)")
            }
        }

        return result
    }

    static func printScoreboard(
        _ result: ScoreboardResult,
        configuration: LLMPolishingConfiguration,
        header: String
    ) {
        let technicalLine =
            result.technicalCaseCount > 0
            ? "\n== technical: \(result.passingTechnicalCases.count)/\(result.technicalCaseCount) =="
            : ""
        print(
            """
            == \(header) (model: \(configuration.model), endpoint: \(configuration.endpointURL)) ==
            \(result.lines.joined(separator: "\n"))
            == required: \(result.requiredCaseCount - result.failedRequiredCases.count)/\(result.requiredCaseCount), \
            known-hard passing: \(result.passingHardCases.count)/\(result.knownHardCaseCount) ==\(technicalLine)
            """
        )
    }
}
