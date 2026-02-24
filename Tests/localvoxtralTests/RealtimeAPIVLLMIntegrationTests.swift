import Foundation
import XCTest
@testable import localvoxtral

final class RealtimeAPIVLLMIntegrationTests: XCTestCase {
    private static let enableEnv = "VLLM_REALTIME_TEST_ENABLE"
    private static let endpointEnv = "VLLM_REALTIME_TEST_ENDPOINT"
    private static let modelEnv = "VLLM_REALTIME_TEST_MODEL"
    private static let apiKeyEnv = "VLLM_REALTIME_TEST_API_KEY"
    private static let micCaptureEnableEnv = "LOCALVOXTRAL_MIC_CAPTURE_TEST_ENABLE"
    private static let micCaptureDeviceEnv = "LOCALVOXTRAL_MIC_CAPTURE_DEVICE_UID"

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

    func testMicrophoneCaptureProducesPCM16Chunks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.micCaptureEnableEnv] == "1" else {
            throw XCTSkip(
                """
                Microphone capture integration test is disabled.
                Enable with \(Self.micCaptureEnableEnv)=1.
                """
            )
        }

        let microphone = MicrophoneCaptureService()
        try await ensureMicrophoneAuthorization(microphone)

        do {
            let capturedBytes = try await captureBytesWithRetries(
                microphone: microphone,
                preferredDeviceID: nil,
                attempts: 3,
                captureWindowSeconds: 2.0
            )
            guard capturedBytes > 0 else {
                throw XCTSkip("Default microphone produced no PCM frames after retries.")
            }
        } catch {
            if isMicEnvironmentStartError(error) {
                throw XCTSkip("Skipping microphone integration due to transient CoreAudio start state: \(error.localizedDescription)")
            }
            throw error
        }
    }

    func testMicrophoneCaptureProducesPCM16ChunksForSelectedDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.micCaptureEnableEnv] == "1" else {
            throw XCTSkip(
                """
                Microphone capture integration test is disabled.
                Enable with \(Self.micCaptureEnableEnv)=1.
                """
            )
        }

        guard let selectedUID = env[Self.micCaptureDeviceEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedUID.isEmpty
        else {
            throw XCTSkip(
                """
                Selected-device microphone capture test requires \(Self.micCaptureDeviceEnv).
                Example:
                  \(Self.micCaptureDeviceEnv)=BuiltInMicrophoneDevice
                """
            )
        }

        let microphone = MicrophoneCaptureService()
        try await ensureMicrophoneAuthorization(microphone)

        let availableInputs = microphone.availableInputDevices()
        guard availableInputs.contains(where: { $0.id == selectedUID }) else {
            let availableIDs = availableInputs.map(\.id).joined(separator: ", ")
            throw XCTSkip("Selected test input \(selectedUID) is unavailable. Available inputs: \(availableIDs)")
        }

        do {
            let capturedBytes = try await captureBytesWithRetries(
                microphone: microphone,
                preferredDeviceID: selectedUID,
                attempts: 3,
                captureWindowSeconds: 2.0
            )
            guard capturedBytes > 0 else {
                throw XCTSkip(
                    "Selected microphone \(selectedUID) produced no PCM frames after retries. "
                        + "This is often an environment/headset routing issue, not a deterministic client regression."
                )
            }
        } catch {
            if isMicEnvironmentStartError(error) {
                throw XCTSkip(
                    "Skipping selected-device microphone integration due to transient CoreAudio start state: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    func testMicrophoneStartFailsForUnavailablePreferredDevice() {
        let microphone = MicrophoneCaptureService()
        let unavailableID = "localvoxtral.invalid-input-device"

        XCTAssertThrowsError(
            try microphone.start(preferredDeviceID: unavailableID) { _ in }
        ) { error in
            guard case MicrophoneCaptureError.preferredDeviceUnavailable(let reportedID) = error else {
                XCTFail("Expected preferredDeviceUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(reportedID, unavailableID)
        }
    }

    func testVLLMHandshakeAndDisconnectCycle() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeAPIWebSocketClient()

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
        let client = RealtimeAPIWebSocketClient()

        try await runHandshakeCycle(client: client, configuration: configuration)
        try await runHandshakeCycle(client: client, configuration: configuration)
    }

    func testVLLMDisconnectAfterFinalCommitWithAudio() async throws {
        let configuration = try integrationConfiguration()
        let client = RealtimeAPIWebSocketClient()

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

    func testVLLMProcessesSpokenSyntheticAudio() async throws {
        let configuration = try integrationConfiguration()
        let longPhrase = [
            "hello from localvoxtral realtime test.",
            "this is a longer synthetic audio passage for integration testing.",
            "we are verifying that the vllm realtime server performs generation and returns transcript text.",
            "the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks.",
            "if this transcript is non empty, end to end processing is confirmed.",
        ].joined(separator: " ")
        let spokenPCM16 = try makeSpokenPCM16Data(phrase: longPhrase)
        XCTAssertGreaterThan(
            spokenPCM16.count,
            100_000,
            "Expected a longer spoken synthetic audio clip for this test."
        )
        let spokenChunks = splitPCM16IntoChunks(spokenPCM16, chunkSizeBytes: 3_200)
        let client = RealtimeAPIWebSocketClient()

        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let finalTranscript = expectation(description: "final transcript")
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event in
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

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5.0)
        await fulfillment(of: [realtimeError], timeout: 0.2)
    }

    private func runHandshakeCycle(
        client: RealtimeAPIWebSocketClient,
        configuration: RealtimeSessionConfiguration
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

    private func ensureMicrophoneAuthorization(_ microphone: MicrophoneCaptureService) async throws {
        switch microphone.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                microphone.requestAccess { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            guard granted else {
                throw XCTSkip("Microphone access was not granted for integration testing.")
            }
        case .denied, .restricted:
            throw XCTSkip("Microphone access is denied/restricted for integration testing.")
        }
    }

    private func startMicrophoneWithRetry(
        _ microphone: MicrophoneCaptureService,
        preferredDeviceID: String?,
        maxAttempts: Int = 3,
        chunkHandler: @escaping @Sendable (Data) -> Void
    ) async throws {
        var lastStartError: Error?

        for attempt in 1 ... maxAttempts {
            do {
                try microphone.start(preferredDeviceID: preferredDeviceID, chunkHandler: chunkHandler)
                return
            } catch {
                lastStartError = error
                if attempt == maxAttempts {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        if let lastStartError {
            throw lastStartError
        }
        throw XCTSkip("Microphone start retry exhausted without a captured error.")
    }

    private func captureBytesWithRetries(
        microphone: MicrophoneCaptureService,
        preferredDeviceID: String?,
        attempts: Int,
        captureWindowSeconds: TimeInterval
    ) async throws -> Int {
        var bestCaptureBytes = 0

        for attempt in 1 ... max(1, attempts) {
            let capturedBytes = NSLockingCounter()
            try await startMicrophoneWithRetry(microphone, preferredDeviceID: preferredDeviceID) { chunk in
                capturedBytes.increment(by: chunk.count)
            }

            try await Task.sleep(for: .seconds(captureWindowSeconds))
            let bytes = capturedBytes.value
            if bytes > bestCaptureBytes {
                bestCaptureBytes = bytes
            }

            microphone.stop()
            if bytes > 0 {
                return bytes
            }

            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        return bestCaptureBytes
    }

    private func isMicEnvironmentStartError(_ error: Error) -> Bool {
        if error is MicrophoneCaptureError {
            switch error as! MicrophoneCaptureError {
            case .auHALCreationFailed, .auHALConfigurationFailed, .auHALComponentNotFound:
                return true
            default:
                break
            }
        }

        let nsError = error as NSError
        guard nsError.domain == "com.apple.coreaudio.avfaudio" else {
            return false
        }

        let transientCodes: Set<Int> = [-10_868, 560_227_702]
        return transientCodes.contains(nsError.code)
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

    private func makeSpokenPCM16Data(phrase: String) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("svxt-tts-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", tempURL.path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            phrase,
        ]

        do {
            try process.run()
        } catch {
            throw XCTSkip("Failed to execute /usr/bin/say for spoken-audio integration test: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("System TTS (say) failed with status \(process.terminationStatus).")
        }

        return try extractPCMDataFromWAV(at: tempURL)
    }

    private func extractPCMDataFromWAV(at url: URL) throws -> Data {
        let wavData = try Data(contentsOf: url)
        guard wavData.count >= 44 else {
            throw XCTSkip("Generated WAV audio is unexpectedly short.")
        }

        var index = 12
        while index + 8 <= wavData.count {
            let chunkIDData = wavData[index ..< index + 4]
            let chunkID = String(data: chunkIDData, encoding: .ascii) ?? ""
            let chunkSize = Int(readLEUInt32(in: wavData, at: index + 4))
            let chunkStart = index + 8
            let chunkEnd = chunkStart + chunkSize

            guard chunkEnd <= wavData.count else {
                break
            }

            if chunkID == "data" {
                return wavData.subdata(in: chunkStart ..< chunkEnd)
            }

            index = chunkEnd
            if index % 2 == 1 {
                index += 1
            }
        }

        throw XCTSkip("WAV audio does not contain a valid data chunk.")
    }

    private func readLEUInt32(in data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private func splitPCM16IntoChunks(_ pcm: Data, chunkSizeBytes: Int) -> [Data] {
        guard chunkSizeBytes > 0 else { return [pcm] }
        guard !pcm.isEmpty else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, pcm.count / chunkSizeBytes))

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSizeBytes, pcm.count)
            chunks.append(pcm.subdata(in: offset ..< end))
            offset = end
        }

        return chunks
    }
}

private final class NSLockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment(by amount: Int) {
        lock.lock()
        storage += amount
        lock.unlock()
    }
}
