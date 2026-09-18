import Foundation
import XCTest
@testable import localvoxtral

/// Live lane for the hosted Mistral realtime transcription API.
///
/// Enablement (either one; skips otherwise):
/// - `MISTRAL_API_KEY` in the environment (direct runs on a Mac), or
/// - the gitignored marker `.mistral-integration-enable.json` at the repo root
///   (`{"apiKey": "...", "model"?: "...", "endpoint"?: "..."}`), written by
///   `./scripts/remote-build.sh integration-mistral` — the SSH build gate
///   allowlists exact `swift test ...` payloads, so enablement has to travel
///   inside the rsynced tree rather than as a per-run env prefix.
///
/// This lane costs real money (0.006 USD/min of audio) and is never wired into
/// CI; it is run by hand before shipping a change to the Mistral wire path.
final class MistralRealtimeIntegrationTests: XCTestCase {
    private static let apiKeyEnv = "MISTRAL_API_KEY"
    private static let modelEnv = "MISTRAL_REALTIME_TEST_MODEL"
    private static let endpointEnv = "MISTRAL_REALTIME_TEST_ENDPOINT"
    private static let markerFileName = ".mistral-integration-enable.json"

    private struct MarkerConfig: Decodable {
        let apiKey: String?
        let model: String?
        let endpoint: String?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // localvoxtralTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func integrationConfiguration() throws -> RealtimeSessionConfiguration {
        let env = ProcessInfo.processInfo.environment
        var apiKey = env[Self.apiKeyEnv]?.trimmed ?? ""
        var model = env[Self.modelEnv]?.trimmed ?? ""
        var endpointString = env[Self.endpointEnv]?.trimmed ?? ""

        if apiKey.isEmpty {
            let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
            guard FileManager.default.fileExists(atPath: markerURL.path) else {
                throw XCTSkip(
                    """
                    Mistral realtime integration tests are disabled.
                    Enable with \(Self.apiKeyEnv)=<key> in the environment, or run
                    ./scripts/remote-build.sh integration-mistral from the dev box
                    (it writes the marker \(Self.markerFileName) into the synced tree).
                    """
                )
            }
            let marker = try JSONDecoder().decode(
                MarkerConfig.self, from: Data(contentsOf: markerURL))
            apiKey = marker.apiKey?.trimmed ?? ""
            if model.isEmpty { model = marker.model?.trimmed ?? "" }
            if endpointString.isEmpty { endpointString = marker.endpoint?.trimmed ?? "" }
        }

        guard !apiKey.isEmpty else {
            throw XCTSkip("Mistral integration enablement carried no API key.")
        }

        let endpoint: URL
        if endpointString.isEmpty {
            endpoint = MistralRealtimeWebSocketClient.defaultEndpoint
        } else {
            guard let parsed = URL(string: endpointString) else {
                throw XCTSkip("Invalid Mistral endpoint: \(endpointString)")
            }
            endpoint = parsed
        }

        return RealtimeSessionConfiguration(endpoint: endpoint, apiKey: apiKey, model: model)
    }

    // MARK: - (a) Handshake

    func testMistralHandshakeAndDisconnectCycle() async throws {
        let configuration = try integrationConfiguration()
        let client = MistralRealtimeWebSocketClient()

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
        await fulfillment(of: [connected, sessionReady], timeout: 30.0)

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.2)
    }

    // MARK: - (b) Real transcription

    func testMistralTranscribesSyntheticSpeechAndFinalizes() async throws {
        let configuration = try integrationConfiguration()
        let phrase = [
            "hello from localvoxtral realtime test.",
            "this is a longer synthetic audio passage for integration testing.",
            "we are verifying that the mistral realtime service returns transcript text.",
            "the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks.",
            "if this transcript is non empty, end to end processing is confirmed.",
        ].joined(separator: " ")

        let spokenPCM16 = try IntegrationTestSupport.makeSpokenPCM16Data(phrase: phrase)
        XCTAssertGreaterThan(
            spokenPCM16.count, 100_000,
            "Expected a longer spoken synthetic audio clip for this test."
        )
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(
            spokenPCM16, chunkSizeBytes: 3_200)

        let client = MistralRealtimeWebSocketClient()
        let ledger = MistralUsageLedger(fileURL: nil)
        client.setUsageRecorder(ledger)
        let deltas = LockedStrings()
        let finals = LockedStrings()
        let errors = LockedStrings()

        let sessionReady = expectation(description: "session ready")
        let finalized = expectation(description: "transcription finalized")

        client.setEventHandler { event in
            switch event {
            case .status(let message):
                guard message.localizedCaseInsensitiveContains("session ready") else { return }
                sessionReady.fulfill()
                for chunk in chunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: true)
            case .partialTranscript(let delta):
                deltas.append(delta)
            case .finalTranscript(let text):
                finals.append(text)
            case .transcriptionFinalized:
                finalized.fulfill()
            case .error(let message):
                errors.append(message)
            default:
                break
            }
        }

        try client.connect(configuration: configuration)
        await fulfillment(of: [sessionReady], timeout: 30.0)
        await fulfillment(of: [finalized], timeout: 120.0)

        client.disconnect()

        XCTAssertTrue(
            errors.snapshot().isEmpty,
            "Mistral reported errors during transcription: \(errors.snapshot())"
        )

        // The ledger counts the audio this client put on the wire — every
        // chunk, since all of them went out after session.created.
        let usage = ledger.entries()
        XCTAssertEqual(usage.count, 1, "One socket, one ledger entry: \(usage)")
        XCTAssertEqual(usage.first?.audioSeconds, Double(spokenPCM16.count) / 32_000)
        XCTAssertNotNil(usage.first?.costEUR, "The realtime model must be priced")
        print("mistral integration: ledger \(usage)")

        let doneText = finals.snapshot().joined(separator: " ")
        let accuracy = IntegrationTestSupport.wordAccuracy(expected: phrase, actual: doneText)
        print(
            "mistral integration: word accuracy \(String(format: "%.3f", accuracy)); "
                + "transcript: \(doneText)"
        )
        XCTAssertGreaterThanOrEqual(
            accuracy, 0.55,
            "Expected synthetic-audio transcript accuracy >= 0.55. Transcript: \(doneText)"
        )

        // Mistral's delta stream is append-only, so the concatenated deltas are
        // a prefix of (usually equal to) the done transcript. A violation here
        // means the delta/done contract the view model merges on has changed.
        let concatenatedDeltas = Self.normalizedForParity(deltas.snapshot().joined())
        let normalizedDone = Self.normalizedForParity(doneText)
        XCTAssertFalse(concatenatedDeltas.isEmpty, "Expected at least one text delta.")
        XCTAssertTrue(
            normalizedDone == concatenatedDeltas || normalizedDone.hasPrefix(concatenatedDeltas),
            """
            Delta/done parity broken.
            deltas: \(concatenatedDeltas)
            done:   \(normalizedDone)
            """
        )
    }

    // MARK: - (d) Polish usage

    /// A real chat/completions answer carries the `usage` the ledger prices.
    /// Eight output tokens at most: this costs a small fraction of a cent.
    func testMistralPolishReportsUsageTheLedgerPrices() async throws {
        let apiKey = try integrationConfiguration().apiKey
        let ledger = MistralUsageLedger(fileURL: nil)
        let service = LLMPolishingService(usageRecorder: ledger)

        _ = try await service.polish(
            request: LLMPolishingRequest(
                inputText: "hello world",
                systemPrompt: "Repeat the user's text.",
                userPrompts: ["hello world"],
                maxTokens: 8
            ),
            configuration: LLMPolishingConfiguration(
                endpointURL: MistralPolishDefaults.endpoint,
                apiKey: apiKey,
                model: MistralPolishDefaults.model,
                requestShape: .mistral
            )
        )

        let usage = ledger.entries()
        print("mistral integration: polish ledger \(usage)")
        XCTAssertEqual(usage.count, 1)
        let entry = try XCTUnwrap(usage.first)
        XCTAssertGreaterThan(entry.promptTokens ?? 0, 0)
        XCTAssertGreaterThan(entry.completionTokens ?? 0, 0)
        XCTAssertGreaterThan(entry.costEUR ?? 0, 0, "The answering model must be priced: \(entry.model)")
    }

    // MARK: - (c) Bogus key

    func testMistralRejectsABogusAPIKeyWithAnUnauthorizedError() async throws {
        // Proves the 401 UX path end to end for free: the request is rejected
        // at the upgrade, so no audio is ever billed.
        _ = try integrationConfiguration()

        let client = MistralRealtimeWebSocketClient()
        let errors = LockedStrings()
        let failed = expectation(description: "realtime error")
        failed.assertForOverFulfill = false

        client.setEventHandler { event in
            guard case .error(let message) = event else { return }
            errors.append(message)
            failed.fulfill()
        }

        try client.connect(
            configuration: RealtimeSessionConfiguration(
                endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
                apiKey: "sk-localvoxtral-deliberately-invalid",
                model: ""
            )
        )
        await fulfillment(of: [failed], timeout: 30.0)
        client.disconnect()

        let message = errors.snapshot().joined(separator: " | ")
        XCTAssertTrue(
            message.contains("401"),
            "Expected the HTTP status in the socket error, got: \(message)"
        )
        XCTAssertEqual(
            RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message),
            .unauthorized,
            "A rejected key must classify as .unauthorized, not .endpointRejected"
        )
    }

    private static func normalizedForParity(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

private final class LockedStrings: @unchecked Sendable {
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
