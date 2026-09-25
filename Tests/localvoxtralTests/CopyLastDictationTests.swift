import Carbon.HIToolbox
import Foundation
import XCTest

@testable import localvoxtral

/// "Copy last dictation" (#526): what the menu row and the shortcut copy, and
/// which dictations are still there to copy after something went wrong.
@MainActor
final class CopyLastDictationTests: XCTestCase {
    // MARK: - What gets copied

    func testAPolishedDictationCopiesThePolishedText() async {
        let (viewModel, written) = makeViewModel(polishing: FakePolishingService(returning: "Hello world."))

        finishOverlayDictation(viewModel, text: "hello world")
        await awaitStoppedSessionCommit(viewModel)
        viewModel.copyLastDictation()

        XCTAssertEqual(written.values, ["Hello world."])
        XCTAssertEqual(viewModel.statusText, "Last dictation copied.")
    }

    func testAFailedPolishCopiesTheRawTranscript() async {
        let (viewModel, written) = makeViewModel(
            polishing: FakePolishingService(failing: CopyLastDictationTestError()))

        finishOverlayDictation(viewModel, text: "hello world")
        await awaitStoppedSessionCommit(viewModel)
        viewModel.copyLastDictation()

        XCTAssertEqual(viewModel.session.lastDictation?.status, .llmFailed)
        XCTAssertEqual(written.values, ["hello world"])
    }

    /// History off keeps nothing on disk, and the text of a dictation that
    /// did not land is still one menu click away for the rest of the run.
    func testWithHistoryOffTheLastDictationIsStillCopyable() async throws {
        let (viewModel, written) = makeViewModel(polishing: nil)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.sessionStore = store
        viewModel.settings.dictationHistoryRetention = .off

        finishOverlayDictation(viewModel, text: "keep me anyway")
        viewModel.copyLastDictation()

        let saved = await store.count()
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(written.values, ["keep me anyway"])
    }

    /// History stores the clipboard placeholder; the copy is the text as it
    /// was inserted, clipboard included.
    func testAPasteClipboardDictationCopiesTheClipboardNotThePlaceholder() {
        let (viewModel, written) = makeViewModel(polishing: nil)
        viewModel.dependencies.pasteboardReader = { PasteboardStub(string: "ValueError: boom") }
        var records: [DictationSessionRecord] = []
        viewModel.dependencies.onSessionRecord = { records.append($0) }

        finishOverlayDictation(viewModel, text: "here is the error paste clipboard")
        viewModel.copyLastDictation()

        XCTAssertEqual(records.first?.polishedText?.contains(ClipboardPayloadMacro.placeholder), true)
        let copied = written.values.first ?? ""
        XCTAssertTrue(copied.contains("ValueError: boom"), copied)
        XCTAssertFalse(copied.contains(ClipboardPayloadMacro.placeholder), copied)
    }

    /// History's change callback reads the stored row back; it must not
    /// swap the clipboard text for the placeholder that row holds.
    func testReadingHistoryBackKeepsTheClipboardText() async throws {
        let (viewModel, written) = makeViewModel(polishing: nil)
        viewModel.sessionStore = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.dependencies.pasteboardReader = { PasteboardStub(string: "ValueError: boom") }

        finishOverlayDictation(viewModel, text: "here is the error paste clipboard")
        await viewModel.session.refreshLastDictationFromStore()
        viewModel.copyLastDictation()

        let copied = written.values.first ?? ""
        XCTAssertTrue(copied.contains("ValueError: boom"), copied)
    }

    func testWithNothingDictatedTheRowIsOffAndCopiesNothing() {
        let (viewModel, written) = makeViewModel(polishing: nil)

        XCTAssertFalse(viewModel.canCopyLastDictation)
        viewModel.copyLastDictation()

        XCTAssertTrue(written.values.isEmpty)
        XCTAssertEqual(viewModel.statusText, "No dictation to copy yet.")
    }

    /// The shortcut can fire mid-dictation. The copy happens; the status line
    /// keeps saying what the session is doing.
    func testCopyingDuringADictationLeavesTheStatusLineAlone() {
        let (viewModel, written) = makeViewModel(polishing: nil)
        finishOverlayDictation(viewModel, text: "the one before")
        viewModel.isDictating = true
        viewModel.statusText = "Listening..."

        viewModel.copyLastDictation()

        XCTAssertEqual(written.values, ["the one before"])
        XCTAssertEqual(viewModel.statusText, "Listening...")
    }

    // MARK: - What survives

    /// Starting a new dictation while the last one is still polishing cancels
    /// that polish. The cancelled dictation used to reach neither the target
    /// app nor History.
    func testANewDictationOverAPolishKeepsThePolishedOneAsNotInserted() async {
        let polishing = BlockingMockLLMPolishingService()
        let (viewModel, written) = makeViewModel(polishing: polishing)
        var records: [DictationSessionRecord] = []
        viewModel.dependencies.onSessionRecord = { records.append($0) }

        finishOverlayDictation(viewModel, text: "the long one I cannot lose")
        let commitTask = viewModel.session.polishAndCommitTask
        await polishing.waitUntilFirstRequestArrives()

        XCTAssertTrue(viewModel.session.cancelPolishingForNewSessionIfNeeded())
        await polishing.resumePendingRequest()
        await commitTask?.value

        XCTAssertEqual(records.count, 1, "saved once, by the cancel, never again by the task")
        XCTAssertEqual(records.first?.rawText, "the long one I cannot lose")
        XCTAssertEqual(records.first?.commitSucceeded, false)
        viewModel.copyLastDictation()
        XCTAssertEqual(written.values, ["the long one I cannot lose"])
    }

    /// A polish that finishes saves its own record; the fallback the cancel
    /// path would use is gone by then.
    func testAPolishThatFinishesSavesOnlyItsOwnRecord() async {
        let polishing = BlockingMockLLMPolishingService()
        let (viewModel, _) = makeViewModel(polishing: polishing)
        var records: [DictationSessionRecord] = []
        viewModel.dependencies.onSessionRecord = { records.append($0) }

        finishOverlayDictation(viewModel, text: "hello world")
        let commitTask = viewModel.session.polishAndCommitTask
        await polishing.waitUntilFirstRequestArrives()
        await polishing.resumePendingRequest()
        await commitTask?.value

        XCTAssertNil(viewModel.session.saveInterruptedPolishCommit)
        XCTAssertFalse(viewModel.session.cancelPolishingForNewSessionIfNeeded())
        XCTAssertEqual(records.map(\.commitSucceeded), [true])
        XCTAssertEqual(records.first?.polishedText, "Hello world.")
    }

    // MARK: - Following History

    func testTheLastDictationFollowsHistory() async throws {
        let (viewModel, _) = makeViewModel(polishing: nil)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.sessionStore = store
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(
            DictationSessionRecord(
                startedAt: startedAt, finishedAt: startedAt, rawText: "from the last run",
                provider: "p", model: "m", outputMode: "overlay_buffer",
                status: .sttCompleted, commitSucceeded: false))

        await viewModel.session.refreshLastDictationFromStore()
        XCTAssertEqual(viewModel.session.lastDictation?.rawText, "from the last run")

        store.deleteAll()
        await viewModel.session.refreshLastDictationFromStore()
        XCTAssertNil(viewModel.session.lastDictation, "a dictation deleted from History is not copyable")
    }

    /// Turning History off deletes every dictation, the last one included.
    func testTurningHistoryOffDeletesTheLastDictationToo() async throws {
        let (viewModel, _) = makeViewModel(polishing: nil)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.sessionStore = store
        finishOverlayDictation(viewModel, text: "saved while History was on")
        XCTAssertTrue(viewModel.canCopyLastDictation)

        viewModel.settings.dictationHistoryRetention = .off
        viewModel.applyDictationHistoryRetention()
        await viewModel.session.refreshLastDictationFromStore()

        XCTAssertNil(viewModel.session.lastDictation)
    }

    /// With History off the store stays empty, and an empty answer must not
    /// erase the dictation this run kept in memory.
    func testWithHistoryOffAnEmptyStoreKeepsTheDictationInMemory() async throws {
        let (viewModel, _) = makeViewModel(polishing: nil)
        viewModel.sessionStore = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.settings.dictationHistoryRetention = .off
        finishOverlayDictation(viewModel, text: "only in memory")

        await viewModel.session.refreshLastDictationFromStore()

        XCTAssertEqual(viewModel.session.lastDictation?.rawText, "only in memory")
    }

    // MARK: - Helpers

    private final class Written {
        var values: [String] = []
    }

    private func makeViewModel(
        polishing: (any LLMPolishingServicing)?
    ) -> (DictationViewModel, Written) {
        let settings = makeSettings(outputMode: .overlayBuffer)
        if polishing != nil {
            settings.llmPolishingEnabled = true
            settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        } else {
            settings.llmPolishingEnabled = false
        }
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        if let polishing { viewModel.llmPolishingService = polishing }
        // A failed polish would otherwise raise the real alert.
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let written = Written()
        viewModel.dependencies.pasteboardWriter = { written.values.append($0) }
        return (viewModel, written)
    }

    private func finishOverlayDictation(_ viewModel: DictationViewModel, text: String) {
        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = text
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
    }
}

private struct CopyLastDictationTestError: Error {}

/// The "Copy last dictation" shortcut next to the dictation triggers.
@MainActor
final class CopyLastDictationShortcutTests: XCTestCase {
    private let bareF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: 0)
    private let bareF15 = DictationShortcut(keyCode: UInt32(kVK_F15), carbonModifierFlags: 0)

    func testRecordingADictationKeyForCopyIsRefusedAndChangesNothing() {
        let (shortcuts, _) = makeShortcuts()
        shortcuts.settings.setLivePasteShortcut(bareF13)

        let message = shortcuts.requestCopyLastDictationShortcut(bareF13)

        XCTAssertEqual(message, "Already the Live Auto-Paste shortcut.")
        XCTAssertNil(shortcuts.settings.copyLastDictationShortcut)
    }

    func testRecordingTheCopyKeyForADictationSlotIsRefused() {
        forceRegistrationSuccess()
        let (shortcuts, _) = makeShortcuts()
        XCTAssertNil(shortcuts.requestCopyLastDictationShortcut(bareF15))
        shortcuts.settings.setLivePasteShortcut(nil)

        XCTAssertEqual(
            shortcuts.requestLivePasteShortcut(bareF15),
            .refused(message: ShortcutController.copyLastDictationConflictMessage)
        )
        XCTAssertEqual(
            shortcuts.requestOverlayBufferShortcut(bareF15),
            .refused(message: ShortcutController.copyLastDictationConflictMessage)
        )
        XCTAssertNil(shortcuts.settings.livePasteShortcut)
        XCTAssertNotEqual(shortcuts.settings.overlayBufferShortcut, bareF15)
    }

    func testAKeyMacOSRefusesPutsThePreviousShortcutBack() {
        forceRegistrationSuccess()
        let (shortcuts, session) = makeShortcuts()
        XCTAssertNil(shortcuts.requestCopyLastDictationShortcut(bareF15))
        HotKeyManager.debugForceRegisterStatusForTesting(
            hotKeyID: .copyLastDictation, status: OSStatus(eventHotKeyExistsErr))

        XCTAssertNil(shortcuts.requestCopyLastDictationShortcut(bareF13))

        XCTAssertEqual(shortcuts.settings.copyLastDictationShortcut, bareF15)
        XCTAssertEqual(session.lastError, HotKeyManager.copyLastDictationUnavailableErrorMessage)
    }

    /// A handler install failure on the copy slot is the copy slot's error:
    /// a dictation trigger that registers fine must not clear it.
    func testACopyHandlerFailureIsNotClearedByADictationTrigger() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(false)
        addTeardownBlock { @MainActor in HotKeyManager.debugResetOverridesForTesting() }
        let (shortcuts, session) = makeShortcuts()

        XCTAssertNil(shortcuts.requestCopyLastDictationShortcut(bareF15))
        XCTAssertEqual(session.lastError, HotKeyManager.copyLastDictationUnavailableErrorMessage)

        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        shortcuts.applyHotKeySettingsChange()

        XCTAssertEqual(session.lastError, HotKeyManager.copyLastDictationUnavailableErrorMessage)
    }

    func testThePressCopiesAndTheReleaseDoesNotEndAPushToTalkHold() {
        let (shortcuts, session) = makeShortcuts()
        shortcuts.settings.dictationShortcutMode = .pushToTalk

        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .overlay)
        XCTAssertTrue(shortcuts.isPushToTalkShortcutHeld)

        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .copyLastDictation)
        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .copyLastDictation)

        XCTAssertEqual(session.copyLastDictationCalls, 1)
        XCTAssertTrue(shortcuts.isPushToTalkShortcutHeld, "the copy key's release is not the dictation key's")
        XCTAssertEqual(session.refusalSignalClears, 0)
    }

    // MARK: - Helpers

    private func forceRegistrationSuccess() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .copyLastDictation, status: noErr)
        addTeardownBlock { @MainActor in
            HotKeyManager.debugResetOverridesForTesting()
        }
    }

    private func makeShortcuts() -> (ShortcutController, FakeShortcutSession) {
        let settings = makeSettings()
        settings.modifierOnlyHotKeyEnabled = false
        let shortcuts = ShortcutController(settings: settings)
        let session = FakeShortcutSession()
        shortcuts.install(session: session)
        addTeardownBlock { @MainActor in shortcuts.unregister() }
        return (shortcuts, session)
    }
}
