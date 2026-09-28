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
        let sessions: [ClaudeSessionSnapshot]
        let nicknames: SessionNicknameStore

        var typedText: String {
            events.value
                .filter { $0.hasPrefix("type:") }
                .map { String($0.dropFirst("type:".count)) }
                .joined()
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
        spokenSend: Bool = false
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
        viewModel.dependencies.bundleIdentifier = { _ in Self.ghostty }
        let records = Box<[DictationSessionRecord]>([])
        viewModel.dependencies.onSessionRecord = { records.value.append($0) }

        let events = Box<[String]>([])
        let frontmost = Box<pid_t?>(Self.terminalPID)
        let typedPerApp = Box<[(pid: pid_t?, text: String)]>([])
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
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
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { Self.ghostty }
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
            nicknames: nicknames
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
