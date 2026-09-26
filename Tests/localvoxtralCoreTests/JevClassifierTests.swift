import Foundation
import XCTest

@testable import localvoxtralCore

final class JevClassifierTests: XCTestCase {
    private let options = QuickCaptureRouting.options(for: [
        QuickCaptureProject(key: "/w/localvoxtral", name: "localvoxtral", summary: "Dictation app.", terms: [], userLine: nil),
        QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: [], userLine: nil),
    ])

    /// The choice answer as docs.typesafe.ai/primitives/choice gives it, with
    /// this question's id and options. Replace with a recorded answer once a
    /// key exists (#730).
    private let documentedAnswer = Data("""
        {"model": "jev-1.13.0", "answers": {"project": {"type": "choice", "choice": "localvoxtral",
         "confidence": 0.82, "probabilities": {"localvoxtral": 0.85, "website": 0.08, "inbox": 0.07}}},
         "usage": {"input_tokens": 312, "output_tokens": 48}}
        """.utf8)

    func testBothHostsGetTheSameChoiceQuestionWithTheirOwnModel() throws {
        for (host, url, model) in [
            (Jev.Host.typesafe, "https://api.typesafe.ai/v1/systemone", "jev-latest"),
            (.vercelGateway, "https://ai-gateway.vercel.sh/v1/evaluate", "typesafe-ai/jev"),
        ] {
            let request = Jev.request(host: host, apiKey: "k", capture: "Add a dark mode", options: options)
            XCTAssertEqual(request.url?.absoluteString, url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
            XCTAssertEqual(request.timeoutInterval, Jev.requestTimeout)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertEqual(body["state"] as? String, "Add a dark mode")
            let question = try XCTUnwrap((body["questions"] as? [String: Any])?["project"] as? [String: Any])
            XCTAssertEqual(question["type"] as? String, "choice")
            XCTAssertEqual(question["instructions"] as? String, Jev.instructions)
            XCTAssertEqual(
                question["criteria"] as? [String: String],
                Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.description) })
            )
        }
    }

    func testTheDocumentedAnswerRoutesThroughTheRouter() throws {
        let probabilities = try Jev.probabilities(status: 200, body: documentedAnswer)
        XCTAssertEqual(probabilities, ["localvoxtral": 0.85, "website": 0.08, "inbox": 0.07])
        let route = QuickCaptureRouting.decide(probabilities: probabilities, options: options, classifier: .jev)
        XCTAssertEqual(route.destination, .project("/w/localvoxtral"))
    }

    func testAnAnswerWithoutADistributionStillNamesItsChoice() throws {
        let body = Data(#"{"answers": {"project": {"type": "choice", "choice": "website", "confidence": 0.7}}}"#.utf8)
        XCTAssertEqual(try Jev.probabilities(status: 200, body: body), ["website": 0.7])
    }

    func testFailuresCarryTheAPIsMessage() {
        let cases: [(Int, String, Jev.Failure)] = [
            (422, #"{"detail":[{"type":"missing","loc":["body","model"],"msg":"Field required"}]}"#,
             .http(status: 422, message: "Field required")),
            (401, #"{"error":{"message":"Invalid API key"}}"#, .http(status: 401, message: "Invalid API key")),
            (500, "upstream down", .http(status: 500, message: nil)),
            (200, #"{"answers": {}}"#, .malformedResponse),
        ]
        for (status, body, expected) in cases {
            XCTAssertThrowsError(try Jev.probabilities(status: status, body: Data(body.utf8))) { error in
                XCTAssertEqual(error as? Jev.Failure, expected, body)
            }
        }
    }
}

final class QuickCaptureChatRoutingTests: XCTestCase {
    private let options = QuickCaptureRouting.options(for: [
        QuickCaptureProject(key: "/w/localvoxtral", name: "localvoxtral", summary: nil, terms: [], userLine: nil),
    ])

    private func reply(_ content: String) -> Data {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testTheAnswerIsReadBareFencedOrAfterThinking() throws {
        for content in [
            #"{"project": "localvoxtral", "confidence": 0.8}"#,
            "```json\n{\"project\": \"localvoxtral\", \"confidence\": 0.8}\n```",
            "<think>Maybe {\"project\": \"inbox\"}</think>\n{\"project\": \"localvoxtral\", \"confidence\": 0.8}",
        ] {
            XCTAssertEqual(
                try QuickCaptureChatRouting.probabilities(status: 200, body: reply(content), options: options),
                ["localvoxtral": 0.8], content
            )
        }
    }

    func testAMistralReasoningReplyIsReadFromItsTextChunk() throws {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": [
            ["type": "thinking", "thinking": [["type": "text", "text": "Maybe {\"project\": \"inbox\"}"]]],
            ["type": "text", "text": #"{"project": "localvoxtral", "confidence": 0.85}"#],
        ]]]]]
        XCTAssertEqual(
            try QuickCaptureChatRouting.probabilities(
                status: 200, body: JSONSerialization.data(withJSONObject: object), options: options),
            ["localvoxtral": 0.85]
        )
    }

    func testAnIdThatIsNoOptionIsAFailureNotAGuess() {
        XCTAssertThrowsError(
            try QuickCaptureChatRouting.probabilities(
                status: 200, body: reply(#"{"project": "vidtheque", "confidence": 1}"#), options: options)
        ) { XCTAssertEqual($0 as? QuickCaptureChatRouting.Failure, .unknownOption) }
    }

    func testTheRequestCarriesThePolishConfigurationsExtraFields() throws {
        let body = QuickCaptureChatRouting.requestBody(
            model: "m", capture: "c", options: options,
            extraBody: ["chat_template_kwargs": ["enable_thinking": false]]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "m")
        XCTAssertEqual((object["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["content"], QuickCaptureChatRouting.systemPrompt)
        XCTAssertTrue(messages.last?["content"]?.hasSuffix("Note:\nc") == true)
    }
}
