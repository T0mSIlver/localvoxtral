import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// Live Auto-Paste's spoken send, through the insertion hooks and a fake pane
/// focuser: the read-back before a Return (#1712), the segments that wait
/// behind it, what a stop or a cancel does meanwhile (#1656, #1879, #1882) and
/// the stop's wait for a code-fence paste (#1664). These lived in the go-to
/// wiring tests, which went with the voice commands; what they pinned about
/// "send it" stays. No test here reaches `beginDictationSession`, so none arms
/// the connect timeout.
@MainActor
final class LiveSpokenSendWiringTests: XCTestCase {
    private static let terminalPID: pid_t = 4242
    private static let ghostty = "com.mitchellh.ghostty"
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        try await super.tearDown()
    }

    // MARK: - The read-back before a Return

    /// Two tabs of one terminal share its pid. The words are for the joined
    /// session's pane: a send is pressed only while that pane reads back as
    /// focused, and once it did not, no send for the rest of the dictation.
    func testSamePIDTabSwitchCannotSubmitAnotherPrompt() async {
        let harness = makeHarness(spokenSend: true)
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])

        harness.partial("fix the bug send it")
        harness.final("Fix the bug, send it.")
        await harness.settle()
        XCTAssertEqual(harness.returns, ["return:\(Self.terminalPID)"], "the joined pane is focused")

        // Another tab of the same terminal comes forward.
        harness.focuser.paneStillShowsSession = false
        harness.partial("run the tests send it")
        harness.final("Run the tests, send it.")
        await harness.settle()
        harness.focuser.paneStillShowsSession = true
        harness.partial("send it")
        harness.final("Send it.")
        await harness.settle()

        XCTAssertEqual(harness.focuser.readBackSessionIDs, ["pay", "pay"])
        XCTAssertEqual(harness.returns, ["return:\(Self.terminalPID)"], "no Return in the other tab, nor after")
        XCTAssertEqual(harness.typedText, "Fix the bugRun the tests, send it. Send it.")
    }

    /// The segments that end while a send reads its pane back wait behind
    /// the read-back and are not typed into the prompt before it is sent.
    func testASendHoldsLaterSegmentsBehindItsReadBack() async {
        let harness = makeHarness(spokenSend: true)
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.focuser.onReadBack = { _ in
            harness.focuser.onReadBack = nil
            harness.partial("run the build")
            harness.final("Run the build.")
        }

        harness.partial("fix the bug send it")
        harness.final("Fix the bug, send it.")
        await harness.settle()

        let events = harness.events.value
        let sent = events.firstIndex { $0.hasPrefix("return:") }
        let later = events.firstIndex { $0.contains("Run the build") }
        XCTAssertEqual(harness.returns.count, 1, "events: \(events)")
        XCTAssertEqual(events.first, "type:Fix the bug", "events: \(events)")
        XCTAssertNotNil(later, "events: \(events)")
        XCTAssertLessThan(sent ?? .max, later ?? -1, "the later segment follows the send: \(events)")
    }

    /// A segment that waited behind a read-back was decided before the user
    /// turned Live spoken send off: its "send it" is text, not a Return.
    func testASendQueuedBehindAReadBackIsTextOnceTheSettingIsOff() async {
        let harness = makeHarness(spokenSend: true)
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.focuser.onReadBack = { _ in
            harness.focuser.onReadBack = nil
            harness.partial("Run the build, send it.")
            harness.final("Run the build, send it.")
            harness.viewModel.settings.liveSpokenSendEnabled = false
        }

        harness.partial("fix the bug send it")
        harness.final("Fix the bug, send it.")
        await harness.settle()

        XCTAssertEqual(harness.returns, ["return:\(Self.terminalPID)"], "the first send was decided while the setting was on")
        XCTAssertEqual(harness.typedText, "Fix the bugRun the build, send it.", "the queued one is typed whole, with no Return")
    }

    /// A cancel while a spoken send reads the pane back throws the words
    /// away: nothing is typed and no Return is pressed once the pane
    /// answers (#1656).
    func testACancelDuringASpokenSendReadBackTypesAndSendsNothing() async {
        let harness = makeHarness(spokenSend: true)
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.focuser.onReadBack = { _ in harness.viewModel.cancelDictation() }

        harness.partial("fix the bug send it")
        harness.final("Fix the bug, send it.")
        await harness.settle()
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.focuser.readBackSessionIDs, ["pay"])
        XCTAssertEqual(harness.typedText, "", "nothing the user cancelled is typed")
        XCTAssertEqual(harness.returns, [], "nor sent")
        XCTAssertEqual(harness.records.value.count, 1)
    }

    // MARK: - A stop or a new dictation while a read-back waits

    /// A lost connection stops without finalizing, and a new dictation then
    /// ends the wait the read-back holds, so the session does not refuse
    /// every start.
    func testANewDictationEndsASendReadBackWaitOnAStopThatDidNotFinalize() async {
        let harness = makeHarness(spokenSend: true)
        let gate = ReadBackGate()
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.focuser.holdReadBack = { await gate.wait() }
        addTeardownBlock { @MainActor in gate.release() }

        harness.partial("send it")
        harness.final("Send it.")
        harness.viewModel.isDictating = false
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)
        XCTAssertTrue(harness.viewModel.isFinalizingStop, "the wait counts as finalizing")

        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())

        XCTAssertFalse(harness.viewModel.session.isCompletingStoppedSession)
        XCTAssertFalse(harness.viewModel.isFinalizingStop)
        XCTAssertNil(harness.viewModel.session.spokenCommandGate.action)
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false], "History keeps it as not inserted")
        gate.release()
        await harness.settle()
        XCTAssertEqual(harness.returns, [], "the ended wait presses nothing when the pane answers")
    }

    /// With History off, the recovery copied the whole Live transcript, words
    /// already typed included, over the clipboard (#1879).
    func testANewDictationEndingALiveStopLeavesTheClipboardAloneWithHistoryOff() async {
        let harness = makeHarness(spokenSend: true)
        let gate = ReadBackGate()
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.viewModel.settings.dictationHistoryRetention = .off
        let copied = harness.viewModel.recordPasteboardWrites()
        harness.focuser.holdReadBack = { await gate.wait() }
        addTeardownBlock { @MainActor in gate.release() }

        harness.partial("run the tests.")
        harness.final("run the tests.")
        harness.partial("send it")
        harness.final("Send it.")
        harness.viewModel.isDictating = false
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)
        XCTAssertTrue(harness.viewModel.isFinalizingStop, "the wait counts as finalizing")

        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())

        XCTAssertEqual(harness.typedText, "run the tests.")
        XCTAssertEqual(copied.values, [], "typed words are not copied again")
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        gate.release()
        await harness.settle()
    }

    /// The segments that ended behind a send still reading its pane back are
    /// copied with History off when a new dictation ends the stop's wait
    /// (#1882).
    func testANewDictationEndingALiveStopCopiesTheWordsQueuedBehindASendWithHistoryOff() async {
        let harness = makeHarness(spokenSend: true)
        let gate = ReadBackGate()
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.viewModel.settings.dictationHistoryRetention = .off
        let copied = harness.viewModel.recordPasteboardWrites()
        harness.focuser.holdReadBack = { await gate.wait() }
        addTeardownBlock { @MainActor in gate.release() }

        harness.partial("run the tests.")
        harness.final("run the tests.")
        harness.partial("send it")
        harness.final("Send it.")
        harness.partial("fix the build")
        harness.final("fix the build")
        harness.viewModel.isDictating = false
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)
        XCTAssertTrue(harness.viewModel.isFinalizingStop, "the wait counts as finalizing")

        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())

        XCTAssertEqual(harness.typedText, "run the tests.")
        XCTAssertEqual(copied.values, ["fix the build"], "the words behind the send, not the typed ones")
        gate.release()
        await harness.settle()
    }

    // MARK: - A stop waits for a code-fence paste (#1664)

    /// A stop right after two fenced finals into Claude Desktop waits for
    /// the second paste, which waited for the first one's clipboard.
    func testAStopWaitsForAFencePasteBehindAnother() async {
        let first = "first:\n```\nline one\n```"
        let second = "second:\n```\nline two\n```"
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        let harness = makeHarness(sessions: [], app: ClaudeDesktopAllowlist.bundleID)
        let clock = ManualSessionClock()
        harness.viewModel.textInsertion.pasteRestoreSleep = clock.sleep
        let clipboard = Box("")
        let pasted = Box<[String]>([])
        harness.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            frontmostPIDReader: { Self.terminalPID },
            shiftReturnPoster: { true },
            commandVPaster: { text in
                clipboard.value = text
                // The target handles Cmd+V once the main thread is free.
                Task { @MainActor in pasted.value.append(clipboard.value) }
                return true
            }
        )

        harness.partial(first)
        harness.final(first)
        harness.partial(second)
        harness.final(second)
        harness.stop()
        await clock.waitForSleepers(1)
        XCTAssertTrue(harness.records.value.isEmpty, "the stop waits for the second paste")
        clock.advance(by: 0.15)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.15)
        await harness.viewModel.session.polishAndCommitTask?.value

        XCTAssertEqual(pasted.value.map { $0.trimmingCharacters(in: .whitespaces) }, [first, second])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
    }

    /// The stop's own flush releases the hold-back's last word, a closing
    /// fence, while the paste before it awaits its restore: the stop waits
    /// for it rather than dropping it.
    func testAStopWaitsForAFenceItsOwnFlushReleasesBehindAPaste() async {
        let fenced = "first:\n```\nline one\n```"
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        let harness = makeHarness(
            sessions: [], app: ClaudeDesktopAllowlist.bundleID,
            dictionary: ReplacementDictionary(entries: [ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"])])
        )
        let clock = ManualSessionClock()
        harness.viewModel.textInsertion.pasteRestoreSleep = clock.sleep
        let clipboard = Box("")
        let pasted = Box<[String]>([])
        harness.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            frontmostPIDReader: { Self.terminalPID },
            shiftReturnPoster: { true },
            commandVPaster: { text in
                clipboard.value = text
                Task { @MainActor in pasted.value.append(clipboard.value) }
                return true
            }
        )

        harness.partial(fenced)
        harness.final(fenced)
        harness.stop()
        await clock.waitForSleepers(1)
        clock.advance(by: 0.15)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.15)
        await harness.viewModel.session.polishAndCommitTask?.value

        XCTAssertEqual(pasted.value.count, 2, "the held closing fence is a second paste: \(pasted.value)")
        XCTAssertEqual(pasted.value.joined(), fenced)
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
    }

    /// #1882: with History off, a new dictation that ends a Live stop while
    /// text waits behind a code-fence paste copies that text and nothing
    /// typed before it. The copy waits for the paste's restore.
    func testANewDictationEndingALiveStopCopiesOnlyTheTextWaitingBehindAPasteWithHistoryOff() async {
        let first = "first:\n```\nline one\n```"
        let second = "second:\n```\nline two\n```"
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        let harness = makeHarness(sessions: [], app: ClaudeDesktopAllowlist.bundleID)
        harness.viewModel.settings.dictationHistoryRetention = .off
        let copied = harness.viewModel.recordPasteboardWrites()
        let clock = ManualSessionClock()
        harness.viewModel.textInsertion.pasteRestoreSleep = clock.sleep
        let pasted = Box<[String]>([])
        harness.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            frontmostPIDReader: { Self.terminalPID },
            shiftReturnPoster: { true },
            commandVPaster: { text in
                pasted.value.append(text)
                return true
            }
        )

        harness.partial(first)
        harness.final(first)
        harness.partial(second)
        harness.final(second)
        harness.stop()
        await clock.waitForSleepers(1)
        XCTAssertTrue(harness.viewModel.isFinalizingStop, "the stop waits for the paste")

        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())
        XCTAssertEqual(copied.values, [], "nothing replaces the clipboard the paste may still read")
        clock.advance(by: 0.15)
        await harness.viewModel.textInsertion.pastesSettled()

        XCTAssertEqual(pasted.value.map { $0.trimmingCharacters(in: .whitespaces) }, [first], "the waiting text is not pasted")
        XCTAssertEqual(copied.values, [second], "only the text that never landed is copied")
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
    }

    // MARK: - Harness

    /// Holds a read-back until the test lets it answer.
    @MainActor
    private final class ReadBackGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Harness {
        let viewModel: DictationViewModel
        let focuser: FakeSessionPaneFocuser
        let events: Box<[String]>
        let records: Box<[DictationSessionRecord]>
        let sessions: [ClaudeSessionSnapshot]

        var typedText: String {
            events.value
                .filter { $0.hasPrefix("type:") }
                .map { String($0.dropFirst("type:".count)) }
                .joined()
        }

        var returns: [String] {
            events.value.filter { $0.hasPrefix("return:") }
        }

        @MainActor
        func partial(_ text: String) {
            viewModel.session.handle(event: .partialTranscript(text))
        }

        @MainActor
        func final(_ text: String) {
            viewModel.session.handle(event: .finalTranscript(text))
        }

        /// Every read-back started, and the ones the queue behind it started.
        @MainActor
        func settle() async {
            while let task = viewModel.session.spokenCommandGate.action {
                await task.value
            }
            viewModel.textInsertion.flushFinalLiveReplacementCorrections()
        }

        @MainActor
        func stop() {
            viewModel.isDictating = false
            viewModel.isFinalizingStop = true
            viewModel.session.finishStoppedSession(promotePendingSegment: false)
        }
    }

    private func session(_ id: String, cwd: String, tty: String = "/dev/ttys009") -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: tty, termProgram: "ghostty")
        return snapshot
    }

    private func join(_ snapshot: ClaudeSessionSnapshot) -> ClaudeSessionJoin {
        ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: Self.terminalPID, bundleID: Self.ghostty),
            snapshot: snapshot,
            windowID: 101,
            mechanism: .ttyDevice
        )
    }

    private func makeHarness(
        sessions: [ClaudeSessionSnapshot]? = nil,
        spokenSend: Bool = false,
        app: String = LiveSpokenSendWiringTests.ghostty,
        dictionary: ReplacementDictionary? = nil
    ) -> Harness {
        let sessions = sessions ?? [session("pay", cwd: "/r/payments")]
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.liveSpokenSendEnabled = spokenSend
        settings.replacementDictionaryEnabled = dictionary != nil

        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = Self.terminalPID
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(replacementDictionary: dictionary ?? ReplacementDictionary(entries: []))
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { _ in app }
        let records = Box<[DictationSessionRecord]>([])
        viewModel.dependencies.onSessionRecord = { records.value.append($0) }

        let events = Box<[String]>([])
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                events.value.append("type:\(chunk)")
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                events.value.append("return:\(pid)")
                return true
            },
            frontmostPIDReader: { Self.terminalPID }
        )
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { app }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        viewModel.session.captureSessionTargetVerdict()
        viewModel.session.applyPreCapturedSessionTargetVerdict()

        let focuser = FakeSessionPaneFocuser()
        viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { sessions },
            focuser: focuser,
            // Each session's agent (claudePID 2) owns its terminal (#1249).
            ttyForegroundPIDs: { _ in [2] }
        )
        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.session.configureLiveAutoPasteReplacementCorrectorForSession()
        return Harness(viewModel: viewModel, focuser: focuser, events: events, records: records, sessions: sessions)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
