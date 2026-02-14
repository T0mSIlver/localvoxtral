import Foundation
import XCTest
@testable import supervoxtral

final class RealtimeWebSocketVLLMIntegrationTests: XCTestCase {
    private static let enableEnv = "VLLM_REALTIME_TEST_ENABLE"
    private static let endpointEnv = "VLLM_REALTIME_TEST_ENDPOINT"
    private static let modelEnv = "VLLM_REALTIME_TEST_MODEL"
    private static let apiKeyEnv = "VLLM_REALTIME_TEST_API_KEY"

    private func integrationConfiguration() throws -> RealtimeWebSocketClient.Configuration {
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
        let client = RealtimeWebSocketClient()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event in
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
        let client = RealtimeWebSocketClient()

        try await runHandshakeCycle(client: client, configuration: configuration)
        try await runHandshakeCycle(client: client, configuration: configuration)
    }

    func testVLLMDisconnectAfterFinalCommitWithAudio() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeWebSocketClient()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event in
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
        client.disconnectAfterFinalCommitIfNeeded()

        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.5)
    }

    private func runHandshakeCycle(
        client: RealtimeWebSocketClient,
        configuration: RealtimeWebSocketClient.Configuration
    ) async throws {
        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event in
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
