import Foundation
import XCTest
@testable import localvoxtral

/// A dictation stopped because its mic was unplugged turns the menu bar icon
/// red and leaves a short reason in the popover. The red must survive the
/// stop's own finalization, which otherwise resets the icon to idle.
@MainActor
final class MicrophoneDisconnectedIndicatorTests: XCTestCase {
    func testUnpluggedMicTurnsIconRedThroughFinalization() {
        let viewModel = makeDictatingViewModel()

        viewModel.session.stopDictationForUnavailableMicrophone()

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.lastError, "Mic disconnected.")
        XCTAssertEqual(viewModel.currentErrorToken, .microphoneDisconnected)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .failure)

        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(
            viewModel.realtimeSessionIndicatorState, .recentFailure,
            "finalization completing must not clear the red icon early"
        )
        XCTAssertEqual(viewModel.lastError, "Mic disconnected.")
    }

    func testOrdinaryStopAfterAnUnplugReturnsIconToIdle() {
        let viewModel = makeDictatingViewModel()
        viewModel.session.stopDictationForUnavailableMicrophone()
        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        viewModel.isDictating = true
        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.stopDictation(reason: "user")
        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
    }

    /// A mic that stopped sending frames stops the dictation (#1865). The stop
    /// keeps the icon red through its finalization and ends on why, not Ready.
    func testSilentMicStopEndsOnItsReasonWithTheIconRed() {
        let viewModel = makeDictatingViewModel()

        viewModel.session.stopDictationForSilentMicrophone()
        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Mic sent no audio. Dictation stopped.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)

        viewModel.isDictating = true
        viewModel.stopDictation(reason: "user")
        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(viewModel.statusText, "Ready", "the next stop ends on Ready again")
    }

    /// The monitor's "no frames yet" error must not outlive the silent-mic
    /// stop that answers it; the status line says why the dictation ended.
    func testSilentMicStopClearsTheWaitingForAudioError() {
        let viewModel = makeDictatingViewModel()
        viewModel.lastError = AudioCaptureHealthMonitor.noAudioFramesYetMessage

        viewModel.session.stopDictationForSilentMicrophone()
        viewModel.session.finishStoppedSession(promotePendingSegment: false)

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.statusText, "Mic sent no audio. Dictation stopped.")
    }

    private func makeDictatingViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.MicrophoneDisconnectedIndicatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.dictationOutputMode = .liveAutoPaste
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: .init(clock: ManualSessionClock().clock)
        )
        retainForTestProcessLifetime(viewModel)
        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        return viewModel
    }
}
