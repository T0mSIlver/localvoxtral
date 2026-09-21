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

        viewModel.stopDictationForUnavailableMicrophone()

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.lastError, "Mic disconnected.")
        XCTAssertEqual(viewModel.currentErrorToken, .microphoneDisconnected)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .failure)

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(
            viewModel.realtimeSessionIndicatorState, .recentFailure,
            "finalization completing must not clear the red icon early"
        )
        XCTAssertEqual(viewModel.lastError, "Mic disconnected.")
    }

    func testOrdinaryStopAfterAnUnplugReturnsIconToIdle() {
        let viewModel = makeDictatingViewModel()
        viewModel.stopDictationForUnavailableMicrophone()
        viewModel.finishStoppedSession(promotePendingSegment: false)

        viewModel.isDictating = true
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.stopDictation(reason: "user")
        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
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
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        return viewModel
    }
}
