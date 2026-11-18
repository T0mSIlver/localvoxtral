import Foundation
import localvoxtralTestSupport
import Synchronization
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

    /// Transcribe 3 takes phrases and commas (live API, 2026-11-04), so a
    /// term goes out as listed, whitespace runs collapsed.
    func testPhrasesKeepTheirSpacesAndCommas() {
        XCTAssertEqual(
            MistralBatchTranscription.contextBias(from: [
                " Claude  Code ", "useAuth.ts", "a, b", "", "   ", "vLLM\tserver",
            ]),
            ["Claude Code", "useAuth.ts", "a, b", "vLLM server"]
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

    func testTheRequestIsAMultipartPostWithTheWavAndOneFieldPerTerm() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        let request = MistralBatchTranscription.request(
            endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
            apiKey: "k-123",
            wav: wav,
            language: "en",
            contextBias: ["localvoxtral", "Claude Code"],
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
        append("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nvoxtral-mini-transcribe-3-0\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"context_bias\"\r\n\r\nlocalvoxtral\r\n")
        append("--B\r\nContent-Disposition: form-data; name=\"context_bias\"\r\n\r\nClaude Code\r\n")
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
        let body = Data(#"{"model":"voxtral-mini-transcribe-3-0","text":" Hello there.","usage":{}}"#.utf8)
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

    // MARK: - Upload measurement (#1867)

    #if !canImport(FoundationNetworking)
    /// The client reports how much of the body went out, which sizes the next
    /// pass's deadline. Linux's Foundation sends no body progress.
    func testTheClientMeasuresTheBodyItUploaded() async throws {
        let server = try FakeLoopbackHTTPServer()
        addTeardownBlock { server.stop() }
        let wav = Data(repeating: 1, count: 1_000_000)
        let measurements = Mutex<[MistralBatchTranscription.UploadMeasurement]>([])
        let reported = expectation(description: "the upload was measured")

        _ = try? await MistralBatchTranscriptionClient().transcribe(
            wav: wav, language: nil, contextBias: [], apiKey: "k",
            endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/transcriptions")!,
            onUpload: { measurement in
                measurements.withLock { $0.append(measurement) }
                reported.fulfill()
            }
        )

        await fulfillment(of: [reported], timeout: 10)
        let measured = measurements.withLock { $0 }
        XCTAssertEqual(measured.count, 1)
        XCTAssertGreaterThan(measured.first?.bytes ?? 0, Int64(wav.count), "the multipart body holds the WAV")
        XCTAssertNotNil(measured.first?.bytesPerSecond)
    }

    /// The request can return before the session's delegate queue ran the
    /// upload's progress callbacks (LVX-20). Held shut until the request has
    /// returned, the queue still delivers the measurement once it runs.
    func testTheMeasurementSurvivesProgressThatRunsAfterTheRequestReturned() async throws {
        let server = try FakeLoopbackHTTPServer()
        addTeardownBlock { server.stop() }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: queue)
        addTeardownBlock { session.invalidateAndCancel() }
        let gate = DispatchSemaphore(value: 0)
        queue.addOperation { gate.wait() }
        let wav = Data(repeating: 1, count: 1_000_000)
        let measurements = Mutex<[MistralBatchTranscription.UploadMeasurement]>([])
        let reported = expectation(description: "the upload was measured")

        let returned = BoundedWait()
        let request = Task {
            _ = try? await MistralBatchTranscriptionClient(session: session).transcribe(
                wav: wav, language: nil, contextBias: [], apiKey: "k",
                endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/transcriptions")!,
                onUpload: { measurement in
                    measurements.withLock { $0.append(measurement) }
                    reported.fulfill()
                }
            )
            returned.resolve()
        }
        let returnedWhileHeld = await returned.value(failAfter: 10)
        gate.signal()
        XCTAssertTrue(returnedWhileHeld, "the request waited for the delegate queue")
        await request.value

        await fulfillment(of: [reported], timeout: 10)
        let measured = measurements.withLock { $0 }
        XCTAssertEqual(measured.count, 1)
        XCTAssertGreaterThan(measured.first?.bytes ?? 0, Int64(wav.count))
    }
    #endif
}
