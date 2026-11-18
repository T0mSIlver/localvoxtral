import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// The polishing server's dialect (#1851): each shape reads only its own
/// reply.
final class PolishWireTests: XCTestCase {
    private static func configuration(_ shape: LLMPolishingRequestShape) -> LLMPolishingConfiguration {
        LLMPolishingConfiguration(
            endpointURL: URL(string: "https://\(StubHTTPProtocol.host)")!, apiKey: "k", model: "m", requestShape: shape)
    }

    // MARK: - Replies

    /// Every OpenAI-compatible server, and Mistral with reasoning off: a
    /// plain string.
    func testChatCompletionsReplyReadsPlainStringContent() {
        let reply = Self.configuration(.openAICompatible).reply(toResponseObject: [
            "choices": [["message": ["role": "assistant", "content": "Où est la gare ?"], "finish_reason": "stop"]],
        ])
        XCTAssertEqual(reply.text, "Où est la gare ?")
        XCTAssertFalse(reply.stoppedAtOutputLimit)
        XCTAssertFalse(reply.refused)
    }

    /// A Mistral model that reasons anyway answers a list of chunks: the
    /// `text` chunks are the answer, concatenated in order; the trace and
    /// unknown chunk types never reach the user's document.
    func testMistralReplyKeepsTextChunksAndDropsThinking() {
        let reply = Self.configuration(.mistral).reply(toResponseObject: [
            "choices": [[
                "message": [
                    "content": [
                        ["type": "thinking", "thinking": [["type": "text", "text": "French spacing."]]],
                        ["type": "text", "text": "Are you coming"],
                        ["type": "something_new", "text": "IGNORED"],
                        ["type": "text", "text": " tomorrow?"],
                    ],
                ],
            ]],
        ])
        XCTAssertEqual(reply.text, "Are you coming tomorrow?")
    }

    /// No text anywhere is no answer: the callers fail it.
    func testChatCompletionsReplyWithoutTextHasNone() {
        let configuration = Self.configuration(.mistral)
        let replies: [[String: Any]] = [
            ["choices": [["message": ["content": [["type": "thinking", "thinking": "hmm"]]]]]],
            ["choices": [["message": ["content": [] as [Any]]]]],
            ["choices": [] as [Any]],
            ["choices": [["message": ["role": "assistant"]]]],
        ]
        for json in replies {
            XCTAssertNil(configuration.reply(toResponseObject: json).text, "\(json)")
        }
    }

    func testCutRepliesAreMarkedOnEachShape() {
        for reason in ["length", "model_length"] {
            XCTAssertTrue(
                Self.configuration(.mistral).reply(toResponseObject: [
                    "choices": [["message": ["content": "Hel"], "finish_reason": reason]],
                ]).stoppedAtOutputLimit, reason)
        }
        for reason in ["max_tokens", "model_context_window_exceeded"] {
            XCTAssertTrue(
                Self.configuration(.anthropic).reply(toResponseObject: [
                    "stop_reason": reason, "content": [["type": "text", "text": "Hel"]],
                ]).stoppedAtOutputLimit, reason)
        }
        let refusal = Self.configuration(.anthropic).reply(toResponseObject: [
            "stop_reason": "refusal", "content": [["type": "text", "text": "I can"]],
        ])
        XCTAssertTrue(refusal.refused)
        XCTAssertFalse(refusal.stoppedAtOutputLimit)
    }

    /// A filtered reply carries the text before the cut: it must read as a
    /// refusal so the service falls back to the transcript, not commit a prefix.
    func testContentFilteredReplyIsRefusedOnChatShapes() {
        for shape in [LLMPolishingRequestShape.openAICompatible, .mistral] {
            let reply = Self.configuration(shape).reply(toResponseObject: [
                "choices": [["message": ["content": "The first sentence."], "finish_reason": "content_filter"]],
            ])
            XCTAssertTrue(reply.refused, "\(shape)")
            XCTAssertFalse(reply.stoppedAtOutputLimit, "\(shape)")
        }
    }

    /// The provider's error sentence can quote the request, and so the dictated
    /// text. The summary the session logs `.public` carries the status only.
    func testRejectionPublicSummaryOmitsProviderErrorText() throws {
        let canary = "private dictation: Project RedPanda acquisition"
        let body = String(
            decoding: try JSONSerialization.data(withJSONObject: ["error": ["message": "Invalid input: \(canary)"]]),
            as: UTF8.self)
        let failure = try XCTUnwrap(
            PolishOutcomeClassifier.failure(
                for: LLMPolishingError.requestFailed(statusCode: 400, body: body),
                endpointURL: URL(string: "http://127.0.0.1:8080")!))
        XCTAssertTrue(failure.message.contains(canary), "the alert copy keeps the provider's reason")
        XCTAssertTrue(failure.publicSummary.contains("HTTP 400"))
        XCTAssertFalse(failure.publicSummary.contains(canary))
    }

    /// Each shape reads its own server's keys only: no guessing the dialect
    /// from what a reply happens to contain.
    func testEachShapeReadsOnlyItsOwnReply() {
        let anthropicReply: [String: Any] = ["stop_reason": "max_tokens", "content": [["type": "text", "text": "Hi"]]]
        let chatReply: [String: Any] = ["choices": [["message": ["content": "Hi"], "finish_reason": "length"]]]

        let asChat = Self.configuration(.openAICompatible).reply(toResponseObject: anthropicReply)
        XCTAssertNil(asChat.text)
        XCTAssertFalse(asChat.stoppedAtOutputLimit)
        let asAnthropic = Self.configuration(.anthropic).reply(toResponseObject: chatReply)
        XCTAssertNil(asAnthropic.text)
        XCTAssertFalse(asAnthropic.stoppedAtOutputLimit)
    }
}
