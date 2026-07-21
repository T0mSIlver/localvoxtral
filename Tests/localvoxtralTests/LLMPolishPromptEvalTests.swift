import Foundation
import XCTest

@testable import localvoxtral

/// Eval harness for the DEFAULT LLM polishing prompt against a live
/// chat/completions server. It builds requests exactly the way
/// `DictationViewModel+Session` does — bundled default templates through
/// `AppConfigStore`, `renderedUserPrompts`, the production
/// `LLMPolishingService` — and scores a table of tricky punctuation-spacing
/// sentences the prompt must fix (French: one space before ?, !, :, ; —
/// English: none). Voxtral sometimes emits the wrong convention; the polish
/// pass is the fix, and this suite is the regression net for the prompt.
/// The corpus + scorer live in `LLMPolishEvalSupport`, shared with
/// `PolishHelperIntegrationTests` so the bundled engine is held to the
/// same baseline.
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
/// Default endpoint is the build-host eval service `com.localvoxtral.testpolishd`
/// (the bundled polishd helper on port 8080, owner runbook:
/// scripts/mac/README.md); the app-managed instance on 8472 works too while the
/// app is running with polishing on.
@MainActor
final class LLMPolishPromptEvalTests: XCTestCase {
    private static let enableEnv = "LLM_POLISH_EVAL_ENABLE"
    private static let endpointEnv = "LLM_POLISH_EVAL_ENDPOINT"
    private static let modelEnv = "LLM_POLISH_EVAL_MODEL"
    private static let requestShapeModelEnv = "LLM_POLISH_EVAL_REQUEST_SHAPE_MODEL"
    private static let thinkingBudgetTokensEnv = "LLM_POLISH_EVAL_THINKING_BUDGET_TOKENS"
    private static let passthroughExtraParametersEnv = "LLM_POLISH_EVAL_PASSTHROUGH_EXTRA_PARAMS"
    private static let apiKeyEnv = "LLM_POLISH_EVAL_API_KEY"
    private static let markerFileName = ".llm-polish-eval-enable.json"
    private static let defaultEndpoint = "http://127.0.0.1:8080/v1/chat/completions"

    private struct MarkerConfig: Decodable {
        let endpoint: String?
        let model: String?
        let requestShapeModel: String?
        let useDefaultRequestShape: Bool?
        let thinkingBudgetTokens: Int?
        let passthroughExtraParameters: Bool?
        let apiKey: String?
    }

    private func evalConfiguration() throws -> LLMPolishingConfiguration {
        let env = ProcessInfo.processInfo.environment
        var endpointString: String?
        var model: String?
        var requestShapeModel: String?
        var useDefaultRequestShape = false
        var thinkingBudgetTokens: Int?
        var passthroughExtraParameters = false
        var apiKey: String?

        if env[Self.enableEnv] == "1" {
            endpointString = env[Self.endpointEnv]
            model = env[Self.modelEnv]
            requestShapeModel = env[Self.requestShapeModelEnv]
            thinkingBudgetTokens = env[Self.thinkingBudgetTokensEnv].flatMap(Int.init)
            passthroughExtraParameters = env[Self.passthroughExtraParametersEnv] == "1"
            apiKey = env[Self.apiKeyEnv]
        } else if let marker = try loadMarkerConfig() {
            endpointString = marker.endpoint
            model = marker.model
            requestShapeModel = marker.requestShapeModel
            useDefaultRequestShape = marker.useDefaultRequestShape == true
            thinkingBudgetTokens = marker.thinkingBudgetTokens
            passthroughExtraParameters = marker.passthroughExtraParameters == true
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

        // Catalog-aware: the resolved model's catalog sampling defaults and
        // chat-template kwargs ride along, exactly like the managed
        // production configuration (pinned by
        // `LLMPolishEvalSupportTests.testEvalConfigurationCarriesCatalogRequestShape`).
        let resolvedRequestShapeModel = requestShapeModel?.isEmpty == false
            ? requestShapeModel
            : (useDefaultRequestShape ? PolishModelCatalog.defaultOption.repoID : nil)
        return LLMPolishEvalSupport.configuration(
            endpointURL: endpointURL,
            apiKey: apiKey ?? "",
            model: model?.isEmpty == false ? model! : SettingsStore.defaultLLMPolishingModel,
            requestShapeModel: resolvedRequestShapeModel,
            thinkingBudgetTokens: thinkingBudgetTokens,
            passthroughExtraParameters: passthroughExtraParameters
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

    func testDefaultPromptFixesPunctuationSpacing() async throws {
        let configuration = try evalConfiguration()
        let (templates, cleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        addTeardownBlock { cleanup() }
        let service = LLMPolishingService()

        let result = await LLMPolishEvalSupport.runScoreboard(
            service: service,
            templates: templates,
            configuration: configuration
        )
        LLMPolishEvalSupport.printScoreboard(
            result,
            configuration: configuration,
            header: "LLM polish prompt eval"
        )

        XCTAssertTrue(
            result.failedRequiredCases.isEmpty,
            "Default polish prompt regressed on required punctuation-spacing cases: \(result.failedRequiredCases.joined(separator: ", "))"
        )
    }

    /// Scores the bundled AGENT-profile prompt against the same live server:
    /// spoken-symbol normalization, backticking, filler/self-correction
    /// cleanup — while never expanding the dictated prompt. Required agent
    /// cases are asserted; the rest are tracked as known-hard.
    func testAgentPromptProfileScoreboard() async throws {
        let configuration = try evalConfiguration()
        let (templates, cleanup) = try LLMPolishEvalSupport.agentPromptTemplates()
        addTeardownBlock { cleanup() }
        let service = LLMPolishingService()

        let result = await LLMPolishEvalSupport.runScoreboard(
            service: service,
            templates: templates,
            configuration: configuration,
            requiredCases: LLMPolishEvalSupport.agentRequiredCases,
            knownHardCases: LLMPolishEvalSupport.agentKnownHardCases,
            technicalCases: []
        )
        LLMPolishEvalSupport.printScoreboard(
            result,
            configuration: configuration,
            header: "LLM polish AGENT-profile eval"
        )

        XCTAssertTrue(
            result.failedRequiredCases.isEmpty,
            "Agent polish prompt regressed on required agent cases: \(result.failedRequiredCases.joined(separator: ", "))"
        )
    }
}
