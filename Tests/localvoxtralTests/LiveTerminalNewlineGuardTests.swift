import XCTest
@testable import localvoxtral

#if DEBUG
/// #513: a Live Auto-Paste session started outside a terminal, whose focus
/// then moves to one, must still type a newline as a space there.
@MainActor
final class LiveTerminalNewlineGuardTests: XCTestCase {
    private static let ghostty = "com.mitchellh.ghostty"
    private static let editor = "com.example.editor"

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    // MARK: - The issue's steps, through the session controller

    func testNewlineReachesATerminalFocusedAfterAnEditorSessionStartedAsASpace() {
        let frontmost = Box(Self.editor)
        let typed = Box<[String]>([])
        let viewModel = makeLiveViewModel(frontmostBundleID: frontmost, typed: typed)
        XCTAssertFalse(viewModel.session.sessionTargetIsTerminalLike, "the session starts in an editor")

        viewModel.textInsertion.enqueueRealtimeInsertion("Draft the notes.")
        frontmost.value = Self.ghostty
        viewModel.textInsertion.enqueueRealtimeInsertion("\nRun the tests")
        viewModel.textInsertion.enqueueRealtimeInsertion("\n")
        viewModel.textInsertion.enqueueRealtimeInsertion(" please")

        XCTAssertFalse(typed.value.joined().contains("\n"), "a newline in a terminal acts as Enter")
        XCTAssertEqual(typed.value.joined(), "Draft the notes. Run the tests please")
    }

    func testAnEditorSessionThatStaysInTheEditorKeepsItsNewlines() {
        let frontmost = Box(Self.editor)
        let typed = Box<[String]>([])
        let viewModel = makeLiveViewModel(frontmostBundleID: frontmost, typed: typed)

        viewModel.textInsertion.enqueueRealtimeInsertion("First line.\nSecond line.")

        XCTAssertEqual(typed.value.joined(), "First line.\nSecond line.")
    }

    func testAnEditorSessionWithReplacementsStillGuardsALateTerminal() {
        let frontmost = Box(Self.editor)
        let typed = Box<[String]>([])
        let viewModel = makeLiveViewModel(
            frontmostBundleID: frontmost,
            typed: typed,
            replacements: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )
        XCTAssertTrue(viewModel.textInsertion.debugLiveHoldBackStreamIsActive)

        frontmost.value = Self.ghostty
        viewModel.textInsertion.enqueueRealtimeInsertion("voxtral\nship it")
        viewModel.textInsertion.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "localvoxtral ship it")
    }

    // MARK: - The guard alone

    func testCollapsesEveryNewlineOrTabRunWithItsWhitespaceToOneSpace() {
        let prepared = LiveTerminalNewlineGuard().prepare("a \n\t b\nc", targetIsTerminalLike: { true })

        XCTAssertEqual(prepared.text, "a b c")
        XCTAssertEqual(prepared.collapsedRunCount, 2)
    }

    func testKeepsPlainWhitespaceVerbatim() {
        let prepared = LiveTerminalNewlineGuard().prepare(
            "Pourquoi\u{00A0}? Oui  non\n",
            targetIsTerminalLike: { true }
        )

        XCTAssertEqual(prepared.text, "Pourquoi\u{00A0}? Oui  non ")
    }

    func testLeadingRunTypesNoSpaceAtSessionStartOrAfterWhitespace() {
        let atStart = LiveTerminalNewlineGuard().prepare("\nhello ", targetIsTerminalLike: { true })
        XCTAssertEqual(atStart.text, "hello ")

        let afterSpace = atStart.stateAfterTyping.prepare("\n world", targetIsTerminalLike: { true })
        XCTAssertEqual(afterSpace.text, "world")
    }

    func testNoDoubleSpaceAcrossAChunkThatEndsInACollapsedRun() {
        let first = LiveTerminalNewlineGuard()
            .prepare("hello", targetIsTerminalLike: { true })
            .stateAfterTyping
            .prepare("\n", targetIsTerminalLike: { true })
        XCTAssertEqual(first.text, " ")

        let second = first.stateAfterTyping.prepare("\n", targetIsTerminalLike: { true })
        XCTAssertEqual(second.text, "")

        let third = second.stateAfterTyping.prepare(" world", targetIsTerminalLike: { true })
        XCTAssertEqual(third.text, "world")
    }

    func testLeavesTextAloneWhenTheTargetIsNotATerminal() {
        let prepared = LiveTerminalNewlineGuard().prepare("a\nb\tc", targetIsTerminalLike: { false })

        XCTAssertEqual(prepared.text, "a\nb\tc")
        XCTAssertEqual(prepared.collapsedRunCount, 0)
    }

    func testChecksTheTargetOnlyForAChunkHoldingANewlineOrTab() {
        let checks = Box(0)
        let probe = { () -> Bool in
            checks.value += 1
            return true
        }

        _ = LiveTerminalNewlineGuard().prepare("plain words ", targetIsTerminalLike: probe)
        XCTAssertEqual(checks.value, 0)
        _ = LiveTerminalNewlineGuard().prepare("two\nlines", targetIsTerminalLike: probe)
        XCTAssertEqual(checks.value, 1)
    }

    func testAFailedInsertionRetriesFromTheOldState() {
        let service = TextInsertionService()
        let typed = Box<[String]>([])
        let accepts = Box(false)
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                guard accepts.value else { return false }
                typed.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
        service.setLiveLateTerminalProbe { true }

        service.enqueueRealtimeInsertion("hello\n")
        XCTAssertEqual(typed.value, [])
        accepts.value = true
        service.flushPendingRealtimeInsertion()
        service.enqueueRealtimeInsertion(" world")

        XCTAssertEqual(typed.value.joined(), "hello world")
    }

    // MARK: - Harness

    /// A Live Auto-Paste session configured the way `beginDictationSession`
    /// does it, with the target verdict taken while `frontmostBundleID`
    /// names an editor. Never reaches `beginDictationSession`, so no connect
    /// timeout is armed.
    private func makeLiveViewModel(
        frontmostBundleID: Box<String>,
        typed: Box<[String]>,
        replacements: ReplacementDictionary? = nil
    ) -> DictationViewModel {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.liveSpokenSendEnabled = false
        settings.replacementDictionaryEnabled = replacements != nil
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = replacements.map { MockAppConfigStore(replacementDictionary: $0) } ?? MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        TerminalTargetDetector.debugFrontmostBundleIDOverride = { frontmostBundleID.value }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        viewModel.session.captureSessionTargetVerdict()
        viewModel.session.applyPreCapturedSessionTargetVerdict()

        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.session.configureLiveAutoPasteReplacementCorrectorForSession()
        return viewModel
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
