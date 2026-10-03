#if DEBUG || LOCALVOXTRAL_E2E_HARNESS

import Foundation
import XCTest
import localvoxtralTestSupport

@testable import localvoxtral

/// The dogfood WAV source as the session's audio pipeline uses it. The
/// source's own parsing and delivery tests are in the core suite.
final class DogfoodAudioFileViewModelTests: XCTestCase {
    // MARK: - View model

    @MainActor
    func testAFileFedSessionNeverTouchesTheMicrophone() async throws {
        let chunkBytes = DogfoodAudioFileSource.chunkByteCount
        let pcm = Data(repeating: 9, count: chunkBytes)
        let url = try writeTemporaryWAV(pcm: pcm)
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = url
        let gate = DogfoodSleepGate()
        viewModel.audio.dogfoodAudioFileSleep = { _ in try await gate.sleep() }

        XCTAssertFalse(viewModel.session.capturesFromMicrophone)
        XCTAssertEqual(viewModel.session.currentMicrophoneAuthorizationStatus(), .authorized)

        let collector = DogfoodChunkCollector()
        try viewModel.audio.startSessionAudioCapture(preferredDeviceID: nil) { collector.append($0) }
        await gate.waitForEntries(1)
        let producer = viewModel.audio.dogfoodAudioFileSource?.currentTask
        XCTAssertNotNil(producer)
        viewModel.audio.stopSessionAudioCapture()
        gate.release()
        await producer?.value

        XCTAssertEqual(collector.chunks, [pcm])
        XCTAssertNil(viewModel.audio.dogfoodAudioFileSource)
        XCTAssertFalse(viewModel.audio.hasInitializedMicrophone)
    }

    /// Falling back to the microphone would let an end-to-end run pass or fail
    /// on the room's noise, so an unusable file fails the session start.
    @MainActor
    func testAnUnusableFileFailsTheStartInsteadOfFallingBackToTheMicrophone() throws {
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-audio-missing-\(UUID().uuidString).wav")

        XCTAssertThrowsError(
            try viewModel.audio.startSessionAudioCapture(preferredDeviceID: nil) { _ in }
        ) { error in
            XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, .unreadable)
        }
        XCTAssertNil(viewModel.audio.dogfoodAudioFileSource)
        XCTAssertFalse(viewModel.audio.hasInitializedMicrophone)
    }

    @MainActor
    func testWithoutAFileTheMicrophoneStaysTheSource() {
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = nil
        XCTAssertTrue(viewModel.session.capturesFromMicrophone)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.DogfoodAudioFileViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        return DictationViewModel(settings: settings, startRuntimeServices: false)
    }

    private func writeTemporaryWAV(pcm: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-audio-\(UUID().uuidString).wav")
        try DogfoodWAV.make(pcm: pcm).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

#endif
