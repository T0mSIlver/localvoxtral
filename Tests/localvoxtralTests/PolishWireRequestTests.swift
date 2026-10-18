import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

/// What every polish-model request puts on the wire (#1851): URL, method,
/// timeout, headers and body, for polish, the quick-capture router and the
/// quick-capture first draft, on each server shape.
///
/// `Fixtures/PolishWireRequests.json` pins the OpenAI-compatible and Mistral
/// requests. The body is compared as JSON with sorted keys, since key order
/// is not part of the request. Mistral's `prompt_cache_key` is an HMAC under
/// a key drawn at launch, so only its presence is pinned.
///
/// A missing fixture is recorded and printed between `POLISH WIRE BEGIN/END`
/// lines (the build host cannot send files back), and fails until committed.
/// To re-record on purpose, delete the file; a mismatch never rewrites it.
final class PolishWireRequestTests: XCTestCase {
    // MARK: - Configurations

    private static let managed = LLMPolishingConfiguration(
        endpointURL: URL(string: "http://127.0.0.1:8090")!,
        apiKey: "",
        model: "mlx-community/Qwen3.5-4B-4bit",
        samplingDefaults: PolishSamplingDefaults(temperature: 0.7, topP: 0.8, topK: 20, minP: 0, presencePenalty: 1.5),
        chatTemplateArguments: ["enable_thinking": false],
        usageBackend: .bundledHelper
    )

    private static let external = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://llm.example/proxy/v1")!,
        apiKey: "sk-external",
        model: "qwen3",
        samplingDefaults: PolishSamplingDefaults(temperature: 0.2, topP: 0.9, topK: 40, minP: 0.05, presencePenalty: 0.5),
        chatTemplateArguments: ["enable_thinking": false],
        thinkingBudgetTokens: 0,
        passthroughExtraParameters: true
    )

    private static let externalBare = LLMPolishingConfiguration(
        endpointURL: URL(string: "http://192.168.1.20:8080/v1/chat/completions")!,
        apiKey: "",
        model: "local-model"
    )

    private static let mistral = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://api.mistral.ai")!,
        apiKey: "mistral-key",
        model: "mistral-medium-3-5",
        requestShape: .mistral,
        mistralReasoningEffort: .off
    )

    /// No catalog answer: the effort comes from the model id. Sampling
    /// defaults are carried but only the fields Mistral's schema names go.
    private static let mistralGLM = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://api.mistral.ai")!,
        apiKey: "mistral-key",
        model: "zai-glm-5-3",
        samplingDefaults: PolishSamplingDefaults(temperature: 0.6, topP: 0.95, topK: 20, minP: 0, presencePenalty: 1),
        chatTemplateArguments: ["enable_thinking": false],
        thinkingBudgetTokens: 0,
        passthroughExtraParameters: true,
        requestShape: .mistral
    )

    private static let mistralWithoutReasoning = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://api.mistral.ai")!,
        apiKey: "mistral-key",
        model: "mistral-small-latest",
        requestShape: .mistral,
        mistralReasoningEffort: .omitted
    )

    private static let anthropic = LLMPolishingConfiguration(
        endpointURL: URL(string: "https://api.anthropic.com")!,
        apiKey: "anthropic-key",
        model: "claude-sonnet-5-5",
        requestShape: .anthropic
    )

    // MARK: - Requests

    private static let polish = LLMPolishingRequest(
        inputText: "fix the local vox trawl docs",
        systemPrompt: "You polish dictated text.",
        userPrompts: ["[Reference]\nlocalvoxtral", "fix the local vox trawl docs"]
    )

    private static let termSuggestions = LLMPolishingRequest(
        inputText: "weeks of dictations",
        systemPrompt: "",
        userPrompts: ["Suggest terms from: weeks of dictations"],
        maxTokens: 2000,
        timeoutSeconds: 600,
        prefersDeepReasoning: true,
        usageFeature: .termSuggestions
    )

    private static let warmup = LLMPolishingRequest(
        inputText: "warm",
        systemPrompt: "You polish dictated text.",
        userPrompts: ["[Reference]\nlocalvoxtral", "warm"],
        maxTokens: 1,
        usageFeature: nil
    )

    private static let options = [
        QuickCaptureOption(id: "quill", projectKey: "/w/quill", description: "Project quill."),
        QuickCaptureOption(id: QuickCaptureRouting.catchAllID, projectKey: nil, description: "Anything else."),
    ]

    private static let capture = "make the quill export faster"

    // MARK: - Capture

    private func polishRequest(_ request: LLMPolishingRequest, _ configuration: LLMPolishingConfiguration) throws -> URLRequest {
        try LLMPolishingService.makeURLRequest(request: request, configuration: configuration)
    }

    /// The router's request, as the Inbox wires it, answered by a stub.
    private func classifierRequest(_ configuration: LLMPolishingConfiguration) async throws -> URLRequest {
        try await recording {
            _ = try? await QuickCaptureInboxViewModel.chatClassifier(
                polishing: configuration, session: StubHTTPProtocol.session()
            ).classify(capture: Self.capture, options: Self.options)
        }
    }

    /// The first draft's request, as the Inbox wires it, answered by a stub.
    private func firstDraftRequest(_ configuration: LLMPolishingConfiguration) async throws -> URLRequest {
        try await recording {
            _ = await QuickCaptureInboxViewModel.firstDrafter(
                polishing: configuration, session: StubHTTPProtocol.session()
            ).firstDraft(capture: Self.capture, projectName: "quill", context: QuickCaptureContext())
        }
    }

    private func recording(_ send: () async throws -> Void) async throws -> URLRequest {
        let previous = StubHTTPProtocol.reply.withLock { $0 }
        StubHTTPProtocol.reply.withLock { $0 = .http(500, "{}") }
        StubHTTPProtocol.recorded.withLock { $0 = [] }
        defer { StubHTTPProtocol.reply.withLock { $0 = previous } }
        try await send()
        let requests = StubHTTPProtocol.recorded.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(requests.first)
    }

    // MARK: - OpenAI-compatible and Mistral: pinned

    func testOpenAICompatibleAndMistralRequestsMatchTheirFixtures() async throws {
        var snapshots: [String: Any] = [:]
        let polishCases: [(String, LLMPolishingRequest, LLMPolishingConfiguration)] = [
            ("polish-managed", Self.polish, Self.managed),
            ("polish-managed-warmup", Self.warmup, Self.managed),
            ("polish-external", Self.polish, Self.external),
            ("polish-external-bare", Self.polish, Self.externalBare),
            ("polish-external-term-suggestions", Self.termSuggestions, Self.external),
            ("polish-mistral", Self.polish, Self.mistral),
            ("polish-mistral-glm", Self.polish, Self.mistralGLM),
            ("polish-mistral-glm-term-suggestions", Self.termSuggestions, Self.mistralGLM),
            ("polish-mistral-without-reasoning", Self.polish, Self.mistralWithoutReasoning),
        ]
        for (name, request, configuration) in polishCases {
            snapshots[name] = try snapshot(polishRequest(request, configuration))
        }
        let quickCaptureCases: [(String, LLMPolishingConfiguration)] = [
            ("managed", Self.managed),
            ("external", Self.external),
            ("external-bare", Self.externalBare),
            ("mistral", Self.mistral),
            ("mistral-glm", Self.mistralGLM),
            ("mistral-without-reasoning", Self.mistralWithoutReasoning),
        ]
        for (name, configuration) in quickCaptureCases {
            snapshots["quick-capture-route-\(name)"] = try snapshot(await classifierRequest(configuration))
            snapshots["quick-capture-first-draft-\(name)"] = try snapshot(await firstDraftRequest(configuration))
        }
        try assertFixture(snapshots)
    }

    // MARK: - Anthropic

    /// Quick capture on an `api.anthropic.com` server sends #1850's Messages
    /// request, not a chat/completions one Anthropic has no route for.
    func testQuickCaptureOnAnAnthropicServerSendsMessagesRequests() async throws {
        let route = try await classifierRequest(Self.anthropic)
        let draft = try await firstDraftRequest(Self.anthropic)
        for (name, urlRequest, maxTokens) in [("route", route, 4096), ("first draft", draft, 16_384)] {
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages", name)
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "anthropic-key", name)
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", name)
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"), name)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any], name)
            XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "messages", "output_config", "system"], name)
            XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5", name)
            XCTAssertEqual(body["max_tokens"] as? Int, maxTokens, name)
            XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"], name)
            let system = try XCTUnwrap(body["system"] as? [[String: Any]], name)
            XCTAssertEqual(system.count, 1, name)
            XCTAssertEqual(system[0]["cache_control"] as? [String: String], ["type": "ephemeral"], name)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]], name)
            XCTAssertEqual(messages.count, 1, name)
            XCTAssertEqual(messages[0]["role"] as? String, "user", name)
            let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]], name)
            XCTAssertEqual(blocks.count, 1, name)
            XCTAssertTrue((blocks[0]["text"] as? String)?.contains(Self.capture) == true, name)
        }
    }

    // MARK: - Snapshot

    private func snapshot(_ request: URLRequest) throws -> [String: Any] {
        var body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        if body["prompt_cache_key"] is String {
            body["prompt_cache_key"] = "<hmac of the fixed start>"
        }
        return [
            "url": request.url?.absoluteString ?? "",
            "method": request.httpMethod ?? "",
            "timeoutSeconds": request.timeoutInterval,
            "headers": request.allHTTPHeaderFields ?? [:],
            "body": body,
        ]
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PolishWireRequests.json")

    private func assertFixture(_ snapshots: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONSerialization.data(
            withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let actual = String(decoding: data, as: UTF8.self) + "\n"
        guard FileManager.default.fileExists(atPath: Self.fixtureURL.path) else {
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            printForRecovery(actual)
            XCTFail("no fixture: recorded \(Self.fixtureURL.lastPathComponent); commit it after checking it", file: file, line: line)
            return
        }
        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        guard expected != actual else { return }
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        let first = zip(expectedLines, actualLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(expectedLines.count, actualLines.count)
        printForRecovery(actual)
        XCTFail(
            """
            a polish request changed on the wire at fixture line \(first + 1):
              fixture: \(expectedLines.indices.contains(first) ? expectedLines[first] : "<end>")
              actual:  \(actualLines.indices.contains(first) ? actualLines[first] : "<end>")
            """,
            file: file, line: line)
    }

    private func printForRecovery(_ contents: String) {
        fflush(stdout)
        print("===== POLISH WIRE BEGIN =====")
        print(contents, terminator: "")
        print("===== POLISH WIRE END =====")
        fflush(stdout)
    }
}
