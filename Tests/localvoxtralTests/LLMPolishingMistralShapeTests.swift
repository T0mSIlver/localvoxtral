import Foundation
import XCTest
@testable import localvoxtral

/// Mistral's hosted `/v1/chat/completions` has a CLOSED request schema: a body
/// field it does not name is a 422, not an ignored extra. The OpenAI-compatible
/// shape we send every self-hosted server carries four such fields plus an
/// opt-in header, so Mistral needs its own shape — pinned here field by field,
/// and pinned to stay a strict subset (a field added to the OpenAI shape must
/// not silently leak into the Mistral one).
final class LLMPolishingMistralShapeTests: XCTestCase {
    private let request = LLMPolishingRequest(
        inputText: "hello",
        systemPrompt: "system",
        userPrompts: ["first", "second"]
    )

    /// Every field Mistral accepts from us, and nothing else. JSONSerialization
    /// does not guarantee key order, so the wire object is pinned as an exact
    /// key set plus each value (same convention as the OpenAI-shape tests).
    func testMistralShapeEmitsExactlyTheAcceptedFields() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "secret",
            model: MistralPolishDefaults.model,
            samplingDefaults: PolishSamplingDefaults(
                temperature: 0.2,
                topP: 0.9,
                presencePenalty: 1.5
            ),
            requestShape: .mistral
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: configuration.body(for: request.wire)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            Set(json.keys),
            [
                "model", "messages", "temperature", "top_p", "presence_penalty",
                "reasoning_effort", "prompt_cache_key",
            ]
        )
        XCTAssertEqual(json["model"] as? String, "mistral-medium-3-5")
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertEqual(json["top_p"] as? Double, 0.9)
        XCTAssertEqual(json["presence_penalty"] as? Double, 1.5)
        // Polishing must never buy a reasoning trace: mistral-medium-3-5 is
        // reasoning-capable, and a trace costs latency and output tokens to
        // insert one space before a question mark.
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertEqual(
            json["messages"] as? [[String: String]],
            [
                ["role": "system", "content": "system"],
                ["role": "user", "content": "first"],
                ["role": "user", "content": "second"],
            ]
        )
    }

    /// With no sampling defaults the shape is the minimum viable request plus
    /// the reasoning opt-out — same 0.3 temperature the OpenAI shape defaults
    /// to, so a provider swap is not also a sampling change.
    func testMistralShapeWithoutSamplingDefaultsKeepsTheSharedTemperature() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "",
            model: MistralPolishDefaults.model,
            requestShape: .mistral
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: configuration.body(for: request.wire)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            Set(json.keys),
            ["model", "messages", "temperature", "reasoning_effort", "prompt_cache_key"]
        )
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
    }

    /// `max_tokens` IS in Mistral's schema, so the warmup request's cap still
    /// rides along — and a production request (nil) still omits the key.
    func testMistralShapeForwardsMaxTokensOnlyWhenSet() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "",
            model: MistralPolishDefaults.model,
            requestShape: .mistral
        )
        let warmup = LLMPolishingRequest(
            inputText: "hello",
            systemPrompt: "system",
            userPrompts: ["first"],
            maxTokens: 1
        )

        let warmupJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: configuration.body(for: warmup.wire)
            ) as? [String: Any]
        )
        XCTAssertEqual(warmupJSON["max_tokens"] as? Int, 1)

        let productionJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: configuration.body(for: request.wire)
            ) as? [String: Any]
        )
        XCTAssertNil(productionJSON["max_tokens"])
    }

    /// The load-bearing one: a configuration carrying every self-hosted extra
    /// (a catalog model's `top_k`/`min_p` sampling defaults, mlx-lm's
    /// `chat_template_kwargs`, llama.cpp's `thinking_budget_tokens`, Bifrost's
    /// passthrough header) must send NONE of them to Mistral. Each of those is
    /// a 422 on a closed schema, and the header would only advertise fields
    /// that are not there.
    func testMistralShapeDropsEverySelfHostedExtraEvenWhenConfigured() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "secret",
            model: MistralPolishDefaults.model,
            samplingDefaults: PolishSamplingDefaults(
                temperature: 0.3,
                topP: 0.8,
                topK: 20,
                minP: 0.1,
                presencePenalty: 1.0
            ),
            chatTemplateArguments: ["enable_thinking": false],
            thinkingBudgetTokens: 0,
            passthroughExtraParameters: true,
            requestShape: .mistral
        )

        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(urlRequest.httpBody)
            ) as? [String: Any]
        )

        XCTAssertNil(json["top_k"])
        XCTAssertNil(json["min_p"])
        XCTAssertNil(json["chat_template_kwargs"])
        XCTAssertNil(json["thinking_budget_tokens"])
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-bf-passthrough-extra-params"))
        // The fields Mistral DOES accept from the same configuration survive.
        XCTAssertEqual(json["top_p"] as? Double, 0.8)
        XCTAssertEqual(json["presence_penalty"] as? Double, 1.0)
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
    }

    /// The same configuration in the default shape still sends the extras —
    /// proof the drop is the shape's doing, not a field that got deleted.
    func testOpenAICompatibleShapeStillSendsTheSelfHostedExtras() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://router:8080/v1/chat/completions")!,
            apiKey: "",
            model: "llamacpp/qwen35-4b",
            samplingDefaults: PolishSamplingDefaults(topK: 20, minP: 0.1),
            chatTemplateArguments: ["enable_thinking": false],
            thinkingBudgetTokens: 0,
            passthroughExtraParameters: true
        )

        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(urlRequest.httpBody)
            ) as? [String: Any]
        )

        XCTAssertEqual(json["top_k"] as? Int, 20)
        XCTAssertEqual(json["min_p"] as? Double, 0.1)
        XCTAssertEqual(json["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(
            json["chat_template_kwargs"] as? [String: Bool],
            ["enable_thinking": false]
        )
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "x-bf-passthrough-extra-params"),
            "true"
        )
    }

    // MARK: - Base URL

    /// The Settings field will carry the bare Mistral base URL; it must reach
    /// the wire as the documented `/v1/chat/completions` path.
    func testMistralBaseURLNormalizesToChatCompletions() throws {
        XCTAssertEqual(
            LLMPolishingConfiguration.normalizedChatCompletionsURL(MistralPolishDefaults.endpoint)
                .absoluteString,
            "https://api.mistral.ai/v1/chat/completions"
        )

        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "",
            model: MistralPolishDefaults.model,
            requestShape: .mistral
        )
        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://api.mistral.ai/v1/chat/completions"
        )
    }

    /// `prompt_cache_key` names the fixed start of the prompt and nothing
    /// else: requests that differ only in the transcript share a key, a
    /// different system prompt gets another, and the key carries no prompt
    /// text. A one-message request has no fixed start and sends no key.
    func testMistralPromptCacheKeyFollowsTheFixedStartOnly() throws {
        func key(_ system: String, _ prompts: [String]) -> String? {
            LLMPolishingConfiguration.mistralPromptCacheKey(
                for: LLMPolishingRequest(inputText: "x", systemPrompt: system, userPrompts: prompts).wire
            )
        }
        let first = try XCTUnwrap(key("system", ["fixed", "transcript one"]))
        XCTAssertEqual(key("system", ["fixed", "transcript two"]), first)
        XCTAssertNotEqual(key("other system", ["fixed", "transcript one"]), first)
        XCTAssertNotEqual(key("system", ["other fixed", "transcript one"]), first)
        XCTAssertTrue(first.hasPrefix("lvx-polish-"))
        XCTAssertEqual(first.count, "lvx-polish-".count + 16)
        XCTAssertFalse(first.contains("system"))
        XCTAssertNil(key("", ["only message"]))
        XCTAssertNotNil(key("system", ["only message"]))
    }

    /// The key is a Mistral field; the OpenAI-compatible shape never sends it.
    func testOpenAIShapeSendsNoPromptCacheKey() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
            apiKey: "",
            model: "local"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: configuration.body(for: request.wire)
            ) as? [String: Any]
        )
        XCTAssertNil(json["prompt_cache_key"])
    }
}
