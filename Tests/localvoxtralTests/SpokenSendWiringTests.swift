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

    func testLiveTriggerAlonePressesOnlyReturn() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("send"))
        harness.viewModel.session.handle(event: .finalTranscript("Send it."))

        XCTAssertEqual(harness.typedText, "")
        XCTAssertEqual(harness.events.value, ["return:\(Self.terminalPID)"])
    }

    func testLiveHeldPartialIsTypedWhenTheStopPromotesIt() {
        let harness = makeLiveHarness()

        harness.viewModel.session.handle(event: .partialTranscript("run the tests send it"))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.session.finishStoppedSession(promotePendingSegment: true)

        XCTAssertEqual(harness.typedText, "run the tests")
        XCTAssertEqual(harness.events.value.last, "return:\(Self.terminalPID)")
    }

    func testLiveNonTerminalTargetTypesLiveEvenWithTheOptionOn() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeLiveHarness(frontmostBundleID: Self.editor)

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

    private func makeLiveHarness(
        enabled: Bool = true,
        frontmostBundleID: String = SpokenSendWiringTests.ghostty
    ) -> Harness {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.liveSpokenSendEnabled = enabled
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
            }
        )

        TerminalTargetDetector.debugFrontmostBundleIDOverride = { frontmostBundleID }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        viewModel.session.captureSessionTargetVerdict()
        viewModel.session.applyPreCapturedSessionTargetVerdict()

        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.session.configureLiveAutoPasteReplacementCorrectorForSession()
        return Harness(viewModel: viewModel, overlay: overlay, events: events)
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
