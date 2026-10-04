import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// "Go to <name>" in Live Auto-Paste (#747), through the insertion hooks and
/// a fake focuser. No test here reaches `beginDictationSession`, so none arms
/// the connect timeout.
@MainActor
final class LiveGoToSessionWiringTests: XCTestCase {
    private static let terminalPID: pid_t = 4242
    private static let otherTerminalPID: pid_t = 4343
    private static let ghostty = "com.mitchellh.ghostty"
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        try await super.tearDown()
    }

    func testAGoToSegmentTypesNothingAndBringsTheSessionForward() async {
        let harness = makeHarness()

        harness.partial(" Go")
        harness.partial(" to")
        harness.partial(" pay")
        harness.partial("ments.")
        XCTAssertEqual(harness.typedText, "", "nothing is typed before the final")
        harness.final("Go to payments.")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.typedText, "", "the command is not typed")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    func testANameNoSessionHasIsTypedWholeAtItsFinal() async {
        let harness = makeHarness()

        harness.partial("go to the tests")
        XCTAssertEqual(harness.typedText, "")
        harness.final("go to the tests")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.typedText, "go to the tests")
    }

    func testASegmentThatDoesNotOpenWithGoToIsTypedLive() {
        let harness = makeHarness()

        harness.partial("run the ")
        // The terminal hold-back keeps the trailing space until the next word.
        XCTAssertEqual(harness.typedText, "run the", "typed as it streams, as without the hold-back")
        harness.partial("tests")
        harness.final("run the tests")
        harness.stop()

        XCTAssertEqual(harness.typedText, "run the tests")
        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
    }

    /// Only the letters that may still read "go to" wait.
    func testAWordThatOnlyStartsLikeGoIsReleasedAtTheLetterThatRulesItOut() {
        let harness = makeHarness()

        harness.partial("Go")
        XCTAssertEqual(harness.typedText, "")
        harness.partial("od morning ")
        XCTAssertEqual(harness.typedText, "Good morning")
        harness.final("Good morning")
        harness.stop()

        // The stop releases the space the terminal hold-back kept, as it
        // does for any live text.
        XCTAssertEqual(harness.typedText, "Good morning ")
    }

    func testNothingIsHeldWhileNoSessionIsLive() {
        let harness = makeHarness(sessions: [])

        harness.partial("Go ")
        harness.partial("to payments ")

        XCTAssertEqual(harness.typedText, "Go to payments")
    }

    func testTheWordsAfterAGoToLandInThePaneThatCameForward() async {
        let harness = makeHarness()
        harness.focuser.onFocus = { _ in harness.frontmost.value = Self.otherTerminalPID }

        harness.partial("first part ")
        harness.final("first part")
        harness.partial("go to payments")
        harness.final("go to payments")
        // Spoken while the pane is coming forward.
        harness.partial("fix the build")
        harness.final("fix the build")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(
            harness.typedText(in: Self.terminalPID),
            "first part ",
            "what the terminal hold-back kept goes to the pane it was dictated into"
        )
        XCTAssertEqual(harness.typedText(in: Self.otherTerminalPID), "fix the build")
    }

    /// A tail whose insertion failed before the focus is kept, never typed
    /// into the pane that came forward (#1663).
    func testATailThatFailedToLandBeforeAGoToIsKeptNotTypedIntoTheNewPane() async {
        let harness = makeHarness()
        let clipboard = Box<[String]>([])
        harness.viewModel.dependencies.pasteboardWriter = { clipboard.value.append($0) }
        harness.focuser.onFocus = { _ in harness.frontmost.value = Self.otherTerminalPID }
        let clock = ManualSessionClock()
        harness.viewModel.textInsertion.restartInsertionRetryTask(
            sleep: clock.sleep,
            isDictating: { true }
        )
        defer { harness.viewModel.textInsertion.stopInsertionRetryTask() }

        harness.insertionWorks.value = false
        harness.partial("first part ")
        harness.final("first part")
        harness.partial("go to payments")
        harness.final("go to payments")
        await harness.settle()
        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])

        harness.insertionWorks.value = true
        await clock.waitForSleepers(1)
        clock.advance(by: 0.12)
        await clock.waitForSleepers(1)

        XCTAssertEqual(harness.typedText(in: Self.otherTerminalPID), "", "pane A's tail never reaches pane B")
        XCTAssertEqual(clipboard.value, ["first part "], "kept once")
        XCTAssertFalse(harness.viewModel.textInsertion.hasPendingInsertionText)
    }

    /// A stop right after two fenced finals into Claude Desktop waits for
    /// the second paste, which waited for the first one's clipboard (#1664).
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

    func testAStopDuringAGoToWaitsForItThenTypesWhatFollowed() async {
        let harness = makeHarness()
        harness.focuser.onFocus = { _ in harness.frontmost.value = Self.otherTerminalPID }

        harness.partial("go to payments")
        harness.final("go to payments")
        harness.partial("fix the build")
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.typedText(in: Self.otherTerminalPID), "fix the build")
        XCTAssertEqual(harness.records.value.count, 1, "the dictation is saved once the go-to is done")
    }

    /// A cancel during a go-to drops the words that ended behind it; the
    /// go-to itself still lands (#1251).
    func testACancelDuringAGoToTypesNothingThatFollowed() async {
        let harness = makeHarness()
        harness.focuser.onFocus = { _ in harness.frontmost.value = Self.otherTerminalPID }

        harness.partial("go to payments")
        harness.final("go to payments")
        harness.partial("fix the build")
        harness.final("fix the build")
        harness.viewModel.cancelDictation()
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.typedText, "", "nothing the user cancelled is typed")
        XCTAssertEqual(harness.records.value.count, 1)
    }

    /// A cancel while a spoken send reads the pane back throws the words
    /// away too: nothing is typed and no Return is pressed once the pane
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

    /// Review of #773 (P2): the stop waited only for the first go-to, and
    /// the cleanup cancelled the one queued behind it.
    func testAStopWaitsForAGoToQueuedBehindAnother() async {
        let harness = makeHarness(sessions: [
            session("pay", cwd: "/r/payments", tty: "/dev/ttys001"),
            session("bill", cwd: "/r/billing", tty: "/dev/ttys002"),
        ])

        harness.partial("go to payments")
        harness.final("go to payments")
        harness.partial("go to billing")
        harness.final("go to billing")
        harness.stop()
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay", "bill"])
        XCTAssertEqual(harness.typedText, "")
        XCTAssertEqual(harness.records.value.count, 1)
    }

    /// Review of #773 (P1): a lost connection stops without finalizing, and
    /// a new dictation then skipped the recovery that ends the wait, leaving
    /// the session refusing every start.
    func testANewDictationEndsAGoToWaitOnAStopThatDidNotFinalize() {
        let harness = makeHarness()

        harness.partial("go to payments")
        harness.final("go to payments")
        harness.viewModel.isDictating = false
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)
        XCTAssertTrue(harness.viewModel.isFinalizingStop, "the wait counts as finalizing")

        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())

        XCTAssertFalse(harness.viewModel.session.isCompletingStoppedSession)
        XCTAssertFalse(harness.viewModel.isFinalizingStop)
        XCTAssertNil(harness.viewModel.session.liveGoToTask)
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false], "History keeps it as not inserted")
    }

    func testAnAmbiguousNameTypesNothingAndSaysSo() async {
        let harness = makeHarness(sessions: [
            session("a", cwd: "/r/localvoxtral", tty: "/dev/ttys001"),
            session("b", cwd: "/r/localvoxtral", tty: "/dev/ttys002"),
        ])

        harness.partial("go to localvoxtral")
        harness.final("go to localvoxtral")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.typedText, "")
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.GoToSessionStatus.ambiguous)
    }

    /// With the spoken send trigger on, a go-to that names no session is
    /// still a prompt it can send.
    func testAnUnknownGoToEndingInTheTriggerIsSent() async {
        let harness = makeHarness(spokenSend: true)

        harness.partial("go to the tests send it")
        harness.final("go to the tests, send it.")
        await harness.settle()

        XCTAssertEqual(harness.typedText, "go to the tests")
        XCTAssertEqual(harness.events.value.last, "return:\(Self.terminalPID)")
    }

    /// A name that resolves to nothing is sent as text, and with a joined
    /// pane its send reads the pane back first. The segments that end
    /// meanwhile wait behind that read-back, as behind a go-to, and are not
    /// typed into the prompt before it is sent.
    func testAnUnknownGoToSendHoldsLaterSegmentsBehindItsReadBack() async {
        let harness = makeHarness(spokenSend: true)
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])
        harness.focuser.onReadBack = { _ in
            harness.focuser.onReadBack = nil
            harness.partial("run the build")
            harness.final("Run the build.")
        }

        harness.partial("go to the tests send it")
        harness.final("Go to the tests, send it.")
        await harness.settle()

        let events = harness.events.value
        let sent = events.firstIndex { $0.hasPrefix("return:") }
        let later = events.firstIndex { $0.contains("Run the build") }
        XCTAssertEqual(harness.returns.count, 1, "events: \(events)")
        XCTAssertEqual(events.first, "type:Go to the tests", "events: \(events)")
        XCTAssertNotNil(later, "events: \(events)")
        XCTAssertLessThan(sent ?? .max, later ?? -1, "the later segment follows the send: \(events)")
    }

    /// The same instruction sent to one agent, then after a go-to to
    /// another, reaches both: the go-to is an utterance between them, so the
    /// second is no duplicate final.
    func testSameInstructionAfterGoToReachesTheNewAgent() async {
        let harness = makeHarness(sessions: [
            session("pay", cwd: "/r/payments", tty: "/dev/ttys001"),
            session("bill", cwd: "/r/billing", tty: "/dev/ttys002"),
        ], spokenSend: true)
        harness.focuser.onFocus = { _ in harness.frontmost.value = Self.otherTerminalPID }

        harness.partial("run the tests send it")
        harness.final("Run the tests, send it.")
        await harness.settle()
        harness.partial("go to billing")
        harness.final("Go to billing.")
        await harness.settle()
        harness.partial("run the tests send it")
        harness.final("Run the tests, send it.")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["bill"])
        XCTAssertEqual(harness.focuser.readBackSessionIDs, ["bill"], "the pane the go-to brought is read back")
        XCTAssertEqual(harness.typedText(in: Self.terminalPID), "Run the tests")
        XCTAssertEqual(harness.typedText(in: Self.otherTerminalPID), "Run the tests")
        XCTAssertEqual(
            harness.events.value.filter { $0.hasPrefix("return:") },
            ["return:\(Self.terminalPID)", "return:\(Self.otherTerminalPID)"]
        )
    }

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

    /// A go-to whose pane did not read back as the session's may have
    /// brought another prompt forward: a send after it is typed as text.
    func testASendAfterAnUnverifiedGoToPressesNoReturn() async {
        let harness = makeHarness(spokenSend: true)
        harness.focuser.outcome = .unverified(bundleID: Self.ghostty)

        harness.partial("go to payments")
        harness.final("Go to payments.")
        // Ends while the go-to runs, and waits behind it.
        harness.partial("run the tests send it")
        harness.final("Run the tests, send it.")
        await harness.settle()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.returns, [])
        XCTAssertEqual(harness.typedText, "Run the tests, send it.")
    }

    // MARK: - Naming this session (#723 step 2)

    func testNamingThisSessionTypesNothingAndNamesTheJoinedSession() async {
        let harness = makeHarness()
        harness.viewModel.session.context.claudeSessionJoin = join(harness.sessions[0])

        harness.partial("Call this session ")
        harness.partial("billing.")
        XCTAssertEqual(harness.typedText, "")
        harness.final("Call this session billing.")
        await harness.settle()

        XCTAssertEqual(harness.typedText, "")
        XCTAssertEqual(harness.nicknames.nickname(for: "pay"), "billing")
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.GoToSessionStatus.named)
    }

    /// "This session" follows the words: after a go-to, it is the session
    /// that came forward.
    func testAfterAGoToThisSessionIsTheOneThatCameForward() async {
        let other = session("other", cwd: "/r/other", tty: "/dev/ttys002")
        let harness = makeHarness(sessions: [session("pay", cwd: "/r/payments"), other])
        harness.viewModel.session.context.claudeSessionJoin = join(other)

        harness.partial("go to payments")
        harness.final("go to payments")
        harness.partial("call this session billing")
        harness.final("call this session billing")
        await harness.settle()

        XCTAssertEqual(harness.nicknames.nickname(for: "pay"), "billing")
        XCTAssertNil(harness.nicknames.nickname(for: "other"))
        XCTAssertEqual(harness.typedText, "")
    }

    func testNamingWithNoJoinedSessionIsTypedAsText() async {
        let harness = makeHarness()

        harness.partial("call this session billing")
        harness.final("call this session billing")
        await harness.settle()

        XCTAssertEqual(harness.typedText, "call this session billing")
        XCTAssertNil(harness.nicknames.nickname(for: "pay"))
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let focuser: FakeSessionPaneFocuser
        let events: Box<[String]>
        let frontmost: Box<pid_t?>
        let typedPerApp: Box<[(pid: pid_t?, text: String)]>
        let records: Box<[DictationSessionRecord]>
        let insertionWorks: Box<Bool>
        let sessions: [ClaudeSessionSnapshot]
        let nicknames: SessionNicknameStore

        var typedText: String {
            events.value
                .filter { $0.hasPrefix("type:") }
                .map { String($0.dropFirst("type:".count)) }
                .joined()
        }

        var returns: [String] {
            events.value.filter { $0.hasPrefix("return:") }
        }

        func typedText(in pid: pid_t) -> String {
            typedPerApp.value.filter { $0.pid == pid }.map(\.text).joined()
        }

        @MainActor
        func partial(_ text: String) {
            viewModel.session.handle(event: .partialTranscript(text))
        }

        @MainActor
        func final(_ text: String) {
            viewModel.session.handle(event: .finalTranscript(text))
        }

        /// Every go-to started, and the ones the queue behind it started.
        @MainActor
        func settle() async {
            while let task = viewModel.session.liveGoToTask {
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
        app: String = LiveGoToSessionWiringTests.ghostty
    ) -> Harness {
        let sessions = sessions ?? [session("pay", cwd: "/r/payments")]
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.liveSpokenSendEnabled = spokenSend
        settings.replacementDictionaryEnabled = false

        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = Self.terminalPID
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { _ in app }
        let records = Box<[DictationSessionRecord]>([])
        viewModel.dependencies.onSessionRecord = { records.value.append($0) }

        let events = Box<[String]>([])
        let frontmost = Box<pid_t?>(Self.terminalPID)
        let typedPerApp = Box<[(pid: pid_t?, text: String)]>([])
        let insertionWorks = Box(true)
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                guard insertionWorks.value else { return false }
                events.value.append("type:\(chunk)")
                typedPerApp.value.append((frontmost.value, chunk))
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                events.value.append("return:\(pid)")
                return true
            },
            frontmostPIDReader: { frontmost.value }
        )
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { app }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        viewModel.session.captureSessionTargetVerdict()
        viewModel.session.applyPreCapturedSessionTargetVerdict()

        let focuser = FakeSessionPaneFocuser()
        let nicknames = SessionNicknameStore(load: []) { _ in }
        viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { sessions },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep,
            nicknames: nicknames,
            // Each session's agent (claudePID 2) owns its terminal (#1249).
            ttyForegroundPIDs: { _ in [2] }
        )
        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.session.configureLiveAutoPasteReplacementCorrectorForSession()
        return Harness(
            viewModel: viewModel,
            focuser: focuser,
            events: events,
            frontmost: frontmost,
            typedPerApp: typedPerApp,
            records: records,
            insertionWorks: insertionWorks,
            sessions: sessions,
            nicknames: nicknames
        )
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
