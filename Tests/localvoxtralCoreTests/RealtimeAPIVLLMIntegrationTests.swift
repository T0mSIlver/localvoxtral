import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

/// The realtime client against a live OpenAI-Realtime server: the Mac's STT
/// test service in the STT lane, or vLLM on a Linux GPU box
/// (`scripts/linux/voxtral-vllm.sh`). The microphone tests need the app and
/// live in the app suite's class of the same name, so
/// `--filter RealtimeAPIVLLMIntegrationTests` still runs both halves on the Mac.
final class RealtimeAPIVLLMIntegrationTests: XCTestCase {
    private static let enableEnv = "VLLM_REALTIME_TEST_ENABLE"
    private static let endpointEnv = "VLLM_REALTIME_TEST_ENDPOINT"
    private static let modelEnv = "VLLM_REALTIME_TEST_MODEL"
    private static let apiKeyEnv = "VLLM_REALTIME_TEST_API_KEY"

    private func integrationConfiguration() throws -> RealtimeSessionConfiguration {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.enableEnv] == "1" else {
            throw XCTSkip(
                """
                vLLM realtime integration tests are disabled.
                Enable with \(Self.enableEnv)=1.
                Optional env vars:
                  \(Self.endpointEnv)=ws://127.0.0.1:8000/v1/realtime
                  \(Self.modelEnv)=mistralai/Voxtral-Mini-4B-Realtime-2602
                  \(Self.apiKeyEnv)=<api-key>
                """
            )
        }

        let endpointString = env[Self.endpointEnv] ?? "ws://127.0.0.1:8000/v1/realtime"
        guard let endpoint = URL(string: endpointString) else {
            throw XCTSkip("Invalid \(Self.endpointEnv): \(endpointString)")
        }

        let model = env[Self.modelEnv] ?? "mistralai/Voxtral-Mini-4B-Realtime-2602"
        let apiKey = env[Self.apiKeyEnv] ?? env["OPENAI_API_KEY"] ?? ""

        return .init(endpoint: endpoint, apiKey: apiKey, model: model)
    }

    func testVLLMHandshakeAndDisconnectCycle() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeAPIWebSocketClient()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                connected.fulfill()
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    sessionReady.fulfill()
                }
            case .error:
                realtimeError.fulfill()
            case .disconnected:
                disconnected.fulfill()
            default:
                break
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [connected, sessionReady], timeout: 20.0)

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.2)
    }

    func testVLLMClientCanReconnectAcrossTwoCycles() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeAPIWebSocketClient()

        try await runHandshakeCycle(client: client, configuration: configuration)
        try await runHandshakeCycle(client: client, configuration: configuration)
    }

    func testVLLMDisconnectWithPendingAudio() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeAPIWebSocketClient()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                connected.fulfill()
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    sessionReady.fulfill()
                }
            case .error:
                realtimeError.fulfill()
            case .disconnected:
                disconnected.fulfill()
            default:
                break
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [connected, sessionReady], timeout: 20.0)

        client.sendAudioChunk(makeSineWavePCM16Chunk())
        client.disconnect()

        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.5)
    }

    // `say` exists only on macOS.
    #if os(macOS)
    /// End-to-end quality check that enforces minimum transcript accuracy
    /// for synthetic spoken audio streamed over the realtime websocket client.
    func testVLLMProcessesSpokenSyntheticAudio_meetsExpectedAccuracy() async throws {
        let configuration = try integrationConfiguration()
        let longPhrase = [
            "hello from localvoxtral realtime test.",
            "this is a longer synthetic audio passage for integration testing.",
            "we are verifying that the vllm realtime server performs generation and returns transcript text.",
            "the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks.",
            "if this transcript is non empty, end to end processing is confirmed.",
        ].joined(separator: " ")
        let spokenPCM16 = try IntegrationTestSupport.makeSpokenPCM16Data(phrase: longPhrase)
        XCTAssertGreaterThan(
            spokenPCM16.count,
            100_000,
            "Expected a longer spoken synthetic audio clip for this test."
        )
        let spokenChunks = IntegrationTestSupport.splitPCM16IntoChunks(spokenPCM16, chunkSizeBytes: 3_200)
        let client = RealtimeAPIWebSocketClient()
        let finalTexts = NSLockingStringCollector()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let finalTranscript = expectation(description: "final transcript")
        finalTranscript.assertForOverFulfill = false
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                connected.fulfill()
                // Safe to enqueue before session.created; client gates outbound sends
                // until session readiness.
                for chunk in spokenChunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: false)
                client.sendCommit(final: true)
            case .status(let message):
                guard message.localizedCaseInsensitiveContains("session ready") else { return }
                sessionReady.fulfill()
            case .finalTranscript(let text):
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return }
                finalTexts.append(normalized)
                finalTranscript.fulfill()
            case .error:
                realtimeError.fulfill()
            case .disconnected:
                disconnected.fulfill()
            default:
                break
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [connected, sessionReady, finalTranscript], timeout: 60.0)
        try await Task.sleep(for: .seconds(2))

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.2)

        let combinedFinalTranscript = finalTexts.snapshot().joined(separator: " ")
        let wordAccuracy = IntegrationTestSupport.wordAccuracy(
            expected: longPhrase,
            actual: combinedFinalTranscript
        )
        print(
            "speechd integration: word accuracy \(String(format: "%.3f", wordAccuracy)); "
                + "transcript: \(combinedFinalTranscript)"
        )
        XCTAssertGreaterThanOrEqual(
            wordAccuracy,
            0.55,
            "Expected synthetic-audio transcript accuracy >= 0.55. Transcript: \(combinedFinalTranscript)"
        )
    }

    /// The backend half of the mid-dictation reconnect (#380): after a socket
    /// drops mid-utterance, the session that replaces it must transcribe the
    /// audio the gap buffered, delivered as the single burst the restarted send
    /// loop hands it. The view model's orchestration is unit-tested over
    /// injected clocks (`RealtimeReconnectTests`); what only a live backend can
    /// answer is whether the fresh session accepts the replay at all.
    func testVLLMReconnectedSessionTranscribesReplayedGapAudio() async throws {
        let configuration = try integrationConfiguration()
        let beforeDrop = "hello from localvoxtral, this is the first half of the passage."
        let afterDrop =
            "the connection dropped and came back, and these words were spoken into the gap."
        let beforeChunks = IntegrationTestSupport.splitPCM16IntoChunks(
            try IntegrationTestSupport.makeSpokenPCM16Data(phrase: beforeDrop),
            chunkSizeBytes: 3_200
        )
        // ONE Data, not chunks: this is exactly what the first tick of the
        // restarted audio-send loop drains out of AudioChunkBuffer.
        let gapAudio = try IntegrationTestSupport.makeSpokenPCM16Data(phrase: afterDrop)

        let client = RealtimeAPIWebSocketClient()

        // Leg 1: stream up to the drop.
        let firstReady = expectation(description: "first session ready")
        let firstTranscript = expectation(description: "first transcript")
        firstTranscript.assertForOverFulfill = false
        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                for chunk in beforeChunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: false)
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    firstReady.fulfill()
                }
            case .partialTranscript(let text), .finalTranscript(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstTranscript.fulfill()
                }
            default:
                break
            }
        }
        try client.connect(configuration: configuration)
        await fulfillment(of: [firstReady, firstTranscript], timeout: 60.0)

        // The drop. From the session's side a socket that died and one that was
        // closed look the same: a `.disconnected` it did not ask for.
        let dropped = expectation(description: "dropped")
        client.setEventHandler { event, _ in
            if case .disconnected = event { dropped.fulfill() }
        }
        client.disconnect()
        await fulfillment(of: [dropped], timeout: 5.0)

        // Leg 2: the reconnect replays the gap on a brand-new session.
        let replayTexts = NSLockingStringCollector()
        let secondReady = expectation(description: "second session ready")
        let replayTranscript = expectation(description: "replayed transcript")
        replayTranscript.assertForOverFulfill = false
        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                client.sendAudioChunk(gapAudio)
                client.sendCommit(final: false)
                client.sendCommit(final: true)
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    secondReady.fulfill()
                }
            case .finalTranscript(let text):
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return }
                replayTexts.append(normalized)
                replayTranscript.fulfill()
            default:
                break
            }
        }
        try client.connect(configuration: configuration)
        await fulfillment(of: [secondReady, replayTranscript], timeout: 60.0)
        client.disconnect()

        let replayed = replayTexts.snapshot().joined(separator: " ")
        let accuracy = IntegrationTestSupport.wordAccuracy(expected: afterDrop, actual: replayed)
        print(
            "speechd reconnect integration: replayed word accuracy "
                + "\(String(format: "%.3f", accuracy)); transcript: \(replayed)"
        )
        XCTAssertGreaterThanOrEqual(
            accuracy,
            0.55,
            "The session after the drop must transcribe the replayed gap audio. Transcript: \(replayed)"
        )
    }
    #endif

    private func runHandshakeCycle(
        client: RealtimeAPIWebSocketClient,
        configuration: RealtimeSessionConfiguration
    ) async throws {
        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event, _ in
            switch event {
            case .connected:
                connected.fulfill()
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    sessionReady.fulfill()
                }
            case .error:
                realtimeError.fulfill()
            case .disconnected:
                disconnected.fulfill()
            default:
                break
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [connected, sessionReady], timeout: 20.0)
        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.2)
    }

    private func makeSineWavePCM16Chunk() -> Data {
        let sampleRate = 16_000.0
        let frequency = 440.0
        let duration = 0.2
        let amplitude = 12_000.0
        let frameCount = Int(sampleRate * duration)

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            let time = Double(index) / sampleRate
            let value = sin(2 * .pi * frequency * time) * amplitude
            samples.append(Int16(clamping: Int(value)).littleEndian)
        }

        return samples.withUnsafeBytes { Data($0) }
    }
}

private final class NSLockingStringCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
