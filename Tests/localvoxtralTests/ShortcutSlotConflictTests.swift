import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

/// Recording a key the other mode already holds. Carbon refuses the same key
/// twice on one event target, so the two slots cannot both have it: Settings
/// asks, and only a confirmed answer moves it.
@MainActor
final class ShortcutSlotConflictTests: XCTestCase {
    private let bareF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: 0)
    private let bareF14 = DictationShortcut(keyCode: UInt32(kVK_F14), carbonModifierFlags: 0)

    // MARK: - Asking

    func testRecordingTheLivePasteKeyIntoOverlayAsksFirstAndChangesNothing() {
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF14)
        viewModel.settings.setLivePasteShortcut(bareF13)

        let outcome = viewModel.requestOverlayBufferShortcut(bareF13)

        XCTAssertEqual(outcome, .needsMoveConfirmation(shortcut: bareF13, from: .liveAutoPaste))
        XCTAssertEqual(
            viewModel.settings.overlayBufferShortcut, bareF14,
            "the question is asked before anything is written"
        )
        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
    }

    func testRecordingTheOverlayKeyIntoLivePasteAsksFirst() {
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF13)
        viewModel.settings.setLivePasteShortcut(bareF14)

        let outcome = viewModel.requestLivePasteShortcut(bareF13)

        XCTAssertEqual(outcome, .needsMoveConfirmation(shortcut: bareF13, from: .overlayBuffer))
        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF13)
        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF14)
    }

    /// The recorder hands over what ShortcutRecorder reported, which carries
    /// `NSFunctionKeyMask` for F1-F20. A conflict is a conflict once both
    /// sides are normalized, or the same physical key would be accepted twice.
    func testConflictIsDetectedThroughTheRecorderFunctionKeyBit() {
        let viewModel = makeViewModel()
        viewModel.settings.setLivePasteShortcut(bareF13)

        let asRecorded = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: 1 << 23
        )

        XCTAssertEqual(
            viewModel.requestOverlayBufferShortcut(asRecorded),
            .needsMoveConfirmation(shortcut: bareF13, from: .liveAutoPaste),
            "the fn bit is stripped before the question is asked, so the answer names the bare key"
        )
    }

    func testAFreeShortcutIsRecordedWithoutAsking() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setLivePasteShortcut(bareF13)

        XCTAssertEqual(viewModel.requestOverlayBufferShortcut(bareF14), .applied)
        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF14)
        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
    }

    /// A disabled slot registers nothing, so its stored key is not taken.
    func testADisabledOtherSlotIsNotAConflict() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setLivePasteShortcut(bareF13)
        viewModel.settings.livePasteShortcutEnabled = false

        XCTAssertEqual(viewModel.requestOverlayBufferShortcut(bareF13), .applied)
        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF13)
    }

    func testClearingASlotNeverAsks() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setLivePasteShortcut(bareF13)

        XCTAssertEqual(viewModel.requestLivePasteShortcut(nil), .applied)
        XCTAssertNil(viewModel.settings.livePasteShortcut)
    }

    // MARK: - Answering yes

    func testConfirmedMoveTakesTheKeyFromLivePaste() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF14)
        viewModel.settings.setLivePasteShortcut(bareF13)

        viewModel.moveShortcutToOverlayBuffer(bareF13)

        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF13)
        XCTAssertNil(
            viewModel.settings.livePasteShortcut,
            "the key cannot be registered twice, so the slot it came from is cleared"
        )
        XCTAssertEqual(
            viewModel.debugCurrentHotKeyRegistrationKindForTesting,
            .dual(overlay: true, livePaste: false),
            "the move re-registers — settings alone would leave the old hotkey live"
        )
    }

    func testConfirmedMoveTakesTheKeyFromOverlay() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF13)
        viewModel.settings.setLivePasteShortcut(bareF14)

        viewModel.moveShortcutToLivePaste(bareF13)

        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
        XCTAssertNil(viewModel.settings.overlayBufferShortcut)
        XCTAssertEqual(
            viewModel.debugCurrentHotKeyRegistrationKindForTesting,
            .dual(overlay: false, livePaste: true)
        )
    }

    /// A move is one change. If the single registration that follows fails,
    /// the user is left with what they had, not with one slot emptied.
    func testAFailedMoveRestoresBothSlots() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(
            hotKeyID: .overlay, status: OSStatus(eventHotKeyExistsErr))
        defer { HotKeyManager.debugResetOverridesForTesting() }

        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF14)
        viewModel.settings.setLivePasteShortcut(bareF13)

        let unregisterCallsBefore = HotKeyManager.debugUnregisterCallCount

        viewModel.moveShortcutToOverlayBuffer(bareF13)

        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF14)
        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
        // Two registration passes: the one that failed, and the one that puts
        // the old shortcuts back. Counted rather than read off the resulting
        // registration kind, because the restore pass reaches REAL Carbon (the
        // forced status is one-shot) and a test host is not an app, so what it
        // returns is not ours to assert.
        XCTAssertGreaterThanOrEqual(
            HotKeyManager.debugUnregisterCallCount - unregisterCallsBefore, 2,
            "the restore has to re-register, or the failed key stays live"
        )
    }

    // MARK: - The Reset button

    /// Reset writes the default shortcut without going through the recorder,
    /// so it has to ask the same question. It is the one control that could
    /// put the old silent-collision behaviour back.
    func testResettingOverlayToADefaultLivePasteHoldsAsksFirst() {
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF13)
        viewModel.settings.setLivePasteShortcut(SettingsStore.defaultDictationShortcut)

        let outcome = viewModel.requestOverlayBufferShortcut(SettingsStore.defaultDictationShortcut)

        XCTAssertEqual(
            outcome,
            .needsMoveConfirmation(
                shortcut: SettingsStore.defaultDictationShortcut, from: .liveAutoPaste)
        )
        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF13)
        XCTAssertEqual(
            viewModel.settings.livePasteShortcut, SettingsStore.defaultDictationShortcut)
    }

    // MARK: - Restoring exactly what was there

    /// A slot can be enabled while holding a value the validator rejects: the
    /// migration stores key code 0 with the enabled flag defaulting to true.
    /// Restoring that through the setters would write the default shortcut
    /// instead, installing a trigger the user never chose — and, because
    /// Overlay Buffer reachability would flip, starting managed polishd.
    func testAFailedMoveRestoresAnEnabledButInvalidSlotVerbatim() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(
            hotKeyID: .overlay, status: OSStatus(eventHotKeyExistsErr))
        defer { HotKeyManager.debugResetOverridesForTesting() }

        let viewModel = makeViewModel()
        viewModel.settings.restoreShortcutSlots(
            SettingsStore.ShortcutSlotSnapshot(
                overlayKeyCode: 0,
                overlayCarbonModifierFlags: 0,
                overlayEnabled: true,
                livePasteKeyCode: UInt32(kVK_F13),
                livePasteCarbonModifierFlags: 0,
                livePasteEnabled: true
            )
        )
        let before = viewModel.settings.shortcutSlotSnapshot
        XCTAssertNil(viewModel.settings.overlayBufferShortcut, "stored, enabled, and invalid")
        XCTAssertFalse(viewModel.settings.isOverlayBufferSessionReachable)

        viewModel.moveShortcutToOverlayBuffer(bareF13)

        XCTAssertEqual(
            viewModel.settings.shortcutSlotSnapshot, before,
            "both slots come back byte for byte, invalid value included"
        )
        XCTAssertFalse(
            viewModel.settings.isOverlayBufferSessionReachable,
            "a failed move must not make Overlay Buffer reachable — that starts polishd"
        )
    }

    // MARK: - Helpers

    private func forceRegistrationSuccess() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .livePaste, status: noErr)
        addTeardownBlock { @MainActor in
            HotKeyManager.debugResetOverridesForTesting()
        }
    }

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.ShortcutSlotConflictTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        // Shortcuts mode: the modifier-only gesture registers instead of the
        // two slots, and would make every registration here a no-op.
        settings.modifierOnlyHotKeyEnabled = false

        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        retainForTestProcessLifetime(viewModel)
        return viewModel
    }
}
