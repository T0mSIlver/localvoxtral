import Foundation
import Synchronization
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// The usage ledger as the app feeds it: requests the app builds (term
/// suggestions, the prompt warmup) and its realtime sockets. The ledger and the
/// polish client are tested in the core suite (`UsageLedgerTests`).
final class UsageLedgerAppTests: XCTestCase {
    private func polishConfiguration(
        shape: LLMPolishingRequestShape = .mistral,
        model: String = "mistral-medium-latest"
    ) -> LLMPolishingConfiguration {
        LLMPolishingConfiguration(
            endpointURL: URL(string: "https://\(StubHTTPProtocol.host)")!,
            apiKey: "k",
            model: model,
            requestShape: shape
        )
    }

    private let polishRequest = LLMPolishingRequest(
        inputText: "hello", systemPrompt: "s", userPrompts: ["u"])

    private func withStub<T>(_ reply: StubHTTPProtocol.Reply, _ body: () async throws -> T)
        async rethrows -> T
    {
        StubHTTPProtocol.reply.withLock { $0 = reply }
        return try await body()
    }

    private static let successBody = """
        {"model":"mistral-medium-3-5","choices":[{"message":{"role":"assistant","content":"Hello."}}],
         "usage":{"prompt_tokens":1000,"completion_tokens":200,"total_tokens":1200,
                  "prompt_tokens_details":{"cached_tokens":400}}}
        """

    func testEachRequestIsChargedToItsFeatureAndBackend() async throws {
        let ledger = UsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger, session: StubHTTPProtocol.session())
        let bundled = LLMPolishingConfiguration(
            endpointURL: URL(string: "https://\(StubHTTPProtocol.host)")!,
            apiKey: "", model: "m", usageBackend: .bundledHelper)
        let suggestions = SpeakerTermSuggestions.request(
            dictations: [.init(raw: "hello", final: "hello")], terms: [], dismissed: [])

        _ = try await withStub(.http(200, Self.successBody)) {
            _ = try await service.polish(request: suggestions, configuration: polishConfiguration())
            _ = try await service.polish(request: polishRequest, configuration: bundled)
            // The warmup's throwaway on the bundled helper is not counted.
            _ = try await service.polish(
                request: PolishPromptWarmup.request(templates: LLMPromptTemplates(
                    systemContent: "s", userContent: "{{input_text}}")),
                configuration: bundled)
        }

        XCTAssertEqual(ledger.entries().map(\.feature), [.termSuggestions, .polish])
        XCTAssertEqual(ledger.entries().map(\.backend), [.mistral, .bundledHelper])
        // A term suggestion is Mistral spend, and not a polish.
        let summary = MistralUsageSummary(entries: ledger.entries(), since: nil)
        XCTAssertEqual(summary.polishCount, 0)
        XCTAssertEqual(summary.otherCount, 1)
        XCTAssertEqual(summary.costEUR, try XCTUnwrap(ledger.entries().first?.costEUR), accuracy: 1e-12)
    }
}

#if DEBUG
extension UsageLedgerAppTests {
    // MARK: - Dictation sockets

    /// The primed task is never resumed, so its `send` completions do not
    /// fire until cleanup cancels it; a completion error mid-test would close
    /// the socket early and fail the audio-seconds assertions loudly.
    private func makePrimedClient(sessionCreated: Bool)
        -> (MistralRealtimeWebSocketClient, UsageLedger, () -> Void)
    {
        let client = MistralRealtimeWebSocketClient()
        let ledger = UsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        client.debugPrimeConnectedStateForTesting(
            task: task,
            isUserInitiatedDisconnect: true,
            hasReceivedSessionCreated: sessionCreated,
            usageModel: MistralRealtimeWebSocketClient.defaultModel
        )
        return (client, ledger, {
            task.cancel()
            session.invalidateAndCancel()
        })
    }

    /// One second of 16 kHz mono S16 PCM.
    private var oneSecond: Data { Data(count: 32_000) }

    func testSocketRecordsTheAudioItSentOnceWhenItCloses() throws {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: true)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.sendAudioChunk(oneSecond)
        client.disconnect()
        client.disconnect()

        XCTAssertEqual(ledger.entries().count, 1)
        let entry = try XCTUnwrap(ledger.entries().first)
        XCTAssertEqual(entry.feature, .dictation)
        XCTAssertEqual(entry.model, MistralRealtimeWebSocketClient.defaultModel)
        XCTAssertEqual(entry.audioSeconds, 2)
        XCTAssertEqual(try XCTUnwrap(entry.costEUR), 2.0 / 60 * 0.0071, accuracy: 1e-12)
    }

    func testAudioQueuedBeforeTheSessionOpenedIsNotCounted() {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: false)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.disconnect()

        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testQueuedAudioCountsOnceTheSessionOpens() {
        let (client, ledger, cleanup) = makePrimedClient(sessionCreated: false)
        defer { cleanup() }

        client.sendAudioChunk(oneSecond)
        client.debugHandleFrameForTesting(json: ["type": "session.created", "session": ["model": "m"]])
        client.sendAudioChunk(oneSecond)
        client.disconnect()

        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [2])
    }

    func testSocketFailureRecordsTheAudioSentBeforeIt() {
        let client = MistralRealtimeWebSocketClient()
        let ledger = UsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        client.debugPrimeConnectedStateForTesting(
            task: task, isUserInitiatedDisconnect: true, hasReceivedSessionCreated: true,
            usageModel: MistralRealtimeWebSocketClient.defaultModel)

        client.sendAudioChunk(oneSecond)
        client.debugHandleTerminalSocketErrorForTesting(task: task, errorMessage: "boom")
        client.disconnect()

        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [1])
    }
}
#endif
