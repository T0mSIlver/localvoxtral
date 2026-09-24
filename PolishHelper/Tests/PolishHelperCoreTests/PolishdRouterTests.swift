import XCTest

@testable import PolishHelperCore

private final class StubResponder: ChatResponding, @unchecked Sendable {
    let result: Result<ChatReply, Error>
    private(set) var received:
        (
            messages: [ChatCompletionMessage],
            chatTemplateArguments: [String: ChatTemplateArgumentValue]?,
            sampling: ChatSamplingParameters
        )?

    init(result: Result<ChatReply, Error> = .success(ChatReply(content: "polished"))) {
        self.result = result
    }

    func respond(
        to messages: [ChatCompletionMessage],
        chatTemplateArguments: [String: ChatTemplateArgumentValue]?,
        sampling: ChatSamplingParameters
    ) async throws -> ChatReply {
        received = (messages, chatTemplateArguments, sampling)
        return try result.get()
    }
}

final class PolishdRouterTests: XCTestCase {
    private func chatRequest(_ json: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/chat/completions", body: Data(json.utf8))
    }

    func testHealthAnswersOK() async {
        let router = PolishdRouter(responder: StubResponder(), modelName: "m")
        let response = await router.handle(HTTPRequest(method: "GET", path: "/health"))
        XCTAssertEqual(response.status, 200)
    }

    func testChatCompletionRoundTripsContentAndParameters() async throws {
        let responder = StubResponder(result: .success(ChatReply(content: "cleaned text")))
        let router = PolishdRouter(responder: responder, modelName: "test-model")
        let response = await router.handle(
            chatRequest(
                """
                {"model": "x", "temperature": 0.3,
                 "messages": [{"role": "system", "content": "sys"},
                              {"role": "user", "content": "raw one"},
                              {"role": "user", "content": "raw two"}]}
                """
            )
        )

        XCTAssertEqual(response.status, 200)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: response.body)
        XCTAssertEqual(decoded.choices.first?.message.content, "cleaned text")
        XCTAssertEqual(decoded.choices.first?.finishReason, "stop")
        XCTAssertEqual(decoded.model, "x")
        XCTAssertEqual(responder.received?.messages.count, 3)
        XCTAssertEqual(responder.received?.messages[1].content, "raw one")
        XCTAssertNil(responder.received?.chatTemplateArguments)
        XCTAssertEqual(responder.received?.sampling.temperature, 0.3)
        XCTAssertNil(responder.received?.sampling.maxTokens)
        XCTAssertNil(decoded.timings)
    }

    func testChatCompletionReturnsTheEngineTimings() async throws {
        let timings = PolishTimings(
            firstTokenMilliseconds: 180, totalMilliseconds: 420, promptTokens: 900,
            cachedPromptTokens: 850, completionTokens: 40, draftTokens: 20,
            acceptedDraftTokens: 17)
        let router = PolishdRouter(
            responder: StubResponder(result: .success(ChatReply(content: "x", timings: timings))),
            modelName: "m")
        let response = await router.handle(
            chatRequest("{\"messages\": [{\"role\": \"user\", \"content\": \"x\"}]}")
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let wire = try XCTUnwrap(object["timings"] as? [String: Any])
        XCTAssertEqual(wire["first_token_ms"] as? Double, 180)
        XCTAssertEqual(wire["total_ms"] as? Double, 420)
        XCTAssertEqual(wire["cached_prompt_tokens"] as? Int, 850)
        XCTAssertEqual(wire["accepted_draft_tokens"] as? Int, 17)
        XCTAssertEqual(
            timings.summary,
            "first token 180 ms, total 420 ms, prompt 900 (cached 850), completion 40, "
                + "drafts accepted 17/20")
    }

    func testChatCompletionDecodesChatTemplateKwargs() async throws {
        let responder = StubResponder()
        let router = PolishdRouter(responder: responder, modelName: "test-model")
        let response = await router.handle(
            chatRequest(
                """
                {"chat_template_kwargs": {
                    "enable_thinking": false,
                    "mode": "polish",
                    "budget": 4,
                    "scale": 1.5
                 },
                 "messages": [{"role": "user", "content": "raw"}]}
                """
            )
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            responder.received?.chatTemplateArguments,
            [
                "enable_thinking": .bool(false),
                "mode": .string("polish"),
                "budget": .int(4),
                "scale": .double(1.5),
            ]
        )
    }

    func testChatCompletionRoundTripsSamplingOverrides() async throws {
        let responder = StubResponder()
        let router = PolishdRouter(responder: responder, modelName: "test-model")
        let response = await router.handle(
            chatRequest(
                """
                {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.05,
                 "presence_penalty": 2.0, "max_tokens": 64,
                 "messages": [{"role": "user", "content": "raw"}]}
                """
            )
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            responder.received?.sampling,
            ChatSamplingParameters(
                temperature: 1.0, topP: 0.95, topK: 20, minP: 0.05,
                presencePenalty: 2.0, maxTokens: 64
            )
        )
    }

    func testStreamingIsRejected() async {
        let router = PolishdRouter(responder: StubResponder(), modelName: "m")
        let response = await router.handle(
            chatRequest("{\"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"x\"}]}")
        )
        XCTAssertEqual(response.status, 400)
    }

    func testEmptyMessagesRejected() async {
        let router = PolishdRouter(responder: StubResponder(), modelName: "m")
        let response = await router.handle(chatRequest("{\"messages\": []}"))
        XCTAssertEqual(response.status, 400)
    }

    func testInvalidJSONRejected() async {
        let router = PolishdRouter(responder: StubResponder(), modelName: "m")
        let response = await router.handle(chatRequest("{nope"))
        XCTAssertEqual(response.status, 400)
    }

    func testUnknownRoleSurfacesAsBadRequest() async {
        let responder = StubResponder(result: .failure(ChatRespondingError.unknownRole("tool")))
        let router = PolishdRouter(responder: responder, modelName: "m")
        let response = await router.handle(
            chatRequest("{\"messages\": [{\"role\": \"tool\", \"content\": \"x\"}]}")
        )
        XCTAssertEqual(response.status, 400)
    }

    func testGenerationFailureSurfacesAsServerError() async throws {
        struct Boom: Error {}
        let router = PolishdRouter(responder: StubResponder(result: .failure(Boom())), modelName: "m")
        let response = await router.handle(
            chatRequest("{\"messages\": [{\"role\": \"user\", \"content\": \"x\"}]}")
        )
        XCTAssertEqual(response.status, 500)
        let decoded = try JSONDecoder().decode(ChatCompletionErrorResponse.self, from: response.body)
        XCTAssertEqual(decoded.error.type, "server_error")
    }

    func testUnknownPathIs404AndWrongMethodIs405() async {
        let router = PolishdRouter(responder: StubResponder(), modelName: "m")
        let notFound = await router.handle(HTTPRequest(method: "GET", path: "/nope"))
        XCTAssertEqual(notFound.status, 404)
        let wrongMethod = await router.handle(HTTPRequest(method: "GET", path: "/v1/chat/completions"))
        XCTAssertEqual(wrongMethod.status, 405)
    }
}
