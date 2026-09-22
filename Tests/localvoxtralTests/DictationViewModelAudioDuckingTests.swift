import AppKit
import Foundation
import XCTest

@testable import localvoxtral

/// Every way a session can end has to put the volume back. A user left at a
/// fifth of their volume with no dictation running is worse than no ducking,
/// so each abort route gets its own test rather than trusting one funnel.
@MainActor
final class DictationViewModelAudioDuckingTests: XCTestCase {
    private static let deviceA = "device-a"
    private static let original: Float = 0.8
    private static var duckTarget: Float {
        original * AudioDuckingController.duckedFractionOfOriginal
    }

    func testStopRestoresTheVolume() async {
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.volume(of: Self.deviceA), Self.original)
    }

    func testAnAbortedConnectRestoresTheVolume() async {
        // The connect timeout, the escape cancel and a thrown connect all
        // funnel here, and none of them reach stopped-session cleanup.
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.abortConnectingSession()
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.volume(of: Self.deviceA), Self.original)
    }

    func testASocketLostMidDictationRestoresTheVolume() async {
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.handle(event: .disconnected)
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.volume(of: Self.deviceA), Self.original)
        XCTAssertFalse(viewModel.isDictating)
    }

    func testQuitRestoresTheVolumeThroughTheRealObserver() async {
        // Through the notification, not by calling the controller: the claim
        // is that the app's own `willTerminate` wiring restores. And inline —
        // the observer's synchronous return is the last execution the process
        // guarantees, so the volume must be back when `post` returns.
        let center = NotificationCenter()
        let (viewModel, volume) = await makeDuckedSession(lifecycleCenter: center)

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        assertVolume(
            volume.volume(of: Self.deviceA), Self.original,
            "restored by the time the observer returned, with no await in between")
    }

    func testSystemSleepRestoresTheVolume() async {
        // Also through the real observer. The Mac going to sleep with the
        // volume down is the version of this a user finds the next morning.
        let center = NotificationCenter()
        let (viewModel, volume) = await makeDuckedSession(lifecycleCenter: center)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.volume(of: Self.deviceA), Self.original)
        XCTAssertFalse(viewModel.isDictating)
    }

    func testStopWithoutADuckLeavesTheVolumeAlone() async {
        // The setting is off: stopping must not write a volume of its own.
        let (viewModel, volume) = makeSession(duckingEnabled: false)
        viewModel.isDictating = true

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)
        await viewModel.audioDucking.debugFadeTask?.value

        XCTAssertTrue(volume.writes.isEmpty)
    }

    // MARK: - Harness

    private func assertVolume(
        _ actual: Float?, _ expected: Float, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected a volume, got none. \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: 0.0001, message, file: file, line: line)
    }


    /// A view model whose ducking controller is already ducked, with fades
    /// collapsed to a single write so the assertions are about routing.
    private func makeDuckedSession(
        lifecycleCenter: NotificationCenter? = nil
    ) async -> (DictationViewModel, FakeOutputVolumeControl) {
        let (viewModel, volume) = makeSession(duckingEnabled: true, lifecycleCenter: lifecycleCenter)
        viewModel.isDictating = true
        viewModel.audioDucking.duckForSessionStart()
        await viewModel.audioDucking.debugFadeTask?.value
        assertVolume(volume.volume(of: Self.deviceA), Self.duckTarget, "precondition: ducked")
        volume.clearWrites()
        return (viewModel, volume)
    }

    private func makeSession(
        duckingEnabled: Bool,
        lifecycleCenter: NotificationCenter? = nil
    ) -> (DictationViewModel, FakeOutputVolumeControl) {
        let suiteName = "localvoxtral.DictationViewModelAudioDuckingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.dictationOutputMode = .overlayBuffer
        settings.audioDuckingEnabled = duckingEnabled

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: .init(lifecycleNotificationCenter: lifecycleCenter)
        )
        retainForTestProcessLifetime(viewModel)

        let volume = FakeOutputVolumeControl(volume: Self.original)
        // A pinned clock and a sleep that does not sleep: this suite asserts
        // which paths restore, and must not read the wall clock to do it. The
        // fade's shape is AudioDuckingControllerTests.
        let pinnedNow = Date(timeIntervalSince1970: 1_000)
        viewModel.audioDucking = AudioDuckingController(
            volumeControl: volume,
            isEnabled: { settings.audioDuckingEnabled },
            fadeDuration: { 0 },
            interruptedDuck: { settings.audioDuckingPendingRestore },
            recordInterruptedDuck: { settings.audioDuckingPendingRestore = $0 },
            now: { pinnedNow },
            sleepFor: { _ in }
        )
        return (viewModel, volume)
    }
}
