import Foundation
import XCTest
@testable import localvoxtral

/// A dictation stopped because its mic was unplugged turns the menu bar icon
/// red and leaves a short reason in the popover. The red must survive the
/// stop's own finalization, which otherwise resets the icon to idle.
@MainActor
final class MicrophoneDisconnectedIndicatorTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test instances
    // for the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

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
            overlayBufferCoordinator: IndicatorNoopOverlayCoordinator(),
            startRuntimeServices: false
        )
        Self.retainedViewModels.append(viewModel)
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        return viewModel
    }
}

private final class IndicatorNoopOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: .zero, source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?, claudeJoin _: OverlayClaudeJoinBadge) {}
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
