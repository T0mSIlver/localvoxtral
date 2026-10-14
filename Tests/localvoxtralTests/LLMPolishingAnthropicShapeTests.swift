import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

/// Anthropic's Messages API (#1849): an External URL server on
/// `api.anthropic.com` gets its own body, URL and headers, and its replies
/// are read from the top-level `content` and `stop_reason`.
final class LLMPolishingAnthropicShapeTests: XCTestCase {
    private let configuration = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://api.anthropic.com")!,
        apiKey: "secret",
        model: "claude-sonnet-5-5",
        samplingDefaults: PolishSamplingDefaults(temperature: 0.2, topP: 0.9),
        chatTemplateArguments: ["enable_thinking": false],
        thinkingBudgetTokens: 0,
        passthroughExtraParameters: true,
        requestShape: .anthropic
    )

    private func body(_ request: LLMPolishingRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(request: request, configuration: configuration)
            ) as? [String: Any])
    }

    func testOnlyTheAnthropicHostSelectsTheShape() {
        XCTAssertEqual(
            LLMPolishingRequestShape.forExternalEndpoint(URL(string: "https://API.anthropic.com/v1")!),
            .anthropic)
        XCTAssertEqual(
            LLMPolishingRequestShape.forExternalEndpoint(URL(string: "http://127.0.0.1:8080")!),
            .openAICompatible)
        XCTAssertEqual(
            LLMPolishingRequestShape.forExternalEndpoint(URL(string: "https://proxy.example/api.anthropic.com")!),
            .openAICompatible)
    }

    /// No sampling field (current models 400 on non-default values) and none
    /// of the self-hosted extras, even when the configuration carries them.
    /// The prompts are blocks of one user message, the cache breakpoint on
    /// the last fixed one.
    func testPolishBodyIsExactlyTheMessagesShapeAtLowEffort() throws {
        let json = try body(
            LLMPolishingRequest(inputText: "hello", systemPrompt: "system", userPrompts: ["first", "second"]))

        XCTAssertEqual(Set(json.keys), ["model", "max_tokens", "messages", "output_config", "system"])
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 16000)
        XCTAssertEqual(json["output_config"] as? [String: String], ["effort": "low"])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["text"] as? String, "system")
        XCTAssertNil(system[0]["cache_control"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["text"] as? String }, ["first", "second"])
        XCTAssertEqual(blocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertNil(blocks[1]["cache_control"])
    }

    /// A one-prompt request caches the system prompt; a deep-reasoning
    /// request asks for high effort; a caller's cap replaces the default.
    func testOnePromptDeepRequestWithItsOwnCap() throws {
        let json = try body(
            LLMPolishingRequest(
                inputText: "hello", systemPrompt: "system", userPrompts: ["only"],
                maxTokens: 300, prefersDeepReasoning: true))

        XCTAssertEqual(json["max_tokens"] as? Int, 300)
        XCTAssertEqual(json["output_config"] as? [String: String], ["effort": "high"])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    func testURLRequestTargetsMessagesWithAnthropicHeaders() throws {
        for endpoint in ["https://api.anthropic.com", "https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"] {
            let configuration = LLMPolishingConfiguration(
                endpointURL: URL(string: endpoint)!, apiKey: "secret", model: "claude-sonnet-5-5",
                passthroughExtraParameters: true, requestShape: .anthropic)
            let urlRequest = try LLMPolishingService.makeURLRequest(
                request: LLMPolishingRequest(inputText: "hello", systemPrompt: "", userPrompts: ["hi"]),
                configuration: configuration)

            XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages", endpoint)
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "secret")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-bf-passthrough-extra-params"))
        }
    }

    // MARK: - Replies

    private func polish(replying body: String) async throws -> LLMPolishingResult {
        let previous = StubHTTPProtocol.reply.withLock { $0 }
        StubHTTPProtocol.reply.withLock { $0 = .http(200, body) }
        defer { StubHTTPProtocol.reply.withLock { $0 = previous } }
        let service = LLMPolishingService(session: StubHTTPProtocol.session())
        return try await service.polish(
            request: LLMPolishingRequest(inputText: "hello", systemPrompt: "system", userPrompts: ["hello"]),
            configuration: configuration)
    }

    /// The thinking block is never the polish; the text blocks are. Cache
    /// reads and writes count toward the prompt.
    func testReplyTextSkipsThinkingAndUsageCountsTheCache() async throws {
        let result = try await polish(replying: """
            {"model":"claude-sonnet-5-5","stop_reason":"end_turn",
             "content":[{"type":"thinking","thinking":"","signature":"x"},
                        {"type":"text","text":" Hello, "},{"type":"text","text":"world. "}],
             "usage":{"input_tokens":10,"cache_read_input_tokens":900,
                      "cache_creation_input_tokens":50,"output_tokens":7}}
            """)

        XCTAssertEqual(result.polishedText, "Hello, world.")
        XCTAssertEqual(
            result.usage,
            LLMTokenUsage(model: "claude-sonnet-5-5", promptTokens: 960, cachedPromptTokens: 900, completionTokens: 7))
    }

    /// Both stops can carry partial text, which would drop or garble the
    /// rest of the dictation if committed.
    func testCutOffAndRefusedRepliesAreNeverCommitted() async {
        let cases: [(stopReason: String, expected: String)] = [
            ("max_tokens", "truncated"),
            ("model_context_window_exceeded", "truncated"),
            ("refusal", "invalidResponse"),
        ]
        for (stopReason, expected) in cases {
            do {
                _ = try await polish(replying: """
                    {"stop_reason":"\(stopReason)","content":[{"type":"text","text":"Hel"}],
                     "usage":{"input_tokens":1,"output_tokens":1}}
                    """)
                XCTFail("\(stopReason) was committed")
            } catch LLMPolishingError.truncated {
                XCTAssertEqual(expected, "truncated", stopReason)
            } catch LLMPolishingError.invalidResponse {
                XCTAssertEqual(expected, "invalidResponse", stopReason)
            } catch {
                XCTFail("\(stopReason): \(error)")
            }
        }
    }
}
