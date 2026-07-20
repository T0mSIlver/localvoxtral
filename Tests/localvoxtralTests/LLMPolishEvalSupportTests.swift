import Foundation
import XCTest

@testable import localvoxtral

@MainActor
final class LLMPolishEvalSupportTests: XCTestCase {
    /// The eval lanes must score the request shape production actually
    /// sends: a catalog model's eval configuration carries the catalog's
    /// sampling defaults and chat-template kwargs (for the 4B default that
    /// is `enable_thinking: false` — evaluating it with thinking ON would
    /// score a request production never sends and emit reasoning transcripts
    /// that blow the request timeout, #99).
    func testEvalConfigurationCarriesCatalogRequestShape() throws {
        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1/chat/completions"))
        let defaultModel = SettingsStore.defaultLLMPolishingModel
        let catalogOption = try XCTUnwrap(PolishModelCatalog.option(forRepoID: defaultModel))

        let configuration = LLMPolishEvalSupport.configuration(
            endpointURL: endpointURL,
            apiKey: "key",
            model: defaultModel
        )

        XCTAssertEqual(configuration.endpointURL, endpointURL)
        XCTAssertEqual(configuration.apiKey, "key")
        XCTAssertEqual(configuration.model, defaultModel)
        XCTAssertEqual(configuration.samplingDefaults, catalogOption.samplingDefaults)
        XCTAssertEqual(configuration.chatTemplateArguments, catalogOption.chatTemplateArguments)
        // The default is the 4B, whose shipped request shape disables
        // thinking — the eval lane must send exactly that.
        XCTAssertEqual(configuration.chatTemplateArguments, ["enable_thinking": false])
    }

    /// A non-catalog (custom) model keeps the legacy request shape: no
    /// sampling overrides, no template kwargs — same as production's managed
    /// path for a custom repo.
    func testEvalConfigurationLeavesNonCatalogModelsUntouched() throws {
        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1/chat/completions"))

        let configuration = LLMPolishEvalSupport.configuration(
            endpointURL: endpointURL,
            apiKey: "",
            model: "example/custom-polisher"
        )

        XCTAssertNil(configuration.samplingDefaults)
        XCTAssertNil(configuration.chatTemplateArguments)
    }

    /// OpenAI-compatible gateways commonly expose a short alias rather than
    /// the catalog repo ID. The alias must be sent as `model`, while an
    /// explicit request-shape model still supplies production's deterministic
    /// Qwen sampling and thinking-mode fields.
    func testEvalConfigurationCanApplyCatalogShapeToExternalAlias() throws {
        let endpointURL = try XCTUnwrap(URL(string: "http://gpu:8080/v1/chat/completions"))
        let production = PolishModelCatalog.defaultOption
        let configuration = LLMPolishEvalSupport.configuration(
            endpointURL: endpointURL,
            apiKey: "",
            model: "qwen35-4b",
            requestShapeModel: production.repoID,
            thinkingBudgetTokens: 0,
            passthroughExtraParameters: true
        )

        XCTAssertEqual(configuration.model, "qwen35-4b")
        XCTAssertEqual(configuration.samplingDefaults, production.samplingDefaults)
        XCTAssertEqual(configuration.chatTemplateArguments, ["enable_thinking": false])
        XCTAssertEqual(configuration.thinkingBudgetTokens, 0)
        XCTAssertTrue(configuration.passthroughExtraParameters)
    }
}
