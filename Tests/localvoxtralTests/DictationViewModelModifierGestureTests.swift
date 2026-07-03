import Foundation
import XCTest
@testable import localvoxtral

/// Regression tests for the modifier-only tap/hold gesture routing found in
/// adversarial review of the tap-vs-hold rework.
@MainActor
final class DictationViewModelModifierGestureTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test instances
    // for the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    func testModifierTapTogglesOffEvenInPushToTalkShortcutMode() {
        // A tap has no release event: routing it through push-to-talk press
        // semantics set isPushToTalkShortcutHeld with nothing to ever clear
        // it, latching dictation on. A modifier-only tap must toggle.
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationShortcutMode = .pushToTalk
        let viewModel = makeViewModel(settings: settings)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isDictating = true

        viewModel.debugHandleModifierOnlyTapForTesting(mode: .overlayBuffer)

        XCTAssertFalse(viewModel.isDictating, "tap during dictation must stop it")
        XCTAssertFalse(
            viewModel.debugIsPushToTalkShortcutHeldForTesting,
            "a tap must never latch the push-to-talk held flag"
        )
    }

    func testModifierTapDoesNotRewriteActiveSessionMode() {
        // Same invariant as the hold-start guard: the stop half of a toggle
        // finalizes using sessionOutputMode; the tap's mode applies only when
        // it STARTS a session.
        let settings = makeSettings(outputMode: .liveAutoPaste)
        let coordinator = GestureTestOverlayCoordinator()
        let viewModel = makeViewModel(settings: settings, coordinator: coordinator)

        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true

        viewModel.debugHandleModifierOnlyTapForTesting(mode: .overlayBuffer)

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(
            coordinator.commitCallCount, 0,
            "the running live session must finalize down the live path — an overlay commit means its mode was rewritten by the tap"
        )
    }

    func testHoldStartDuringActiveOverlaySessionLeavesModeUntouched() {
        // handleModifierOnlyHoldStart wrote sessionOutputMode BEFORE its
        // isDictating guard, so tap(overlay)→hold→release finalized the
        // overlay session down the live-auto-paste path.
        let settings = makeSettings(outputMode: .overlayBuffer)
        let viewModel = makeViewModel(settings: settings)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isDictating = true

        viewModel.debugHandleModifierOnlyHoldStartForTesting()

        XCTAssertEqual(
            viewModel.sessionOutputMode, .overlayBuffer,
            "a hold during an active session must not rewrite its output mode"
        )
        XCTAssertFalse(
            viewModel.debugIsPushToTalkShortcutHeldForTesting,
            "no push-to-talk state may latch when the hold is ignored"
        )
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName = "localvoxtral.DictationViewModelModifierGestureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        return settings
    }

    private func makeViewModel(
        settings: SettingsStore,
        coordinator: GestureTestOverlayCoordinator = GestureTestOverlayCoordinator()
    ) -> DictationViewModel {
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: coordinator,
            startRuntimeServices: false
        )
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}

@MainActor
private final class GestureTestOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil
    var commitCallCount = 0

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: CGRect(x: 0, y: 0, width: 100, height: 24), source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        return .succeeded
    }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}
