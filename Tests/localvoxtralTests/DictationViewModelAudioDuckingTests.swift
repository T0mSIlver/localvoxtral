import Foundation
import XCTest

@testable import localvoxtral

/// Every way a session can end has to put the volume back. A user left at a
/// fifth of their volume with no dictation running is worse than no ducking,
/// so each abort route gets its own test rather than trusting one funnel.
@MainActor
final class DictationViewModelAudioDuckingTests: XCTestCase {
    private static var retainedViewModels: [DictationViewModel] = []

    private static let original: Float = 0.8
    private static var duckTarget: Float {
        original * AudioDuckingController.duckedFractionOfOriginal
    }

    func testStopRestoresTheVolume() async {
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.currentVolume(), Self.original)
    }

    func testAnAbortedConnectRestoresTheVolume() async {
        // The connect timeout, the escape cancel and a thrown connect all
        // funnel here, and none of them reach stopped-session cleanup.
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.abortConnectingSession()
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.currentVolume(), Self.original)
    }

    func testASocketLostMidDictationRestoresTheVolume() async {
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.handle(event: .disconnected)
        await viewModel.audioDucking.debugFadeTask?.value

        assertVolume(volume.currentVolume(), Self.original)
        XCTAssertFalse(viewModel.isDictating)
    }

    func testQuitRestoresTheVolumeInline() async {
        // `willTerminate` gives one synchronous main-thread closure; a fade
        // started there would never be driven.
        let (viewModel, volume) = await makeDuckedSession()

        viewModel.audioDucking.restoreImmediatelyForTermination()

        assertVolume(volume.currentVolume(), Self.original)
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
    private func makeDuckedSession() async -> (DictationViewModel, FakeOutputVolumeControl) {
        let (viewModel, volume) = makeSession(duckingEnabled: true)
        viewModel.isDictating = true
        viewModel.audioDucking.duckForSessionStart()
        await viewModel.audioDucking.debugFadeTask?.value
        assertVolume(volume.currentVolume(), Self.duckTarget, "precondition: ducked")
        volume.clearWrites()
        return (viewModel, volume)
    }

    private func makeSession(
        duckingEnabled: Bool
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
            overlayBufferCoordinator: DuckingNoopOverlayCoordinator(),
            startRuntimeServices: false
        )
        Self.retainedViewModels.append(viewModel)

        let volume = FakeOutputVolumeControl(currentVolume: Self.original)
        viewModel.audioDucking = AudioDuckingController(
            volumeControl: volume,
            isEnabled: { settings.audioDuckingEnabled },
            // Zero: this suite asserts that the restore happens at all, and on
            // which paths. The fade's shape is AudioDuckingControllerTests.
            fadeDuration: { 0 },
            interruptedDuckVolume: { settings.audioDuckingPendingRestoreVolume },
            recordInterruptedDuckVolume: { settings.audioDuckingPendingRestoreVolume = $0 }
        )
        return (viewModel, volume)
    }
}

private final class DuckingNoopOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t?

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: .zero, source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?, claudeJoin: OverlayClaudeJoinBadge) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    @discardableResult
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}
