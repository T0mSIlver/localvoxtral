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

    // MARK: - Base-URL normalization

    /// The endpoint field accepts a bare base URL (the OpenAI-compatible
    /// convention) while still round-tripping the full `/v1/chat/completions`
    /// URLs users used to have to type. Table-driven so every documented shape
    /// is pinned in one place.
    func testNormalizedChatCompletionsURLMapsEveryEndpointShape() {
        let cases: [(input: String, expected: String)] = [
            // Base URL (empty path) — port present and absent.
            ("http://127.0.0.1:8080", "http://127.0.0.1:8080/v1/chat/completions"),
            ("http://127.0.0.1:8080/", "http://127.0.0.1:8080/v1/chat/completions"),
            ("https://api.example.com", "https://api.example.com/v1/chat/completions"),
            // Ollama-style base URL.
            ("http://localhost:11434", "http://localhost:11434/v1/chat/completions"),
            // Path ending in /v1 (with and without trailing slash).
            ("http://127.0.0.1:8080/v1", "http://127.0.0.1:8080/v1/chat/completions"),
            ("http://127.0.0.1:8080/v1/", "http://127.0.0.1:8080/v1/chat/completions"),
            // Proxy prefix that still mounts the OpenAI API under /v1.
            ("http://gw.example/proxy/v1", "http://gw.example/proxy/v1/chat/completions"),
            ("http://gw.example/proxy/v1/", "http://gw.example/proxy/v1/chat/completions"),
            // Other non-empty base path — appended under /v1.
            ("http://gw.example/openai", "http://gw.example/openai/v1/chat/completions"),
            ("http://gw.example/openai/", "http://gw.example/openai/v1/chat/completions"),
            // Full URL passthrough (with and without trailing slash — unchanged).
            (
                "https://api.openai.com/v1/chat/completions",
                "https://api.openai.com/v1/chat/completions"
            ),
            (
                "https://api.openai.com/v1/chat/completions/",
                "https://api.openai.com/v1/chat/completions/"
            ),
            // A full URL under a non-/v1 mount also passes through unchanged.
            (
                "http://gw.example/proxy/chat/completions",
                "http://gw.example/proxy/chat/completions"
            ),
            // Uppercase path: append case-insensitively, preserve the base case.
            ("http://127.0.0.1:8080/V1", "http://127.0.0.1:8080/V1/chat/completions"),
            (
                "https://api.openai.com/V1/CHAT/COMPLETIONS",
                "https://api.openai.com/V1/CHAT/COMPLETIONS"
            ),
            // Scheme is irrelevant to the path rewrite — a ws:// URL is
            // rewritten identically (the config guard rejects it upstream; this
            // pins that normalization itself is scheme-agnostic).
            ("ws://127.0.0.1:8080", "ws://127.0.0.1:8080/v1/chat/completions"),
            ("ws://127.0.0.1:8080/v1", "ws://127.0.0.1:8080/v1/chat/completions"),
        ]

        for testCase in cases {
            let input = URL(string: testCase.input)!
            let normalized = LLMPolishingService.normalizedChatCompletionsURL(input)
            XCTAssertEqual(
                normalized.absoluteString,
                testCase.expected,
                "normalizing \(testCase.input)"
            )
            XCTAssertFalse(
                normalized.path.contains("//"),
                "normalizing \(testCase.input) produced a double slash: \(normalized.path)"
            )
        }
    }

    /// Normalization only rewrites the path — host and port (which the Local
    /// Network permission preflight classifies on) are never altered, so a base
    /// URL and its normalized form preflight the same target.
    func testNormalizedChatCompletionsURLPreservesHostAndPort() {
        let cases = [
            "http://127.0.0.1:8080",
            "http://192.168.1.50:1234/v1",
            "https://api.example.com",
            "http://gw.example/proxy/v1",
            "http://[fd00::5]:8080/v1",
        ]
        for input in cases {
            let url = URL(string: input)!
            let normalized = LLMPolishingService.normalizedChatCompletionsURL(url)
            XCTAssertEqual(normalized.host, url.host, "host changed for \(input)")
            XCTAssertEqual(normalized.port, url.port, "port changed for \(input)")
            XCTAssertEqual(normalized.scheme, url.scheme, "scheme changed for \(input)")
        }
    }

    /// A query string is carried through untouched when the path is rewritten.
    func testNormalizedChatCompletionsURLPreservesQuery() {
        let url = URL(string: "http://127.0.0.1:8080?tenant=acme")!
        XCTAssertEqual(
            LLMPolishingService.normalizedChatCompletionsURL(url).absoluteString,
            "http://127.0.0.1:8080/v1/chat/completions?tenant=acme"
        )
    }

    /// Degenerate / opaque input must never trap and must never change the
    /// scheme: upstream endpoint validation (which rejects anything
    /// `URL(string:)` cannot parse, and anything that is not http/https) stays
    /// the sole gate on what is actually requested. Normalization here is
    /// path-only and total.
    func testNormalizedChatCompletionsURLPreservesSchemeForOpaqueInput() {
        let opaque = URL(string: "mailto:polish@example.com")!
        let normalized = LLMPolishingService.normalizedChatCompletionsURL(opaque)
        XCTAssertEqual(normalized.scheme, "mailto")
    }

    /// End-to-end proof that a base-URL configuration produces a request whose
    /// URL targets `/v1/chat/completions` — the whole point of accepting a base
    /// URL in Settings.
    func testMakeURLRequestNormalizesBaseURLConfigurationToChatCompletions() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "",
            model: "model"
        )
        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "http://127.0.0.1:8080/v1/chat/completions"
        )
    }

    /// A full-URL configuration reaches the wire byte-for-byte unchanged
    /// (backward compatibility for everyone who already typed the full path).
    func testMakeURLRequestLeavesFullURLConfigurationUnchanged() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: "",
            model: "model"
        )
        let urlRequest = try LLMPolishingService.makeURLRequest(
            request: request,
            configuration: configuration
        )
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }
}
