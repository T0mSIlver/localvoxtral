import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

/// A left-and-right-Shift chord in an action slot (#831): Settings stores it,
/// the hotkey manager fires the slot's action from it, and the slots still
/// refuse each other's shortcut.
@MainActor
final class ModifierChordShortcutTests: XCTestCase {
    private let bothShifts = DictationShortcut(chord: .bothShifts)
    private let optionF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: UInt32(optionKey))

    func testBothShiftsAsQuickCaptureTogglesQuickCaptureAndAShiftHeldWhileTypingDoesNot() {
        let (shortcuts, session) = makeShortcuts()
        XCTAssertNil(shortcuts.requestQuickCaptureShortcut(bothShifts))
        XCTAssertEqual(shortcuts.settings.quickCaptureShortcut, bothShifts)
        XCTAssertTrue(shortcuts.hotKeyManager.isQuickCaptureShortcutRegistered)
        let chords = shortcuts.hotKeyManager.chordMonitor

        // Typing "Hi" with left Shift, then a stray right Shift before letting go.
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift], timestamp: 100.0)
        chords.debugHandleKeyDownForTesting()
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 100.03125)
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 100.25)
        XCTAssertEqual(session.toggleQuickCaptureCalls, 0)

        // Both Shifts pressed together, then released.
        chords.debugHandleFlagsChangedForTesting(held: [.rightShift], timestamp: 200.0)
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 200.03125)
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 200.125)
        XCTAssertEqual(session.toggleQuickCaptureCalls, 1)
        XCTAssertEqual(session.answerAgentCalls, 0)
        XCTAssertEqual(session.copyLastDictationCalls, 0)
    }

    func testTheChordReadsBackAfterARelaunchAndAKeyReplacesIt() {
        let (shortcuts, _) = makeShortcuts()
        XCTAssertNil(shortcuts.requestAnswerAgentShortcut(bothShifts))

        let relaunched = SettingsStore(
            defaults: shortcuts.settings.defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(relaunched.answerAgentShortcut, bothShifts)

        forceActionRegistrationSuccess()
        XCTAssertNil(shortcuts.requestAnswerAgentShortcut(optionF13))
        XCTAssertEqual(shortcuts.settings.answerAgentShortcut, optionF13)
        XCTAssertNil(shortcuts.hotKeyManager.chordMonitor.chords[.answerAgent], "the chord is gone")
    }

    func testTheSlotsRefuseAChordAnotherSlotHolds() {
        let (shortcuts, _) = makeShortcuts()
        XCTAssertNil(shortcuts.requestQuickCaptureShortcut(bothShifts))

        XCTAssertEqual(
            shortcuts.requestAnswerAgentShortcut(bothShifts), ShortcutController.quickCaptureConflictMessage)
        XCTAssertEqual(
            shortcuts.requestCopyLastDictationShortcut(bothShifts),
            ShortcutController.quickCaptureConflictMessage)
        XCTAssertNil(shortcuts.settings.answerAgentShortcut)
        XCTAssertNil(shortcuts.settings.copyLastDictationShortcut)

        XCTAssertNil(shortcuts.requestQuickCaptureShortcut(nil))
        XCTAssertNil(shortcuts.requestCopyLastDictationShortcut(bothShifts), "free once cleared")
        XCTAssertEqual(
            shortcuts.requestQuickCaptureShortcut(bothShifts), ShortcutController.copyLastDictationConflictMessage)
    }

    /// A cold launch can report no Accessibility trust with a grant on disk;
    /// the chord registers once trust lands, and the error goes.
    func testAChordThatFailedAtLaunchRegistersOnceTrustLands() {
        let (shortcuts, session) = makeShortcuts()
        shortcuts.settings.setQuickCaptureShortcut(bothShifts)
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .livePaste, status: noErr)
        addTeardownBlock { @MainActor in HotKeyManager.debugResetOverridesForTesting() }
        ModifierChordHotKeyMonitor.debugForceInstallFailure = true
        addTeardownBlock { @MainActor in ModifierChordHotKeyMonitor.debugForceInstallFailure = false }

        shortcuts.registerAtLaunch()
        XCTAssertFalse(shortcuts.hotKeyManager.isQuickCaptureShortcutRegistered)
        XCTAssertEqual(session.lastError, HotKeyManager.quickCaptureUnavailableErrorMessage)

        ModifierChordHotKeyMonitor.debugForceInstallFailure = false
        shortcuts.retryChordShortcutRegistrationIfNeeded()
        XCTAssertTrue(shortcuts.hotKeyManager.isQuickCaptureShortcutRegistered)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(shortcuts.settings.quickCaptureShortcut, bothShifts, "the stored chord never changed")
    }

    func testTheDictationSlotsNeverStoreAChord() {
        let (shortcuts, _) = makeShortcuts()
        shortcuts.settings.setOverlayBufferShortcut(optionF13)
        shortcuts.settings.setOverlayBufferShortcut(bothShifts)
        shortcuts.settings.setLivePasteShortcut(bothShifts)
        XCTAssertEqual(shortcuts.settings.overlayBufferShortcut, optionF13)
        XCTAssertNil(shortcuts.settings.livePasteShortcut)
    }

    // MARK: - Helpers

    private func forceActionRegistrationSuccess() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .answerAgent, status: noErr)
        addTeardownBlock { @MainActor in
            HotKeyManager.debugResetOverridesForTesting()
        }
    }

    private func makeShortcuts() -> (ShortcutController, FakeShortcutSession) {
        let suiteName = "localvoxtral.ModifierChordShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.modifierOnlyHotKeyEnabled = false
        let shortcuts = ShortcutController(settings: settings)
        let session = FakeShortcutSession()
        shortcuts.install(session: session)
        addTeardownBlock { @MainActor in shortcuts.unregister() }
        return (shortcuts, session)
    }
}
