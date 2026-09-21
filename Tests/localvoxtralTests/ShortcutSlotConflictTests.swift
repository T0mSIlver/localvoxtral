import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

/// Recording a key the other mode already holds. Carbon refuses the same key
/// twice on one event target, so the two slots cannot both have it: Settings
/// asks, and only a confirmed answer moves it.
@MainActor
final class ShortcutSlotConflictTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test
    // instances for the process duration so teardown does not race service
    // shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    private let bareF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: 0)
    private let bareF14 = DictationShortcut(keyCode: UInt32(kVK_F14), carbonModifierFlags: 0)

    // MARK: - Asking

    func testRecordingTheLivePasteKeyIntoOverlayAsksFirstAndChangesNothing() {
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF14)
        viewModel.settings.setLivePasteShortcut(bareF13)

        let outcome = viewModel.requestOverlayBufferShortcut(bareF13)

        XCTAssertEqual(outcome, .needsMoveConfirmation(from: .liveAutoPaste))
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

        XCTAssertEqual(outcome, .needsMoveConfirmation(from: .overlayBuffer))
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
            .needsMoveConfirmation(from: .liveAutoPaste)
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
    }

    func testConfirmedMoveTakesTheKeyFromOverlay() {
        forceRegistrationSuccess()
        let viewModel = makeViewModel()
        viewModel.settings.setOverlayBufferShortcut(bareF13)
        viewModel.settings.setLivePasteShortcut(bareF14)

        viewModel.moveShortcutToLivePaste(bareF13)

        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
        XCTAssertNil(viewModel.settings.overlayBufferShortcut)
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

        viewModel.moveShortcutToOverlayBuffer(bareF13)

        XCTAssertEqual(viewModel.settings.overlayBufferShortcut, bareF14)
        XCTAssertEqual(viewModel.settings.livePasteShortcut, bareF13)
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
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}
