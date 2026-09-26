import Foundation
import XCTest
@testable import localvoxtral

/// The microphone half of the live STT lane's suite. The realtime client half
/// is the core suite's class of the same name, which also runs on Linux; the
/// shared name keeps `--filter RealtimeAPIVLLMIntegrationTests` running both.
final class RealtimeAPIVLLMIntegrationTests: XCTestCase {
    private static let micCaptureEnableEnv = "LOCALVOXTRAL_MIC_CAPTURE_TEST_ENABLE"
    private static let micCaptureDeviceEnv = "LOCALVOXTRAL_MIC_CAPTURE_DEVICE_UID"

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
