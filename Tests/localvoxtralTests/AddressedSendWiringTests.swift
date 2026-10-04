import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// "… send that to <name>" (#723 step 3) wired into the Overlay Buffer stop:
/// the text reaches the named session's pane and nowhere else. Against a
/// fake focuser, the overlay mock committing through the app's committers,
/// and a fake herdr socket. No test here reaches `beginDictationSession`,
/// so none arms the connect timeout.
@MainActor
final class AddressedSendWiringTests: XCTestCase {
    /// The app the dictation started in: nothing may land here.
    private static let focusedAppPID: pid_t = 4242
    /// The named session's terminal, frontmost once its pane comes forward.
    private static let namedTerminalPID: pid_t = 5151
    /// The agent's pid in `session(_:cwd:tty:)`, and its parent shell's.
    private static let agentPID: Int32 = 2
    private static let shellPID: Int32 = 1
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    override func tearDown() async throws {
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    func testTheTextGoesToTheNamedPaneAndIsSubmittedThere() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001"), session("web", cwd: "/r/web")]
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"], "the phrase is cut")
        XCTAssertEqual(harness.inserted.value.map(\.pid), [Self.namedTerminalPID], "typed into the named terminal")
        XCTAssertEqual(harness.focuser.readBackSessionIDs, ["pay"], "the pane is read back before the Return")
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
        XCTAssertEqual(harness.viewModel.statusText, "Ready")
    }

    /// The last commit went into this pane's unsent prompt and the session
    /// has submitted nothing since: the addressed text continues it with a
    /// space, as an ordinary commit does (#802). Its Return sends the
    /// prompt, so nothing after it continues it (#1480).
    func testAnAddressedSendSpacesTheUnsentPromptItContinues() async {
        let registry = ClaudeSessionRegistry(now: { Date(timeIntervalSince1970: 3_000_000) }, isProcessAlive: { _ in true })
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "pay", timestamp: 0, rawCwd: "/r/payments", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(hookPID: 1, claudePID: Self.agentPID, tty: "/dev/ttys001", termProgram: "ghostty")
            ),
            origin: local
        )
        let harness = makeHarness(
            text: "Run the tests, send that to payments.", sessions: registry.liveSessions(), registry: registry
        )
        harness.viewModel.session.lastOverlayCommitLanding = OverlayCommitLanding(
            targetPID: Self.namedTerminalPID, sessionID: "pay",
            promptsSubmitted: registry.snapshot(sessionID: "pay")?.promptsSubmitted ?? -1
        )

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), [" Run the tests"])
        XCTAssertEqual(harness.inserted.value.map(\.pid), [Self.namedTerminalPID])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
        XCTAssertNil(harness.viewModel.session.lastOverlayCommitLanding)
    }

    /// A landing in another session is that prompt's evidence: an addressed
    /// send elsewhere neither continues it nor erases it.
    func testAnAddressedSendKeepsTheLandingOfAnotherSession() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001"), session("web", cwd: "/r/web")]
        )
        let elsewhere = OverlayCommitLanding(targetPID: Self.focusedAppPID, sessionID: "web", promptsSubmitted: 0)
        harness.viewModel.session.lastOverlayCommitLanding = elsewhere

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
        XCTAssertEqual(harness.viewModel.session.lastOverlayCommitLanding, elsewhere)
    }

    func testANameNoSessionHasIsCommittedAsText() async {
        let harness = makeHarness(
            text: "fix it, send that to nowhere",
            sessions: [session("pay", cwd: "/r/payments")]
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.overlay.committedTexts, ["fix it, send that to nowhere"])
        XCTAssertEqual(harness.returns.value, [])
    }

    func testAnAmbiguousNameSendsNothingAndKeepsTheTextInHistory() async {
        let harness = makeHarness(
            text: "fix it, send that to localvoxtral",
            sessions: [
                session("a", cwd: "/r/localvoxtral", tty: "/dev/ttys001"),
                session("b", cwd: "/r/localvoxtral", tty: "/dev/ttys002"),
            ]
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.overlay.committedTexts, [])
        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.records.value.map(\.rawText), ["fix it, send that to localvoxtral"])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.GoToSessionStatus.ambiguous)
    }

    /// With History off the next dictation would replace the only copy, so
    /// the words before the phrase go on the clipboard (#1546).
    func testAnAmbiguousNameWithHistoryOffCopiesTheText() async {
        let harness = makeHarness(
            text: "fix it, send that to localvoxtral",
            sessions: [
                session("a", cwd: "/r/localvoxtral", tty: "/dev/ttys001"),
                session("b", cwd: "/r/localvoxtral", tty: "/dev/ttys002"),
            ]
        )
        harness.viewModel.settings.dictationHistoryRetention = .off
        harness.viewModel.settings.autoCopyEnabled = false
        let copied = harness.viewModel.recordPasteboardWrites()

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(copied.values, ["fix it"])
        XCTAssertEqual(harness.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    /// The owner's ruling: no key without the pane's own evidence.
    func testAPaneThatDoesNotReadBackAsTheSessionGetsNoKey() async {
        for outcome in [
            SessionPaneFocusOutcome.unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID),
            .paneNotFound,
        ] {
            let harness = makeHarness(
                text: "Run the tests, send that to payments.",
                sessions: [session("pay", cwd: "/r/payments")],
                outcome: outcome
            )

            await harness.stop()

            XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"], "\(outcome)")
            XCTAssertEqual(harness.overlay.committedTexts, [], "\(outcome)")
            XCTAssertEqual(harness.inserted.value.count, 0, "\(outcome)")
            XCTAssertEqual(harness.returns.value, [], "\(outcome)")
            XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false], "\(outcome)")
            XCTAssertEqual(
                harness.viewModel.statusText,
                DictationSessionController.AddressedSendStatus.notSent,
                "\(outcome)"
            )
        }
    }

    func testAPaneThatChangedAfterTheTypingGetsNoReturn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.focuser.paneStillShowsSession = false

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [], "no Return into a pane that is not the session's")
        XCTAssertEqual(
            harness.viewModel.statusText,
            DictationSessionController.AddressedSendStatus.typedNotSubmitted
        )
    }

    /// The named agent exits while its pane comes forward: the shell left
    /// in its tty reads back the same, so liveness is asked again before
    /// any key (Codex audit 2026-10-02, #1219).
    func testNamedSessionEndingDuringFocusGetsNoTextOrReturn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.focuser.onFocus = { _ in harness.live.value = [] }

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.inserted.value.count, 0, "no text into the shell")
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.AddressedSendStatus.notSent)
    }

    /// The named agent exits during the read-back after the typing: the
    /// text is in its old pane, but no Return goes to the shell.
    func testNamedSessionEndingDuringTheReadBackGetsNoReturn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.focuser.onReadBack = { _ in harness.live.value = [] }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [], "no Return into the shell")
        XCTAssertEqual(
            harness.viewModel.statusText,
            DictationSessionController.AddressedSendStatus.typedNotSubmitted
        )
    }

    /// Ctrl-Z on the named agent: it is alive and registered, and its tab's
    /// tty reads back as the session's, but its shell owns the terminal and
    /// would run the text as a command (#1249).
    func testASuspendedAgentGetsNoTextOrReturn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.foreground.value = [Self.shellPID]

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0, "no text into the shell")
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.AddressedSendStatus.notSent)
    }

    /// The agent is suspended during the read-back after the typing: the
    /// text is at its prompt, but no Return goes to the shell.
    func testAnAgentSuspendedAfterTheTypingGetsNoReturn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.focuser.onReadBack = { _ in harness.foreground.value = [Self.shellPID] }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [], "no Return into the shell")
        XCTAssertEqual(
            harness.viewModel.statusText,
            DictationSessionController.AddressedSendStatus.typedNotSubmitted
        )
    }

    /// A new dictation that starts between the typing and the Return: no
    /// Return, the typed text is still in History, and the new dictation's
    /// state is not cleaned up a second time.
    func testANewDictationDuringTheReadBackStopsTheReturnButKeepsTheRecord() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        let viewModel = harness.viewModel
        harness.focuser.onReadBack = { _ in
            viewModel.session.cancelPolishingForNewSessionIfNeeded()
            viewModel.statusText = "Listening"
        }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
        XCTAssertEqual(viewModel.statusText, "Listening", "the new dictation's status stands")
    }

    func testAnotherAppFrontmostAfterTheFocusGetsNoKey() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.frontmost.value = Self.focusedAppPID
        harness.viewModel.dependencies.bundleIdentifier = { pid in
            pid == Self.namedTerminalPID ? TerminalScreenAllowlist.ghosttyBundleID : "com.apple.Safari"
        }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.AddressedSendStatus.notSent)
    }

    /// The same with History off: nothing was typed, so the text goes on
    /// the clipboard (#1499).
    func testAnotherAppFrontmostWithHistoryOffCopiesTheText() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        harness.viewModel.settings.dictationHistoryRetention = .off
        harness.viewModel.settings.autoCopyEnabled = false
        let copied = harness.viewModel.recordPasteboardWrites()
        harness.frontmost.value = Self.focusedAppPID
        harness.viewModel.dependencies.bundleIdentifier = { pid in
            pid == Self.namedTerminalPID ? TerminalScreenAllowlist.ghosttyBundleID : "com.apple.Safari"
        }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(copied.values, ["Run the tests"])
        XCTAssertEqual(harness.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    func testSecureKeyboardEntryTypesNothing() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments")]
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(harness.returns.value, [])
    }

    func testASessionWithNoRouteGetsNothingAndSaysSo() async {
        var desktop = session("pay", cwd: "/r/payments")
        desktop.process?.desktopSessionID = "local_x"
        let harness = makeHarness(text: "Run the tests, send that to payments.", sessions: [desktop])

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.AddressedSendStatus.unsupported)
    }

    /// The same with History off: the text goes on the clipboard (#1546).
    func testASessionWithNoRouteWithHistoryOffCopiesTheText() async {
        var desktop = session("pay", cwd: "/r/payments")
        desktop.process?.desktopSessionID = "local_x"
        let harness = makeHarness(text: "Run the tests, send that to payments.", sessions: [desktop])
        harness.viewModel.settings.dictationHistoryRetention = .off
        harness.viewModel.settings.autoCopyEnabled = false
        let copied = harness.viewModel.recordPasteboardWrites()

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(copied.values, ["Run the tests"])
        XCTAssertEqual(harness.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    /// "send it" in the text is text: the addressed send is the only submit,
    /// and it is never a Return in the app the dictation started in.
    func testTheSpokenSendTriggerDoesNotFireInTheFocusedApp() async {
        let harness = makeHarness(
            text: "fix it, send it, send that to payments",
            sessions: [session("pay", cwd: "/r/payments")]
        )

        await harness.stop()

        XCTAssertEqual(harness.inserted.value.map(\.text), ["fix it, send it"])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
    }

    func testThePolisherSeesTheTextWithoutThePhraseAndItsReplyGoesToTheSession() async {
        let polishingService = FakePolishingService(returning: "Run the tests.")
        let harness = makeHarness(
            text: "run the tests send that to payments",
            sessions: [session("pay", cwd: "/r/payments")],
            polishingService: polishingService
        )

        await harness.stop()

        let request = await polishingService.lastRequest
        XCTAssertEqual(request?.inputText, "run the tests")
        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests."])
        XCTAssertEqual(harness.inserted.value.map(\.pid), [Self.namedTerminalPID])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
    }

    /// A polished addressed send writes its diagnostic record like any other
    /// polished dictation, under its History id, and arms no edit watch: the
    /// text went to the named session, not the focused app.
    func testAPolishedAddressedSendWritesItsRecordAndWatchesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("addressed-records-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let monitor = EditSignalTestMonitor()
        let harness = makeHarness(
            text: "run the tests send that to payments",
            sessions: [session("pay", cwd: "/r/payments")],
            polishingService: FakePolishingService(returning: "Run the tests."),
            recordDirectory: directory,
            editMonitor: monitor
        )

        await harness.stop()

        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID], "the send itself went through")
        let historyID = try XCTUnwrap(harness.records.value.first?.id)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.compactMap { DiagnosticRecordFileName.parse($0)?.id }, [historyID])
        XCTAssertEqual(monitor.startCount, 0, "no Backspace watch on the focused app")
    }

    // MARK: - herdr

    func testAHerdrPaneGetsTheTextAndEnterThroughItsSocketAndNoKeyIsPosted() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        addTeardownBlock { herdr.stop() }
        let harness = makeHarness(text: "Run the tests, send that to payments.", herdr: herdr)

        await harness.stop()

        XCTAssertEqual(herdr.writes, [
            .init(method: "pane.send_text", paneID: "w1:p2", text: "Run the tests", keys: nil),
            .init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"]),
        ])
        XCTAssertEqual(harness.focuser.focusedSessionIDs, [], "a socket write needs no focus")
        XCTAssertEqual(harness.inserted.value.count, 0)
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
    }

    func testARefusedHerdrWriteIsKeptInHistoryAndNeverTyped() async throws {
        let herdr = try FakeHerdrSocket(
            answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { _ in
                .error("pane_send_failed")
            }
        )
        addTeardownBlock { herdr.stop() }
        let harness = makeHarness(text: "Run the tests, send that to payments.", herdr: herdr)

        await harness.stop()

        XCTAssertEqual(herdr.writes.map(\.method), ["pane.send_text"], "no Enter after a refused text")
        XCTAssertEqual(harness.inserted.value.count, 0, "the focused app is not where it was sent")
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.AddressedSendStatus.notSent)
    }

    /// With History off, Copy last dictation alone holds the text until the
    /// next dictation: a refused route's text goes on the clipboard, and the
    /// popover says so (#1499).
    func testARefusedHerdrWriteWithHistoryOffIsCopied() async throws {
        let herdr = try FakeHerdrSocket(
            answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { _ in
                .error("pane_send_failed")
            }
        )
        addTeardownBlock { herdr.stop() }
        let harness = makeHarness(text: "Run the tests, send that to payments.", herdr: herdr)
        harness.viewModel.settings.dictationHistoryRetention = .off
        harness.viewModel.settings.autoCopyEnabled = false
        let copied = harness.viewModel.recordPasteboardWrites()

        await harness.stop()

        XCTAssertEqual(herdr.writes.map(\.method), ["pane.send_text"], "precondition: the route refused")
        XCTAssertEqual(copied.values, ["Run the tests"])
        XCTAssertEqual(harness.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    /// A new dictation that starts while the route still answers takes the
    /// stop's status, not the text: a refusal after it is still copied with
    /// History off (#1658).
    func testARefusedHerdrWriteANewDictationSupersededIsStillCopied() async throws {
        let (arrived, arrival) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let herdr = try FakeHerdrSocket(
            answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { _ in
                arrival.yield()
                release.wait()
                return .error("pane_send_failed")
            }
        )
        addTeardownBlock {
            release.signal()
            herdr.stop()
        }
        let harness = makeHarness(text: "Run the tests, send that to payments.", herdr: herdr)
        harness.viewModel.settings.dictationHistoryRetention = .off
        harness.viewModel.settings.autoCopyEnabled = false
        let copied = harness.viewModel.recordPasteboardWrites()

        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: false)
        let commit = harness.viewModel.session.polishAndCommitTask
        for await _ in arrived { break }
        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded(), "a new dictation starts")
        release.signal()
        await commit?.value

        XCTAssertEqual(herdr.writes.map(\.method), ["pane.send_text"], "precondition: the route refused")
        XCTAssertEqual(copied.values, ["Run the tests"])
    }

    func testTheStatusSentencesFitThePopoverLine() {
        for sentence in [
            DictationSessionController.AddressedSendStatus.unsupported,
            DictationSessionController.AddressedSendStatus.notSent,
            DictationSessionController.AddressedSendStatus.typedNotSubmitted,
        ] {
            XCTAssertLessThanOrEqual(sentence.count, 44, sentence)
        }
    }

    // MARK: - Through the named session's mod (#1693)

    /// The named session's mod is attached: it fills and submits by session
    /// id. The pane is never brought forward and no key is posted anywhere.
    func testAnAttachedModSubmitsInTheUnfocusedSessionWithNoFocusAndNoKey() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001"), session("web", cwd: "/r/web")]
        )
        let mod = attachMod(harness, sessionID: "pay", answer: .submitted)

        await harness.stop()

        XCTAssertEqual(mod.sends.value, ["Run the tests"], "the phrase is cut")
        XCTAssertEqual(harness.focuser.focusedSessionIDs, [], "the pane stays where it is")
        XCTAssertEqual(harness.inserted.value.map(\.text), [], "no key typed")
        XCTAssertEqual(harness.returns.value, [], "no Return")
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
        XCTAssertEqual(harness.viewModel.statusText, "Ready")
    }

    /// The box holds an unsent draft ending in a word: the text continues it
    /// with a space, and the mod submits the whole box.
    func testTheModSendSpacesADraftEndingInAWord() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        let mod = attachMod(harness, sessionID: "pay", answer: .submitted, draft: "then")

        await harness.stop()

        XCTAssertEqual(mod.sends.value, [" Run the tests"])
    }

    /// The session is mid-turn: the popover says the prompt runs after it.
    func testAQueuedModSendSaysItRunsAfterTheTurn() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        _ = attachMod(harness, sessionID: "pay", answer: .queued)

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.ModChannelStatus.queued)
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
    }

    /// The mod refused (a dialog holds the box): nothing changed in the
    /// session, so the focus path runs as it does without a mod.
    func testAModRefusalFallsBackToTheFocusPath() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        let mod = attachMod(harness, sessionID: "pay", answer: .refused("dialog"))

        await harness.stop()

        XCTAssertEqual(mod.sends.value, ["Run the tests"])
        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [true])
    }

    /// The channel is there but the write fails: the mod never got the
    /// request, so the focus path runs.
    func testAModThatNeverGetsTheRequestFallsBackToTheFocusPath() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        _ = attachMod(harness, sessionID: "pay", answer: .undeliverable)

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.inserted.value.map(\.text), ["Run the tests"])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
    }

    /// Only the named session's mod counts: another session's attached mod
    /// leaves this one on the focus path.
    func testAnotherSessionsModLeavesTheNamedOneOnTheFocusPath() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001"), session("web", cwd: "/r/web")]
        )
        let mod = attachMod(harness, sessionID: "web", answer: .submitted)

        await harness.stop()

        XCTAssertEqual(mod.sends.value, [])
        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.returns.value, [Self.namedTerminalPID])
    }

    /// The mod got the request and never answered: it may have submitted,
    /// so nothing is typed or sent another way, and the text is kept.
    func testAnUnansweredModSendIsKeptAndNeverRetyped() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        _ = attachMod(harness, sessionID: "pay", answer: .silent)

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.inserted.value.map(\.text), [])
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
        XCTAssertEqual(harness.viewModel.statusText, StatusStrings.agentPromptTextKeptInHistory)
    }

    /// The mod's process moved to another session (`/clear`) after the
    /// name resolved: its pane shows that session now, so nothing is sent
    /// there by any path (#1651).
    func testASessionChangedRefusalIsKeptAndTakesNoOtherPath() async {
        let harness = makeHarness(
            text: "Run the tests, send that to payments.",
            sessions: [session("pay", cwd: "/r/payments", tty: "/dev/ttys001")]
        )
        _ = attachMod(
            harness, sessionID: "pay", answer: .refused(ClaudeModChannelWire.Reply.sessionChangedReason)
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.inserted.value.map(\.text), [])
        XCTAssertEqual(harness.returns.value, [])
        XCTAssertEqual(harness.records.value.map(\.commitSucceeded), [false])
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let focuser: FakeSessionPaneFocuser
        let inserted: Box<[(text: String, pid: pid_t?)]>
        let returns: Box<[pid_t]>
        let frontmost: Box<pid_t?>
        let records: Box<[DictationSessionRecord]>
        /// The registry's live sessions, which a test can end mid-send.
        let live: Box<[ClaudeSessionSnapshot]>
        /// The pids in every tty's foreground process group.
        let foreground: Box<[Int32]>

        @MainActor
        func stop() async {
            viewModel.isDictating = false
            viewModel.isFinalizingStop = true
            viewModel.session.finishStoppedSession(promotePendingSegment: false)
            await awaitStoppedSessionCommit(viewModel)
        }
    }

    private enum ModAnswer: Equatable {
        case submitted, queued, silent, undeliverable
        case refused(String)
    }

    private struct FakeMod {
        /// The texts of the `send` requests the mod got.
        let sends: Box<[String]>
    }

    /// Attaches a fake mod for `sessionID` that answers each `send` with
    /// `answer` and each `draft` with `draft` before an empty cursor tail.
    /// A silent mod's request times out at once.
    private func attachMod(
        _ harness: Harness, sessionID: String, answer: ModAnswer, draft: String = ""
    ) -> FakeMod {
        let sleep: @Sendable (Duration) async -> Void = answer == .silent
            ? { @Sendable _ in }
            : { @Sendable _ in try? await Task.sleep(for: .seconds(3600)) }
        let hub = ClaudeModChannelHub(sleep: sleep)
        let sends = Box<[String]>([])
        _ = hub.attach(sessionID: sessionID, channel: .init(
            write: { line in
                guard let message = ClaudeModChannelWire.decode(
                    ClaudeModChannelWire.Message.self, from: line.dropLast()
                ) else { return false }
                if message.kind == .draft {
                    hub.deliver(.init(
                        sessionID: sessionID, id: message.id, ok: true, text: draft, cursor: draft.utf16.count
                    ))
                    return true
                }
                guard message.kind == .send else { return false }
                sends.value.append(message.text ?? "")
                switch answer {
                case .undeliverable:
                    return false
                case .silent:
                    break
                case .submitted, .queued:
                    hub.deliver(.init(
                        sessionID: sessionID, id: message.id, ok: true,
                        submitted: true, queued: answer == .queued ? true : nil
                    ))
                case .refused(let reason):
                    hub.deliver(.init(sessionID: sessionID, id: message.id, ok: false, reason: reason))
                }
                return true
            },
            close: {}
        ))
        harness.viewModel.session.context.claudeModChannels = hub
        return FakeMod(sends: sends)
    }

    private func session(_ id: String, cwd: String, tty: String = "/dev/ttys009") -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: Self.agentPID, tty: tty, termProgram: "ghostty")
        return snapshot
    }

    /// A harness whose one session, "payments", runs in a pane of `herdr`.
    private func makeHarness(text: String, herdr: FakeHerdrSocket) -> Harness {
        let registry = ClaudeSessionRegistry(now: { Date(timeIntervalSince1970: 3_000_000) }, isProcessAlive: { _ in true })
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "pay", timestamp: 0, rawCwd: "/r/payments", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 9001, claudePID: 9001, tty: "/dev/ttys-inner",
                    herdrPaneID: "w1:p2", herdrSocketPath: herdr.socketPath
                )
            ),
            origin: local
        )
        return makeHarness(text: text, sessions: registry.liveSessions(), registry: registry)
    }

    private func makeHarness(
        text: String,
        sessions: [ClaudeSessionSnapshot],
        outcome: SessionPaneFocusOutcome = .focused(bundleID: TerminalScreenAllowlist.ghosttyBundleID),
        polishingService: FakePolishingService? = nil,
        registry: ClaudeSessionRegistry? = nil,
        recordDirectory: URL? = nil,
        editMonitor: EditSignalTestMonitor? = nil
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.overlaySpokenSendEnabled = true
        if polishingService != nil {
            settings.llmPolishingEnabled = true
            settings.agentPolishProfileEnabled = false
            settings.polishingBackendMode = .externalURL
            settings.llmPolishingEndpointURL = "http://127.0.0.1:8472/v1/chat/completions"
        }
        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = Self.focusedAppPID
        overlay.insertsThroughCommitter = true
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        viewModel.sessionStore = DictationSessionStore.inMemory()
        if let polishingService {
            viewModel.llmPolishingService = polishingService
            viewModel.dependencies.clock = ManualSessionClock().clock
            viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(outcome: nil)
        }
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { _ in TerminalScreenAllowlist.ghosttyBundleID }
        let records = Box<[DictationSessionRecord]>([])
        viewModel.dependencies.onSessionRecord = { records.value.append($0) }

        let inserted = Box<[(text: String, pid: pid_t?)]>([])
        let returns = Box<[pid_t]>([])
        let frontmost = Box<pid_t?>(Self.namedTerminalPID)
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { false },
            // The keyboard path needs a real app to activate: the text lands
            // through Accessibility, which reports the pid it targeted.
            accessibilityInserter: { text, pid in
                inserted.value.append((text, pid))
                return true
            },
            returnKeyPoster: { pid in
                returns.value.append(pid)
                return true
            },
            frontmostPIDReader: { frontmost.value },
            commandVPaster: { _ in false }
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        let focuser = FakeSessionPaneFocuser(outcome: outcome)
        let live = Box(sessions)
        let foreground = Box<[Int32]>([Self.agentPID])
        viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { live.value },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep,
            nicknames: SessionNicknameStore(load: []) { _ in },
            ttyForegroundPIDs: { _ in foreground.value }
        )
        let herdrClient = HerdrSocketClient(timeout: 2)
        viewModel.session.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry ?? ClaudeSessionRegistry(),
            herdrPanes: herdrClient,
            herdrPaneWriter: herdrClient
        )
        if let recordDirectory {
            viewModel.session.diagnosticRecordStore = DiagnosticRecordStore(directoryURL: recordDirectory)
        }
        if let editMonitor {
            let sleeper = EditSignalManualSleeper()
            let clock = EditSignalTestClock()
            viewModel.session.editSignalWatcher = EditSignalWatcher(
                monitor: editMonitor,
                now: { clock.now() },
                sleepFor: { await sleeper.sleep($0) }
            )
            addTeardownBlock { sleeper.fireAll() }
        }
        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.transcript.currentDictationEventText = text
        return Harness(
            viewModel: viewModel,
            overlay: overlay,
            focuser: focuser,
            inserted: inserted,
            returns: returns,
            frontmost: frontmost,
            records: records,
            live: live,
            foreground: foreground
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
