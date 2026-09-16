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
                with: LLMPolishingService.requestBody(
                    request: request,
                    configuration: configuration
                )
            ) as? [String: Any]
        )

        XCTAssertEqual(
            Set(json.keys),
            ["model", "messages", "temperature", "top_p", "presence_penalty", "reasoning_effort"]
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
                with: LLMPolishingService.requestBody(
                    request: request,
                    configuration: configuration
                )
            ) as? [String: Any]
        )

        XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature", "reasoning_effort"])
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
                with: LLMPolishingService.requestBody(
                    request: warmup,
                    configuration: configuration
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(warmupJSON["max_tokens"] as? Int, 1)

        let productionJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(
                    request: request,
                    configuration: configuration
                )
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

    /// A configuration with no explicit shape is the OpenAI-compatible one:
    /// every existing call site (Settings, the eval lanes, the warmup) keeps
    /// the bytes it sent before this type gained a shape.
    func testRequestShapeDefaultsToOpenAICompatible() {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "",
            model: "model"
        )
        XCTAssertEqual(configuration.requestShape, .openAICompatible)
    }

    // MARK: - Base URL

    /// The Settings field will carry the bare Mistral base URL; it must reach
    /// the wire as the documented `/v1/chat/completions` path.
    func testMistralBaseURLNormalizesToChatCompletions() throws {
        XCTAssertEqual(
            LLMPolishingService.normalizedChatCompletionsURL(MistralPolishDefaults.endpoint)
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

    // MARK: - Response content extraction

    /// The shape every OpenAI-compatible server returns, and Mistral's own
    /// when reasoning is off: `content` is a plain string.
    func testAssistantTextReadsPlainStringContent() {
        let json: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "Où est la gare ?"]]]
        ]
        XCTAssertEqual(
            LLMPolishingService.assistantText(inResponseObject: json),
            "Où est la gare ?"
        )
    }

    /// A reasoning-capable Mistral model that reasons anyway returns a LIST of
    /// chunks. Only the `text` chunks are the answer; the `thinking` chunk is
    /// the trace and must never reach the user's document.
    func testAssistantTextKeepsTextChunksAndDropsThinking() {
        let json: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "thinking",
                            "thinking": [["type": "text", "text": "The user wants French spacing."]],
                        ],
                        ["type": "text", "text": "Où est la gare ?"],
                    ],
                ],
            ]]
        ]
        XCTAssertEqual(
            LLMPolishingService.assistantText(inResponseObject: json),
            "Où est la gare ?"
        )
    }

    /// Several text chunks concatenate in order, with unknown chunk types
    /// ignored rather than treated as an error (forward compatibility).
    func testAssistantTextConcatenatesMultipleTextChunksInOrder() {
        let json: [String: Any] = [
            "choices": [[
                "message": [
                    "content": [
                        ["type": "text", "text": "Are you coming"],
                        ["type": "something_new", "text": "IGNORED"],
                        ["type": "text", "text": " tomorrow?"],
                    ]
                ],
            ]]
        ]
        XCTAssertEqual(
            LLMPolishingService.assistantText(inResponseObject: json),
            "Are you coming tomorrow?"
        )
    }

    /// A chunk list with no text chunk (a trace and nothing else) has no
    /// answer in it — nil, which the caller maps to `invalidResponse` exactly
    /// as it always has for a missing `content`.
    func testAssistantTextReturnsNilWhenChunksCarryNoText() {
        let thinkingOnly: [String: Any] = [
            "choices": [[
                "message": [
                    "content": [
                        ["type": "thinking", "thinking": [["type": "text", "text": "hmm"]]]
                    ]
                ],
            ]]
        ]
        XCTAssertNil(LLMPolishingService.assistantText(inResponseObject: thinkingOnly))

        let emptyList: [String: Any] = [
            "choices": [["message": ["content": [] as [Any]]]]
        ]
        XCTAssertNil(LLMPolishingService.assistantText(inResponseObject: emptyList))

        let noChoices: [String: Any] = ["choices": [] as [Any]]
        XCTAssertNil(LLMPolishingService.assistantText(inResponseObject: noChoices))

        let noContent: [String: Any] = ["choices": [["message": ["role": "assistant"]]]]
        XCTAssertNil(LLMPolishingService.assistantText(inResponseObject: noContent))
    }
}
