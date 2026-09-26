import Carbon.HIToolbox
import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// The answer shortcut and the needs-you cue's app surface (#717), against a
/// fake focuser. The queue itself is `AgentAttentionTests` (core). A start
/// request is observed through `onDictationStartRequested` and then refused
/// by the microphone gate, so no test reaches `beginDictationSession`.
@MainActor
final class AnswerAgentTests: XCTestCase {
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let bareF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: 0)
    private let bareF16 = DictationShortcut(keyCode: UInt32(kVK_F16), carbonModifierFlags: 0)

    // MARK: - The press

    func testThePressBringsTheOldestWaitForwardAndListensThere() async {
        let h = makeHarness(sessions: ["pay": "/r/payments", "api": "/r/api"])
        if let check = h.tracker.receive(.stop, session: h.sessions["api"]!) { await check.value }
        h.tracker.receive(.notification, session: h.sessions["pay"]!)

        h.viewModel.session.answerAgentThatNeedsYou()
        await h.viewModel.session.answerAgentTask?.value

        XCTAssertEqual(h.focuser.focusedSessionIDs, ["pay"], "a wait before a finished turn")
        XCTAssertEqual(h.startRequests.value, 1)
        XCTAssertEqual(h.tracker.queue.entries.map(\.sessionID), ["api"], "the answered session left the queue")

        h.viewModel.session.answerAgentThatNeedsYou()
        await h.viewModel.session.answerAgentTask?.value
        XCTAssertEqual(h.focuser.focusedSessionIDs, ["pay", "api"], "the next press goes to the next one")
        XCTAssertEqual(h.startRequests.value, 2)
    }

    func testAnUnconfirmedFocusStartsNoDictation() async {
        let h = makeHarness(sessions: ["pay": "/r/payments"], outcome: .unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID))
        h.tracker.receive(.notification, session: h.sessions["pay"]!)

        h.viewModel.session.answerAgentThatNeedsYou()
        await h.viewModel.session.answerAgentTask?.value

        XCTAssertEqual(h.startRequests.value, 0, "an answer must not land in another pane")
        XCTAssertEqual(h.viewModel.statusText, DictationSessionController.AnswerAgentStatus.unconfirmed)
    }

    func testAPaneWithNoRouteSaysSo() async {
        let h = makeHarness(sessions: ["pay": "/r/payments"], outcome: .unsupported(.herdr))
        h.tracker.receive(.notification, session: h.sessions["pay"]!)

        h.viewModel.session.answerAgentThatNeedsYou()
        await h.viewModel.session.answerAgentTask?.value

        XCTAssertEqual(h.startRequests.value, 0)
        XCTAssertEqual(h.viewModel.statusText, DictationSessionController.GoToSessionStatus.unsupported)
        XCTAssertTrue(h.tracker.queue.isEmpty)
    }

    func testWithNobodyWaitingThePressSaysSo() {
        let h = makeHarness(sessions: [:])
        h.viewModel.session.answerAgentThatNeedsYou()
        XCTAssertEqual(h.focuser.focusedSessionIDs, [])
        XCTAssertEqual(h.viewModel.statusText, DictationSessionController.AnswerAgentStatus.nobodyWaiting)
    }

    func testTheStatusSentencesFitThePopoverLine() {
        for sentence in [
            DictationSessionController.AnswerAgentStatus.nobodyWaiting,
            DictationSessionController.AnswerAgentStatus.unconfirmed,
        ] {
            XCTAssertLessThanOrEqual(sentence.count, 44, sentence)
        }
    }

    // MARK: - The cue's surfaces

    func testTheIconAndThePopoverLineShowOnlyWhileTheShortcutIsSet() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        // External modes: no managed backend decides the icon.
        h.viewModel.settings.dictationBackendMode = .externalURL
        h.viewModel.settings.polishingBackendMode = .externalURL
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .idle)
        h.tracker.receive(.notification, session: h.sessions["pay"]!)
        XCTAssertEqual(h.viewModel.agentAttentionLine, "payments needs you")
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .agentNeedsYou)
        XCTAssertEqual(h.announcer.announced.map(\.sessionID), ["pay"])

        h.viewModel.settings.setAnswerAgentShortcut(nil)
        XCTAssertNil(h.viewModel.agentAttentionLine)
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .idle)
    }

    func testASessionLeavingTheQueueTakesItsBannerDown() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        h.tracker.receive(.notification, session: h.sessions["pay"]!)
        h.tracker.receive(.userPromptSubmit, session: h.sessions["pay"]!)
        XCTAssertEqual(h.announcer.withdrawn, [["pay"]])
    }

    func testADictationThatJoinsASessionAnswersIt() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        h.tracker.receive(.notification, session: h.sessions["pay"]!)
        h.viewModel.session.noteDictationJoinedAgentSession("pay")
        XCTAssertTrue(h.tracker.queue.isEmpty)
    }

    // MARK: - The shortcut

    func testTheAnswerKeyAndTheOtherSlotsRefuseEachOther() {
        forceRegistrationSuccess()
        let (shortcuts, _) = makeShortcuts()
        shortcuts.settings.setLivePasteShortcut(bareF13)
        XCTAssertEqual(shortcuts.requestAnswerAgentShortcut(bareF13), "Already the Live Auto-Paste shortcut.")
        XCTAssertNil(shortcuts.settings.answerAgentShortcut)

        XCTAssertNil(shortcuts.requestAnswerAgentShortcut(bareF16))
        XCTAssertEqual(shortcuts.settings.answerAgentShortcut, bareF16)
        XCTAssertEqual(shortcuts.requestCopyLastDictationShortcut(bareF16), ShortcutController.answerAgentConflictMessage)
        XCTAssertEqual(
            shortcuts.requestOverlayBufferShortcut(bareF16),
            .refused(message: ShortcutController.answerAgentConflictMessage)
        )
    }

    func testAKeyMacOSRefusesPutsThePreviousAnswerKeyBack() {
        forceRegistrationSuccess()
        let (shortcuts, session) = makeShortcuts()
        XCTAssertNil(shortcuts.requestAnswerAgentShortcut(bareF16))
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .answerAgent, status: OSStatus(eventHotKeyExistsErr))

        XCTAssertNil(shortcuts.requestAnswerAgentShortcut(bareF13))

        XCTAssertEqual(shortcuts.settings.answerAgentShortcut, bareF16)
        XCTAssertEqual(session.lastError, HotKeyManager.answerAgentUnavailableErrorMessage)
    }

    func testThePressAnswersAndTheReleaseDoesNotEndAPushToTalkHold() {
        let (shortcuts, session) = makeShortcuts()
        shortcuts.settings.dictationShortcutMode = .pushToTalk
        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .overlay)

        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .answerAgent)
        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .answerAgent)

        XCTAssertEqual(session.answerAgentCalls, 1)
        XCTAssertTrue(shortcuts.isPushToTalkShortcutHeld)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let tracker: AgentAttentionTracker
        let focuser: FakeSessionPaneFocuser
        let announcer: RecordingAnnouncer
        let sessions: [String: ClaudeSessionSnapshot]
        let startRequests: Box<Int>
    }

    private func makeHarness(
        sessions cwdByID: [String: String],
        outcome: SessionPaneFocusOutcome = .focused(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.setAnswerAgentShortcut(bareF16)
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)

        var sessions: [String: ClaudeSessionSnapshot] = [:]
        for (id, cwd) in cwdByID {
            var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: Date(timeIntervalSince1970: 0))
            snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
            snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys00\(sessions.count)")
            sessions[id] = snapshot
        }
        let live = sessions
        let focuser = FakeSessionPaneFocuser(outcome: outcome)
        viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { Array(live.values) },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep
        )
        var tick = 0.0
        let tracker = AgentAttentionTracker(
            isEnabled: { settings.answerAgentShortcut != nil },
            isWatching: { _ in false },
            liveSessionIDs: { Set(live.keys) },
            now: {
                tick += 1
                return Date(timeIntervalSince1970: tick)
            }
        )
        let announcer = RecordingAnnouncer()
        viewModel.agentAttention = AgentAttentionModel(tracker: tracker, announcer: announcer)

        let startRequests = Box(0)
        viewModel.session.onDictationStartRequested = { startRequests.value += 1 }
        // The microphone gate refuses the start the test just observed.
        viewModel.session.isAwaitingMicrophonePermission = true
        return Harness(
            viewModel: viewModel, tracker: tracker, focuser: focuser, announcer: announcer,
            sessions: sessions, startRequests: startRequests
        )
    }

    private func forceRegistrationSuccess() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .copyLastDictation, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .answerAgent, status: noErr)
        addTeardownBlock { @MainActor in HotKeyManager.debugResetOverridesForTesting() }
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

@MainActor
private final class RecordingAnnouncer: AgentAttentionAnnouncing {
    private(set) var announced: [AgentAttentionEntry] = []
    private(set) var withdrawn: [Set<String>] = []

    func requestPermission() {}
    func announce(_ entry: AgentAttentionEntry) { announced.append(entry) }
    func withdraw(sessionIDs: Set<String>) { withdrawn.append(sessionIDs) }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
#endif
