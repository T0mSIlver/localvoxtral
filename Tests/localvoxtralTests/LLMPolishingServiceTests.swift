import Foundation
import XCTest
@testable import localvoxtral

final class LLMPolishingServiceTests: XCTestCase {
    private let request = LLMPolishingRequest(
        inputText: "hello",
        systemPrompt: "system",
        userPrompts: ["first", "second"]
    )

    /// The polish request timeout must accommodate the managed worst case: a
    /// 4B model with an invalidated polishd prefix cache re-prefills ~2.3k
    /// tokens and took 23.6 s on a real request — the previous 15 s timeout
    /// abandoned it and the user lost the polish (field, 2026-07-11). Polish
    /// is async behind the overlay, so slow beats discarded. Pinned through
    /// the request-construction seam — no networking, no wall-clock.
    func testPolishRequestTimeoutAccommodatesManagedWorstCase() throws {
        XCTAssertEqual(LLMPolishingService.requestTimeoutInterval, 40)

        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            apiKey: "",
            model: "model"
        )
        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        XCTAssertEqual(urlRequest.timeoutInterval, 40)
    }

    func testNilSamplingDefaultsKeepLegacyRequestBytesIdentical() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            samplingDefaults: nil
        )
        let bytes = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )

        // JSONSerialization does not guarantee dictionary key order, so raw
        // bytes from two independent serialization calls are not comparable.
        // Pin the exact legacy wire object and prove no override key was added.
        XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature"])
        XCTAssertEqual(json["model"] as? String, "model")
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        XCTAssertEqual(
            json["messages"] as? [[String: String]],
            [
                ["role": "system", "content": "system"],
                ["role": "user", "content": "first"],
                ["role": "user", "content": "second"],
            ]
        )
        XCTAssertNil(json["chat_template_kwargs"])
    }

    func testSamplingDefaultsEmitExactOpenAIFieldNames() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            samplingDefaults: PolishSamplingDefaults(
                temperature: 1.0,
                topP: 0.9,
                topK: 20,
                minP: 0.1,
                presencePenalty: 2.0
            )
        )

        let data = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["temperature"] as? Double, 1.0)
        XCTAssertEqual(json["top_p"] as? Double, 0.9)
        XCTAssertEqual(json["top_k"] as? Int, 20)
        XCTAssertEqual(json["min_p"] as? Double, 0.1)
        XCTAssertEqual(json["presence_penalty"] as? Double, 2.0)
        XCTAssertNil(json["topP"])
        XCTAssertNil(json["topK"])
        XCTAssertNil(json["minP"])
        XCTAssertNil(json["presencePenalty"])
    }

    func testMaxTokensEmitsOpenAIFieldNameOnlyWhenSet() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model"
        )
        let warmupRequest = LLMPolishingRequest(
            inputText: "hello",
            systemPrompt: "system",
            userPrompts: ["first", "second"],
            maxTokens: 1
        )

        let warmupJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(
                    request: warmupRequest,
                    configuration: configuration
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(warmupJSON["max_tokens"] as? Int, 1)

        // The production polish request (nil maxTokens) keeps its legacy wire
        // shape: no max_tokens key at all, the helper applies its default.
        let productionJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(
                    request: request,
                    configuration: configuration
                )
            ) as? [String: Any]
        )
        XCTAssertNil(productionJSON["max_tokens"])
        XCTAssertNil(productionJSON["maxTokens"])
    }

    func testChatTemplateArgumentsEmitMlxLmFieldName() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            chatTemplateArguments: ["enable_thinking": false]
        )

        let data = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let kwargs = try XCTUnwrap(json["chat_template_kwargs"] as? [String: Bool])

        XCTAssertEqual(kwargs, ["enable_thinking": false])
        XCTAssertNil(json["chatTemplateArguments"])
    }

    func testLlamaCppReasoningBudgetAndBifrostPassthroughAreExplicitOptIns() throws {
        let endpoint = URL(string: "http://router:8080/v1/chat/completions")!
        let configuration = LLMPolishingConfiguration(
            endpointURL: endpoint,
            apiKey: "",
            model: "llamacpp/qwen35-4b",
            chatTemplateArguments: ["enable_thinking": false],
            thinkingBudgetTokens: 0,
            passthroughExtraParameters: true
        )

        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        let data = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(
            json["chat_template_kwargs"] as? [String: Bool],
            ["enable_thinking": false]
        )
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "x-bf-passthrough-extra-params"),
            "true"
        )

        let legacy = LLMPolishingConfiguration(
            endpointURL: endpoint,
            apiKey: "",
            model: "model"
        )
        let legacyRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: legacy
        )
        let legacyData = try XCTUnwrap(legacyRequest.httpBody)
        let legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyJSON["thinking_budget_tokens"])
        XCTAssertNil(legacyRequest.value(forHTTPHeaderField: "x-bf-passthrough-extra-params"))
    }
}
