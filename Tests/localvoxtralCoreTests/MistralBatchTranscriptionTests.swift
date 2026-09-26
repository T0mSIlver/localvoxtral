import Foundation
import XCTest
@testable import localvoxtralCore

final class MistralBatchTranscriptionTests: XCTestCase {
    // MARK: - Endpoint

    func testTheBatchEndpointSitsOnTheRealtimeSocketsHost() {
        let realtime = URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!
        XCTAssertEqual(
            MistralBatchTranscription.endpoint(forRealtimeEndpoint: realtime)?.absoluteString,
            "https://api.mistral.ai/v1/audio/transcriptions"
        )
        let local = URL(string: "ws://127.0.0.1:9000/v1/audio/transcriptions/realtime?x=1")!
        XCTAssertEqual(
            MistralBatchTranscription.endpoint(forRealtimeEndpoint: local)?.absoluteString,
            "http://127.0.0.1:9000/v1/audio/transcriptions"
        )
    }

    func testAnEndpointOfAnotherShapeGetsNoSecondPass() {
        for string in [
            "https://api.mistral.ai/v1/audio/transcriptions/realtime",
            "wss://api.mistral.ai/v1/realtime-other",
            "wss://api.mistral.ai/v1/audio/transcriptions",
        ] {
            XCTAssertNil(
                MistralBatchTranscription.endpoint(forRealtimeEndpoint: URL(string: string)!),
                string
            )
        }
    }

    // MARK: - Terms

    func testPhrasesAreJoinedWithUnderscoresAndCommasDropped() {
        XCTAssertEqual(
            MistralBatchTranscription.contextBias(from: [
                " Claude  Code ", "useAuth.ts", "a, b", "", "   ", "vLLM\tserver",
            ]),
            ["Claude_Code", "useAuth.ts", "vLLM_server"]
        )
    }

    func testTheFirstSpellingOfATermWinsAndTheListStopsAtAHundred() {
        let many = (0..<150).map { "term\($0)" }
        let terms = MistralBatchTranscription.contextBias(from: ["Qwen", "qwen", "QWEN"] + many)
        XCTAssertEqual(terms.count, MistralBatchTranscription.maxContextBiasTerms)
        XCTAssertEqual(terms.first, "Qwen")
        XCTAssertEqual(terms[1], "term0")
        XCTAssertEqual(terms.last, "term98")
    }

    // MARK: - Wire shape

    func testAPhraseTheModelWritesAsSentGetsItsSpacesBack() {
        let candidates = ["Claude Code", "polish_context", "Vibe CLI"]
        XCTAssertEqual(
            MistralBatchTranscription.restoringPhrases(
                in: "Ask Claude_Code, not vibe_cli, about polish_context and Claude_Codex.",
                candidates: candidates),
            "Ask Claude Code, not Vibe CLI, about polish_context and Claude_Codex.")
    }

    func testTheRequestIsAMultipartPostWithTheWavAndOneFieldPerTerm() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        let request = MistralBatchTranscription.request(
            endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
            apiKey: "k-123",
            wav: wav,
            language: "en",
            contextBias: ["localvoxtral", "Claude_Code"],
            boundary: "B",
            timeout: 30
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")

        var expected = Data()
        func append(_ s: String) { expected.append(contentsOf: Array(s.utf8)) }
        append("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        expected.append(wav)
        append("\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nvoxtral-mini-latest\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"context_bias\"\r\n\r\nlocalvoxtral\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"context_bias\"\r\n\r\nClaude_Code\r\n")
        append("--B--\r\n")
        XCTAssertEqual(request.httpBody, expected)
    }

    func testNoLanguageAndNoTermsSendNeitherField() throws {
        let body = MistralBatchTranscription.multipartBody(
            wav: Data([1]), language: nil, contextBias: [], boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("name=\"context_bias\""))
        XCTAssertTrue(text.contains("name=\"model\""))
    }

    // MARK: - Response

    func testASuccessfulAnswerYieldsItsText() throws {
        let body = Data(#"{"model":"voxtral-mini-latest","text":" Hello there.","usage":{}}"#.utf8)
        XCTAssertEqual(
            try MistralBatchTranscription.result(status: 200, body: body).text, " Hello there.")
    }

    func testAnErrorAnswerCarriesTheAPIsMessage() {
        let body = Data(#"{"object":"error","message":"Context bias item 'a b' must not contain commas or whitespace","code":"3051"}"#.utf8)
        XCTAssertThrowsError(try MistralBatchTranscription.result(status: 400, body: body)) {
            XCTAssertEqual(
                $0 as? MistralBatchTranscription.Failure,
                .http(status: 400, message: "Context bias item 'a b' must not contain commas or whitespace")
            )
        }
        XCTAssertThrowsError(try MistralBatchTranscription.result(status: 200, body: Data("{}".utf8))) {
            XCTAssertEqual($0 as? MistralBatchTranscription.Failure, .malformedResponse)
        }
    }
}
