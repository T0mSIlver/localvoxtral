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

    func testFailedModifierHoldStartDoesNotLatchLiveModeForNextSettingsBasedSession() async {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        let viewModel = makeViewModel(settings: settings)

        viewModel.isAwaitingMicrophonePermission = true

        viewModel.debugHandleModifierOnlyHoldStartForTesting()

        XCTAssertNil(
            viewModel.sessionOutputMode,
            "a gesture whose startDictation request is declined must not latch a shortcut mode"
        )

        settings.dictationOutputMode = .overlayBuffer
        viewModel.isAwaitingMicrophonePermission = false
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)

        await viewModel.beginDictationSession()

        XCTAssertEqual(
            viewModel.sessionOutputMode, .overlayBuffer,
            "the next settings-based session must use the current setting, not a stale failed gesture mode"
        )

        viewModel.abortConnectingSession()
    }

    func testAccessibilityTrustArrivalRetriesFailedModifierOnlyRegistration() {
        // Launch-time modifier-only registration fails while AXIsProcessTrusted()
        // is transiently false (cold-launch TCC race, field-hit 2026-07-05).
        // When trust lands, the trust-change hook must re-register instead of
        // leaving the shortcut dead until the user touches the modifier setting.
        ModifierOnlyHotKeyManager.resetDebugState()
        defer { ModifierOnlyHotKeyManager.resetDebugState() }

        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.modifierOnlyHotKeyEnabled = true
        // Force the failure BEFORE the view model exists: on an AX-trusted
        // test host, init's trust refresh already fires the retry hook, and a
        // real registration there would break the "dead at launch" premise.
        ModifierOnlyHotKeyManager.forcedStartOutcome = .monitorInstallationFailed
        let viewModel = makeViewModel(settings: settings)
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)

        viewModel.applyHotKeySettingsChange()
        XCTAssertNotEqual(
            viewModel.debugCurrentHotKeyRegistrationKindForTesting, .modifierOnly,
            "sanity: the launch-time registration attempt must have failed"
        )

        ModifierOnlyHotKeyManager.forcedStartOutcome = .created
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)

        XCTAssertEqual(
            viewModel.debugCurrentHotKeyRegistrationKindForTesting, .modifierOnly,
            "trust arrival must re-register the modifier-only hotkey"
        )
        XCTAssertNil(
            viewModel.lastError,
            "a healed registration must clear the stale hotkey error"
        )
    }

    func testAccessibilityTrustArrivalDoesNotChurnLiveModifierOnlyRegistration() {
        ModifierOnlyHotKeyManager.resetDebugState()
        defer { ModifierOnlyHotKeyManager.resetDebugState() }

        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.modifierOnlyHotKeyEnabled = true
        // Forced before init so an AX-trusted test host cannot install real
        // NSEvent monitors through the init-time trust refresh.
        ModifierOnlyHotKeyManager.forcedStartOutcome = .created
        let viewModel = makeViewModel(settings: settings)
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)

        viewModel.applyHotKeySettingsChange()
        XCTAssertEqual(viewModel.debugCurrentHotKeyRegistrationKindForTesting, .modifierOnly)
        let startCallsAfterRegistration = ModifierOnlyHotKeyManager.startCallCount

        viewModel.textInsertion.debugSetAccessibilityTrusted(true)

        XCTAssertEqual(
            ModifierOnlyHotKeyManager.startCallCount, startCallsAfterRegistration,
            "trust arrival must not re-register a modifier-only hotkey that is already live"
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
        // Keep tests hermetic: session start reads config (terminal apps,
        // replacement dictionary) through the store — never the real
        // config directory.
        viewModel.appConfigStore = GestureTestHermeticConfigStore()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}

private final class GestureTestHermeticConfigStore: AppConfigServing {
    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        ReplacementDictionary(entries: [])
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
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
