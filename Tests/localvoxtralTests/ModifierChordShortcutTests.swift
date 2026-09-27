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

    // MARK: - The dictation key as a chord (#863)

    func testBothShiftsAsTheDictationKeyTapToggleAndHoldIsPushToTalk() {
        let (shortcuts, session, timer) = makeDictationChord()
        let chords = shortcuts.hotKeyManager.chordMonitor
        XCTAssertEqual(chords.dictationChord, .bothShifts, "both Shifts until another is recorded")

        // A tap: released before the hold delay runs out.
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift], timestamp: 10.0)
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 10.03125)
        XCTAssertEqual(timer.scheduledDelays, [0.5], "the hold delay setting")
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 10.25)
        timer.fireAll()
        XCTAssertEqual(session.toggledModes, [.overlayBuffer])
        XCTAssertEqual(session.startedModes, [])

        // A hold: still down when the delay runs out, then one Shift lets go.
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 20.0)
        timer.fireAll()
        XCTAssertEqual(session.startedModes, [.overlayBuffer], "push to talk starts")
        XCTAssertTrue(session.isDictating)
        chords.debugHandleFlagsChangedForTesting(held: [.rightShift], timestamp: 23.0)
        XCTAssertEqual(session.stopReasons, ["modifier hold release"])
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 23.03125)
        XCTAssertEqual(session.toggledModes, [.overlayBuffer], "no tap after a hold")
    }

    func testAShiftHeldWhileTypingNeverStartsADictation() {
        let (shortcuts, session, timer) = makeDictationChord()
        let chords = shortcuts.hotKeyManager.chordMonitor

        // "Hi", then a stray right Shift before letting go of the left.
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift], timestamp: 100.0)
        chords.debugHandleKeyDownForTesting()
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 100.5)
        timer.fireAll()
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 101.0)

        // Both Shifts together, then a letter before the hold delay.
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 200.0)
        chords.debugHandleKeyDownForTesting()
        timer.fireAll()
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 200.25)

        XCTAssertEqual(session.toggledModes, [])
        XCTAssertEqual(session.startedModes, [])
    }

    /// One chord does one job, whichever side records it first.
    func testTheDictationChordAndTheActionSlotsRefuseEachOther() {
        let (shortcuts, _, _) = makeDictationChord()
        XCTAssertEqual(
            shortcuts.requestQuickCaptureShortcut(bothShifts), ShortcutController.dictationChordConflictMessage)
        XCTAssertEqual(
            shortcuts.requestAnswerAgentShortcut(bothShifts), ShortcutController.dictationChordConflictMessage)
        XCTAssertEqual(
            shortcuts.requestCopyLastDictationShortcut(bothShifts),
            ShortcutController.dictationChordConflictMessage)
        XCTAssertNil(shortcuts.settings.quickCaptureShortcut)

        let bothCommands = ModifierChord(keys: [.leftCommand, .rightCommand])!
        XCTAssertNil(shortcuts.requestDictationChord(bothCommands))
        XCTAssertEqual(shortcuts.hotKeyManager.chordMonitor.dictationChord, bothCommands)
        XCTAssertNil(shortcuts.requestQuickCaptureShortcut(bothShifts), "free once the dictation key moved")
        XCTAssertEqual(
            shortcuts.requestDictationChord(.bothShifts), ShortcutController.quickCaptureConflictMessage)
        XCTAssertEqual(shortcuts.settings.dictationChord, bothCommands, "the refused chord changed nothing")
    }

    /// A chord an action slot took while Fn dictated is not registered twice
    /// when the picker goes back to Chord; the row asks for a new one.
    func testPickingChordDropsAStoredChordAnActionSlotTook() {
        let (shortcuts, session, _) = makeDictationChord()
        shortcuts.selectModifierKey(.fn)
        XCTAssertNil(shortcuts.hotKeyManager.chordMonitor.dictationChord)
        XCTAssertNil(shortcuts.requestQuickCaptureShortcut(bothShifts))

        shortcuts.selectModifierKey(.chord)
        XCTAssertNil(shortcuts.settings.dictationChord)
        XCTAssertNil(shortcuts.hotKeyManager.chordMonitor.dictationChord)
        XCTAssertEqual(shortcuts.hotKeyManager.chordMonitor.chords[.quickCapture], .bothShifts)
        XCTAssertNil(session.lastError)

        let relaunched = SettingsStore(
            defaults: shortcuts.settings.defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertNil(relaunched.dictationChord, "the dropped chord stays dropped")
    }

    /// Back on keyboard shortcuts, the chord monitor lets the dictation
    /// chord go and the Carbon dictation shortcut takes over.
    func testLeavingTheModifierKeysTriggerRemovesTheDictationChord() {
        let (shortcuts, session, timer) = makeDictationChord()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        addTeardownBlock { @MainActor in HotKeyManager.debugResetOverridesForTesting() }

        shortcuts.applyDictationTriggerModeChange(modifierOnlyEnabled: false)
        XCTAssertNil(shortcuts.hotKeyManager.chordMonitor.dictationChord)
        let chords = shortcuts.hotKeyManager.chordMonitor
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 1.0)
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 1.125)
        XCTAssertEqual(timer.scheduledDelays, [])
        XCTAssertEqual(session.toggledModes, [])
    }

    // MARK: - Helpers

    /// The modifier-key trigger set to Chord, with a 500 ms hold delay the
    /// test plays through `HoldSchedulerProbe`.
    private func makeDictationChord() -> (ShortcutController, FakeShortcutSession, HoldSchedulerProbe) {
        let (shortcuts, session) = makeShortcuts()
        session.startDictationSucceeds = true
        let timer = HoldSchedulerProbe()
        shortcuts.hotKeyManager.chordMonitor.holdScheduler = timer.scheduler
        shortcuts.settings.modifierOnlyHotKeyEnabled = true
        shortcuts.settings.modifierOnlyHoldDelay = 0.5
        shortcuts.selectModifierKey(.chord)
        return (shortcuts, session, timer)
    }

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
