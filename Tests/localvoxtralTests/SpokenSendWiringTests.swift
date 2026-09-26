import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
/// The spoken send trigger (#318) wired into both output modes, through the
/// insertion hooks and the overlay mock. No test here reaches
/// `beginDictationSession`, so none arms the connect timeout.
@MainActor
final class SpokenSendWiringTests: XCTestCase {
    private static let terminalPID: pid_t = 4242
    private static let ghostty = "com.mitchellh.ghostty"
    private static let editor = "com.example.editor"
    private static let editorPID: pid_t = 555
    private static let claudeDesktop = "com.anthropic.claudefordesktop"

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    // MARK: - Overlay Buffer

    func testOverlayTriggerCommitsTheTextThenPressesReturnInTheSamePID() {
        let harness = makeOverlayHarness(text: "run the tests, send it.")

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests"])
        XCTAssertEqual(
            harness.events.value,
            ["commit:run the tests", "return:\(Self.terminalPID)"],
            "Return follows the commit, in the PID the overlay committed to"
        )
    }

    func testOverlaySettingOffCommitsTheTriggerAsTextAndPressesNoReturn() {
        let harness = makeOverlayHarness(text: "run the tests, send it.", enabled: false)

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests, send it."])
        XCTAssertEqual(harness.events.value, ["commit:run the tests, send it."])
    }

    func testOverlayNonTerminalTargetKeepsTheTriggerAndPressesNoReturn() {
        let harness = makeOverlayHarness(text: "run the tests send it", targetBundleID: Self.editor)

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests send it"])
        XCTAssertEqual(harness.events.value, ["commit:run the tests send it"])
    }

    /// #660: Claude Desktop's prompt box sends on Return, but the app is not
    /// a terminal. The trigger was typed as words there.
    func testOverlayClaudeDesktopTargetGetsTheReturn() {
        let harness = makeOverlayHarness(text: "run the tests, send it.", targetBundleID: Self.claudeDesktop)

        harness.stop()

        XCTAssertEqual(harness.events.value, ["commit:run the tests", "return:\(Self.terminalPID)"])
    }

    func testOverlayTriggerAlonePressesOnlyReturn() {
        let harness = makeOverlayHarness(text: "Send it.")

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, [""], "nothing to insert")
        XCTAssertEqual(harness.events.value, ["commit:", "return:\(Self.terminalPID)"])
    }

    func testOverlayWithoutATargetPIDKeepsTheTriggerAndPressesNoReturn() {
        let harness = makeOverlayHarness(text: "run the tests send now", pid: nil)

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests send now"])
        XCTAssertEqual(harness.events.value, ["commit:run the tests send now"])
    }

    func testOverlayUnderSecureKeyboardEntryKeepsTheTriggerAndPressesNoReturn() {
        let harness = makeOverlayHarness(text: "run the tests send now")
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests send now"])
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    func testOverlayFailedCommitPressesNoReturn() {
        let harness = makeOverlayHarness(text: "run the tests send it")
        harness.overlay.commitOutcome = .failed(message: "Unable to insert buffered text into the focused app.")

        harness.stop()

        XCTAssertEqual(harness.events.value, ["commit:run the tests"])
    }

    /// Codex review of #494 (Medium): an unknown bundle was judged by the
    /// element focused NOW. With a terminal focused while the commit target
    /// is an editor, the editor got the Return.
    func testOverlayUnknownTargetIsJudgedByItsOwnBundleNotTheFocusedElement() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueNotSettable }
        let harness = makeOverlayHarness(text: "run the tests send it", targetBundleID: Self.editor)

        harness.stop()

        XCTAssertEqual(harness.overlay.committedTexts, ["run the tests send it"])
        XCTAssertEqual(harness.events.value, ["commit:run the tests send it"])
    }

    func testOverlayPolishNeverSeesTheTrigger() async {
        let polishingService = FakePolishingService(returning: "Run the tests.")
        let harness = makeOverlayHarness(text: "run the tests, send it.", polishingService: polishingService)

        harness.stop()
        await awaitStoppedSessionCommit(harness.viewModel)

        let request = await polishingService.lastRequest
        XCTAssertEqual(request?.inputText, "run the tests")
        XCTAssertFalse(
            request?.userPrompts.joined().localizedCaseInsensitiveContains("send it") ?? true,
            "the trigger is cut before the request is built"
        )
        XCTAssertEqual(
            harness.events.value,
            ["commit:Run the tests.", "return:\(Self.terminalPID)"]
        )
    }

    // MARK: - Live Auto-Paste

    func testLiveOptionOffTypesPartialsAsTheyArrive() {
        let harness = makeLiveHarness(enabled: false)

        harness.viewModel.session.handle(event: .partialTranscript("run the "))
        // The terminal hold-back keeps the trailing space until the next word.
        XCTAssertEqual(harness.typedText, "run the", "partials are typed live, as before")

        harness.viewModel.session.handle(event: .partialTranscript("tests send it"))
        harness.viewModel.session.handle(event: .finalTranscript("run the tests send it"))
        harness.stop()

        XCTAssertEqual(harness.typedText, "run the tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    func testLiveOptionOnHoldsPartialsThenTypesTheSegmentAndPressesReturn() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run the "))
        harness.viewModel.session.handle(event: .partialTranscript("tests, send"))
        XCTAssertEqual(harness.typedText, "", "nothing is typed before the final")

        harness.viewModel.session.handle(event: .finalTranscript("run the tests, send it."))

        XCTAssertEqual(harness.typedText, "run the tests")
        XCTAssertEqual(harness.events.value.last, "return:\(Self.terminalPID)")
        XCTAssertEqual(
            harness.events.value.filter { $0.hasPrefix("return:") }.count, 1
        )
    }

    func testLiveRepeatedFinalDoesNotSubmitTwice() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("fix the build send"))
        harness.viewModel.session.handle(event: .finalTranscript("fix the build send it"))
        // A straggling delta of the same utterance, then the backend repeats
        // the final.
        harness.viewModel.session.handle(event: .partialTranscript(" it."))
        harness.viewModel.session.handle(event: .finalTranscript("fix the build send it"))

        XCTAssertEqual(harness.typedText, "fix the build")
        XCTAssertEqual(harness.events.value.filter { $0.hasPrefix("return:") }.count, 1)
    }

    func testLiveSegmentWithoutTheTriggerIsTypedAtItsFinalWithASpaceBeforeTheNext() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("first part"))
        harness.viewModel.session.handle(event: .finalTranscript("first part"))
        harness.viewModel.session.handle(event: .partialTranscript("second part send now"))
        harness.viewModel.session.handle(event: .finalTranscript("second part send now"))

        XCTAssertEqual(harness.typedText, "first part second part")
        XCTAssertEqual(harness.events.value.filter { $0.hasPrefix("return:") }.count, 1)
        XCTAssertEqual(harness.events.value.last, "return:\(Self.terminalPID)")
    }

    /// #536: vLLM ended a generation mid-word, and the next one opened on
    /// the rest of the word with no space. The terminal got "Pleas e help".
    func testLiveWordSplitAcrossGenerationsIsTypedWhole() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("So"))
        harness.viewModel.session.handle(event: .partialTranscript(" I need you."))
        harness.viewModel.session.handle(event: .partialTranscript(" Pleas"))
        harness.viewModel.session.handle(event: .finalTranscript("So I need you. Pleas"))
        harness.viewModel.session.handle(event: .partialTranscript("e help"))
        harness.viewModel.session.handle(event: .partialTranscript(" me constr"))
        harness.viewModel.session.handle(event: .finalTranscript("e help me constr"))
        // The next generation is cut short by the stop and promoted.
        harness.viewModel.session.handle(event: .partialTranscript("uct"))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)

        XCTAssertEqual(harness.typedText, "So I need you. Please help me construct")
    }

    /// GLM review of #541: the new generation re-heard the end of the word.
    /// The dictation event drops the repeat; the terminal must too.
    func testLiveWordSplitWithARepeatedTailIsNotTypedTwice() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("The"))
        harness.viewModel.session.handle(event: .partialTranscript(" information"))
        harness.viewModel.session.handle(event: .finalTranscript("The information"))
        harness.viewModel.session.handle(event: .partialTranscript("ation overload"))
        harness.viewModel.session.handle(event: .finalTranscript("ation overload"))

        XCTAssertEqual(harness.typedText, "The information overload")
        XCTAssertEqual(harness.viewModel.transcript.currentDictationEventText, "The information overload")
    }

    func testLiveLowercaseSegmentAfterPunctuationKeepsItsSpace() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("first"))
        harness.viewModel.session.handle(event: .partialTranscript(" part."))
        harness.viewModel.session.handle(event: .finalTranscript("first part."))
        harness.viewModel.session.handle(event: .partialTranscript("second part"))
        harness.viewModel.session.handle(event: .finalTranscript("second part"))

        XCTAssertEqual(harness.typedText, "first part. second part")
    }

    /// Codex review of #494 (High): the text went to whatever app had focus,
    /// the Return to the session's terminal. A segment typed elsewhere, then
    /// "send it" with the terminal refocused, submitted the terminal's own
    /// prompt.
    func testLiveReturnNeedsTheTextSinceTheLastReturnTypedIntoTheTerminal() {
        let harness = makeLiveHarness()

        harness.frontmost.value = 777
        harness.viewModel.session.handle(event: .partialTranscript("notes for later"))
        harness.viewModel.session.handle(event: .finalTranscript("notes for later"))
        harness.frontmost.value = Self.terminalPID
        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send it"))
        harness.stop()

        // No Return, so the trigger is typed as dictated. Per app: the space
        // between segments belongs only where the previous text landed in
        // the same app (Codex review round 4 of #494).
        XCTAssertEqual(harness.typedText(in: 777), "notes for later")
        XCTAssertEqual(harness.typedText(in: Self.terminalPID), "send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    func testLiveReturnNeedsTheSegmentTypedIntoTheTerminal() {
        let harness = makeLiveHarness()

        harness.frontmost.value = 777
        harness.viewModel.session.handle(event: .partialTranscript("run the tests send"))
        harness.viewModel.session.handle(event: .finalTranscript("run the tests send it"))
        harness.stop()

        // Not a terminal at the segment's first insertion: typed live as
        // dictated, trigger words included.
        XCTAssertEqual(harness.typedText, "run the tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review of #494 (High): a partial that ran past the final kept
    /// "send it" although the backend's final held no command.
    func testLiveBackendFinalDecidesTheTrigger() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run tests send it"))
        harness.viewModel.session.handle(event: .finalTranscript("run tests"))

        XCTAssertEqual(harness.typedText, "run tests")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review of #494 (Medium): a late partial that is a prefix of the
    /// repeated final passed for a new utterance.
    func testLiveLatePrefixPartialDoesNotResubmit() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send it"))
        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send it"))

        XCTAssertEqual(harness.events.value, ["return:\(Self.terminalPID)"])
    }

    /// Codex review round 2 of #494 (High): the trigger was switched on by the
    /// terminal verdict taken before the connection, while the target PID was
    /// read at audio start. Focus moving to an editor while connecting sent
    /// the text and the Return to the editor.
    func testLiveFocusMovedToAnEditorWhileConnectingPressesNoReturn() {
        let harness = makeLiveHarness(
            frontmostPID: Self.editorPID,
            commitTargetPID: Self.editorPID
        )

        harness.viewModel.session.handle(event: .partialTranscript("run the tests send it"))
        harness.viewModel.session.handle(event: .finalTranscript("run the tests send it"))
        harness.stop()

        XCTAssertEqual(harness.typedText, "run the tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review round 2 of #494 (High): a rejected Return cleared the
    /// record of where text went, so the next trigger passed and submitted the
    /// terminal's own prompt.
    func testLiveTextTypedElsewhereBlocksEveryLaterTrigger() {
        let harness = makeLiveHarness()

        harness.frontmost.value = 777
        harness.viewModel.session.handle(event: .partialTranscript("notes for later"))
        harness.viewModel.session.handle(event: .finalTranscript("notes for later"))
        harness.frontmost.value = Self.terminalPID
        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send it"))
        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send now"))

        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review round 2 of #494 (Medium): an empty final parsed the merged
    /// partials, so "send it" heard only in a partial pressed Return.
    func testLiveEmptyFinalNeverTriggers() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run tests send it"))
        harness.viewModel.session.handle(event: .finalTranscript(""))

        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review round 3 of #494 (High): keys posted under Secure Keyboard
    /// Entry are swallowed while posting reports success, so that text was
    /// recorded as landed in the terminal and a later "send it" submitted the
    /// terminal's own prompt.
    func testLiveTextTypedUnderSecureInputBlocksEveryLaterTrigger() {
        let harness = makeLiveHarness()
        let secureInput = Box(false)
        TerminalTargetDetector.debugSecureEventInputOverride = { secureInput.value }

        secureInput.value = true
        harness.viewModel.session.handle(event: .partialTranscript("notes for later"))
        harness.viewModel.session.handle(event: .finalTranscript("notes for later"))
        secureInput.value = false
        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("send it"))

        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// Codex review round 3 of #494 (Medium): the segment was held back while
    /// a terminal was in front, then focus moved to an editor before the
    /// final. The editor got the text without "send it" and no Return: the
    /// words were lost. The trigger is cut only when the Return will be sent.
    func testLiveTriggerIsTypedWholeWhenTheReturnWillNotBeSent() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run tests send"))
        XCTAssertEqual(harness.typedText, "")
        harness.frontmost.value = Self.editorPID
        harness.viewModel.session.handle(event: .finalTranscript("run tests send it"))
        harness.stop()

        XCTAssertEqual(harness.typedText, "run tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    func testLiveTriggerAlonePressesOnlyReturn() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("Send it."))

        XCTAssertEqual(harness.typedText, "")
        XCTAssertEqual(harness.events.value, ["return:\(Self.terminalPID)"])
    }

    /// A promotion is not a backend final: the withheld text is typed as
    /// dictated and never triggers.
    func testLiveWithheldPartialPromotedAtStopIsTypedAsTextWithoutReturn() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run the tests send it"))
        XCTAssertEqual(harness.typedText, "")
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)

        XCTAssertEqual(harness.typedText, "run the tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    /// #660: the same withholding and Return as in a terminal, while the
    /// session stays a text-field session.
    func testLiveClaudeDesktopTargetGetsTheReturn() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        let harness = makeLiveHarness(appBundleID: Self.claudeDesktop)
        XCTAssertFalse(harness.viewModel.session.sessionTargetIsTerminalLike)

        harness.viewModel.session.handle(event: .partialTranscript("run the tests, send"))
        XCTAssertEqual(harness.typedText, "", "nothing is typed before the final")

        harness.viewModel.session.handle(event: .finalTranscript("run the tests, send it."))

        XCTAssertEqual(harness.events.value, ["type:run the tests", "return:\(Self.terminalPID)"])
    }

    func testLiveNonTerminalTargetTypesLiveEvenWithTheOptionOn() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeLiveHarness(
            frontmostBundleID: Self.editor,
            frontmostPID: Self.editorPID,
            commitTargetPID: Self.editorPID
        )

        harness.viewModel.session.handle(event: .partialTranscript("run the tests send it"))
        XCTAssertEqual(harness.typedText, "run the tests send it")

        harness.viewModel.session.handle(event: .finalTranscript("run the tests send it"))
        harness.stop()

        XCTAssertEqual(harness.typedText, "run the tests send it")
        XCTAssertFalse(harness.events.value.contains { $0.hasPrefix("return:") })
    }

    // MARK: - Harnesses

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let events: Box<[String]>
        /// What the insertion service reads as the frontmost app.
        var frontmost = Box<pid_t?>(nil)
        /// Each posted chunk with the app frontmost when it was posted.
        var typedPerApp = Box<[(pid: pid_t?, text: String)]>([])

        /// What the app `pid` received, not every app's typing joined.
        func typedText(in pid: pid_t) -> String {
            typedPerApp.value.filter { $0.pid == pid }.map(\.text).joined()
        }

        var typedText: String {
            events.value
                .filter { $0.hasPrefix("type:") }
                .map { String($0.dropFirst("type:".count)) }
                .joined()
        }

        @MainActor
        func stop() {
            viewModel.isDictating = false
            viewModel.isFinalizingStop = true
            viewModel.session.finishStoppedSession(promotePendingSegment: false)
        }
    }

    private func makeOverlayHarness(
        text: String,
        enabled: Bool = true,
        pid: pid_t? = SpokenSendWiringTests.terminalPID,
        targetBundleID: String = SpokenSendWiringTests.ghostty,
        polishingService: FakePolishingService? = nil
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.overlaySpokenSendEnabled = enabled
        if polishingService != nil {
            settings.llmPolishingEnabled = true
            settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        }

        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = pid
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        if let polishingService {
            viewModel.llmPolishingService = polishingService
        }
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { $0 == pid ? targetBundleID : nil }

        let events = Box<[String]>([])
        overlay.onCommit = { [overlay] in
            events.value.append("commit:\(overlay.committedTexts.last ?? "")")
        }
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                events.value.append("return:\(pid)")
                return true
            }
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.transcript.currentDictationEventText = text
        return Harness(viewModel: viewModel, overlay: overlay, events: events)
    }

    /// `appBundleID` is the bundle of `terminalPID`; with the default
    /// `frontmostBundleID` it is also the app frontmost at session start.
    private func makeLiveHarness(
        enabled: Bool = true,
        appBundleID: String = SpokenSendWiringTests.ghostty,
        frontmostBundleID: String? = nil,
        frontmostPID: pid_t = SpokenSendWiringTests.terminalPID,
        commitTargetPID: pid_t = SpokenSendWiringTests.terminalPID
    ) -> Harness {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.liveSpokenSendEnabled = enabled
        settings.replacementDictionaryEnabled = false

        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = commitTargetPID
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { pid in
            pid == Self.terminalPID ? appBundleID : Self.editor
        }

        let events = Box<[String]>([])
        let frontmost = Box<pid_t?>(frontmostPID)
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

        let frontmostBundleID = frontmostBundleID ?? appBundleID
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { frontmostBundleID }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        viewModel.session.captureSessionTargetVerdict()
        viewModel.session.applyPreCapturedSessionTargetVerdict()

        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.session.configureLiveAutoPasteReplacementCorrectorForSession()
        return Harness(
            viewModel: viewModel,
            overlay: overlay,
            events: events,
            frontmost: frontmost,
            typedPerApp: typedPerApp
        )
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
