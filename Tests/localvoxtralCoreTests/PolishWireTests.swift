import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// The polishing server's dialect (#1851): each shape reads only its own
/// reply, and quick capture speaks the same dialect polish does.
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

    // MARK: - Quick capture on Anthropic

    private func answering(_ body: String, _ send: () async throws -> Void) async rethrows {
        let previous = StubHTTPProtocol.reply.withLock { $0 }
        StubHTTPProtocol.reply.withLock { $0 = .http(200, body) }
        defer { StubHTTPProtocol.reply.withLock { $0 = previous } }
        try await send()
    }

    private static let options = [
        QuickCaptureOption(id: "quill", projectKey: "/w/quill", description: "Project quill."),
        QuickCaptureOption(id: QuickCaptureRouting.catchAllID, projectKey: nil, description: "Anything else."),
    ]

    /// The router reads Anthropic's text block, skips its thinking, and
    /// bills the call with Anthropic's usage.
    func testTheRouterReadsAnAnthropicReply() async throws {
        let ledger = UsageLedger(fileURL: nil)
        let classifier = QuickCaptureChatClassifier(
            configuration: Self.configuration(.anthropic), session: StubHTTPProtocol.session(), usageRecorder: ledger)
        try await answering(#"""
            {"model":"m","stop_reason":"end_turn",
             "content":[{"type":"thinking","thinking":"{\"project\":\"inbox\"}","signature":"x"},
                        {"type":"text","text":"{\"project\":\"quill\",\"confidence\":0.9}"}],
             "usage":{"input_tokens":10,"cache_read_input_tokens":900,"output_tokens":7}}
            """#) {
            let probabilities = try await classifier.classify(capture: "c", options: Self.options)
            XCTAssertEqual(probabilities, ["quill": 0.9])
        }
        try await answering(#"""
            {"stop_reason":"refusal","content":[{"type":"text","text":"{\"project\":\"quill\",\"confidence\":0.95}"}]}
            """#) {
            do {
                _ = try await classifier.classify(capture: "c", options: Self.options)
                XCTFail("a refusal was routed")
            } catch {
                XCTAssertEqual(error as? QuickCaptureChatRouting.Failure, .malformedResponse)
            }
        }
        XCTAssertEqual(ledger.entries().map(\.feature), [.quickCaptureRouting, .quickCaptureRouting])
        XCTAssertEqual(ledger.entries().first?.promptTokens, 910)
        XCTAssertEqual(ledger.entries().first?.completionTokens, 7)
    }

    /// A first draft cut at Anthropic's `max_tokens` is too large, as a cut
    /// chat/completions one is, and never a half-written draft.
    func testAFirstDraftCutOnAnthropicIsTooLarge() async {
        let drafter = QuickCaptureFirstDrafter(
            configuration: Self.configuration(.anthropic), session: StubHTTPProtocol.session())
        await answering(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\"kind\":\"issue\",\"ti"}]}"#) {
            let outcome = await drafter.firstDraft(capture: "c", projectName: "quill", context: QuickCaptureContext())
            XCTAssertEqual(outcome, .failed(.outputTooLarge))
        }
        await answering(#"""
            {"stop_reason":"end_turn","content":[{"type":"text",
             "text":"{\"kind\":\"note\",\"title\":\"T\",\"body\":\"B\",\"relation\":\"none\",\"issue\":null}"}]}
            """#) {
            let outcome = await drafter.firstDraft(capture: "c", projectName: "quill", context: QuickCaptureContext())
            guard case .draft(let draft, _) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(draft.kind, .note)
        }
    }

    // MARK: - Replay configuration

    func testAReplayNamesOnlySettingsThatExist() throws {
        let mistral = try LLMPolishingConfiguration.replay(
            url: URL(string: "https://api.mistral.ai/v1/chat/completions")!, apiKey: "k", model: "m",
            extra: #"{"reasoning_effort":"none"}"#)
        XCTAssertEqual(mistral.requestShape, .mistral)
        XCTAssertEqual(mistral.mistralReasoningEffort, .off)
        XCTAssertEqual(
            try LLMPolishingConfiguration.replay(url: URL(string: "https://api.anthropic.com")!, apiKey: "k", model: "m")
                .requestShape,
            .anthropic)
        XCTAssertThrowsError(
            try LLMPolishingConfiguration.replay(
                url: URL(string: "http://127.0.0.1:8080")!, apiKey: "", model: "m", extra: #"{"top_k":20}"#)
        ) { XCTAssertEqual($0 as? LLMPolishingConfiguration.ReplayError, .unknownField("top_k")) }
    }
}
