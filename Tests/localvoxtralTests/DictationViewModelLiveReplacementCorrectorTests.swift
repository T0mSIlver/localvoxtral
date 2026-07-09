import CoreGraphics
import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
/// End-to-end Live Auto-Paste replacement behavior at the view-model level.
/// Every target applies dictionary replacements BEFORE typing through the
/// hold-back stream: matched words are released already corrected, no target
/// ever receives a backspace, and a word held at session stop is flushed with
/// its replacement applied (the 2026-07-08 field regression — a final-word
/// replacement was deferred by the old guarded corrector and dropped at stop).
@MainActor
final class DictationViewModelLiveReplacementCorrectorTests: XCTestCase {
    private static var retainedViewModels: [DictationViewModel] = []

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    func testCorrectsWordCompletedAcrossDeltaBoundaries() {
        let harness = makeHarness(
            dictionary: voxtralDictionary
        )

        harness.viewModel.handle(event: .partialTranscript("vox"))
        XCTAssertEqual(harness.typed.value, [], "partial word stays held until a boundary")
        harness.viewModel.handle(event: .partialTranscript("tral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(
            harness.typed.value, ["localvoxtral "],
            "the corrected word is released once its boundary arrives — no raw type, no backspace"
        )
        XCTAssertEqual(harness.viewModel.pendingSegmentText, "voxtral ")
    }

    func testCorrectsMultiWordKeyWithLookbackWindow() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("local "))
        // "local" could begin the two-word match, so it stays held.
        XCTAssertEqual(harness.typed.value, [], "a possible first match word stays held")

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        // Once the match applies, "localvoxtral" begins no rule, so it is
        // released immediately rather than waiting for the stop flush.
        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral ")

        stop(harness.viewModel)

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral ")
    }

    func testCorrectsFinalUnboundedWordOnStopFlush() {
        let harness = makeHarness(
            dictionary: voxtralDictionary
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral"))
        harness.viewModel.handle(event: .finalTranscript("voxtral"))
        XCTAssertEqual(harness.typed.value, [], "the unbounded final word stays held until stop")

        stop(harness.viewModel)

        XCTAssertEqual(harness.field.value, "localvoxtral")
        XCTAssertEqual(harness.typed.value, ["localvoxtral"])
        XCTAssertEqual(harness.viewModel.currentDictationEventText, "voxtral")
    }

    // The exact field regression (2026-07-08), end to end: a short dictation
    // whose ONLY replacement is the final word, with no trailing whitespace.
    // The old guarded corrector deferred it waiting for the caret to settle and
    // dropped it at stop; nothing was replaced. The hold-back stream applies it
    // on the stop flush.
    func testFinalWordOnlyReplacementIsAppliedAtStop() {
        // Writable AX value → deterministically classified non-terminal,
        // independent of whether the CI host has Accessibility trust.
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            frontmostBundleID: "com.example.editor"
        )

        harness.viewModel.handle(event: .partialTranscript("vox"))
        harness.viewModel.handle(event: .finalTranscript("voxtral"))
        XCTAssertEqual(harness.typed.value, [])

        stop(harness.viewModel)

        XCTAssertEqual(
            harness.field.value, "localvoxtral",
            "the only replacement in the session — the final word — must not be dropped at stop"
        )
        XCTAssertEqual(harness.typed.value, ["localvoxtral"])
    }

    func testNoMatchWordsAreUntouched() {
        let harness = makeHarness(
            dictionary: voxtralDictionary
        )

        harness.viewModel.handle(event: .partialTranscript("hello "))

        XCTAssertEqual(harness.field.value, "hello ")
        XCTAssertEqual(
            harness.typed.value, ["hello "],
            "a completed non-matching word is released promptly, unchanged"
        )
    }

    func testWhitespaceBoundaryReleasesCorrectedTextInRegularEditor() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            frontmostBundleID: "com.example.editor"
        )

        // A newline is a whitespace boundary: it completes the word and, in a
        // regular (non-terminal) editor, is preserved verbatim.
        harness.viewModel.handle(event: .partialTranscript("voxtral\n"))

        XCTAssertEqual(harness.field.value, "localvoxtral\n")
        XCTAssertEqual(harness.typed.value, ["localvoxtral\n"])
    }

    func testNonTerminalSessionUsesHoldBackStream() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            frontmostBundleID: "com.example.editor"
        )
        XCTAssertTrue(harness.viewModel.textInsertion.debugLiveHoldBackStreamIsActive)

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.typed.value, ["localvoxtral "])
    }

    func testReplacementDictionarySettingOffLeavesLivePathUntouchedAndDoesNotLoadDictionary() {
        let configStore = MockAppConfigStore(
            replacementDictionary: voxtralDictionary
        )
        let harness = makeHarness(
            dictionaryEnabled: false,
            configStore: configStore
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        stop(harness.viewModel)

        XCTAssertEqual(configStore.loadReplacementDictionaryCallCount, 0)
        XCTAssertFalse(
            harness.viewModel.textInsertion.debugLiveHoldBackStreamIsActive,
            "dictionary off in a non-terminal target types directly, no hold-back"
        )
        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertEqual(harness.typed.value, ["voxtral "])
    }

    // MARK: - Terminal target wiring (TerminalTargetDetector → hold-back strategy)

    /// End-to-end regression for the field bug (2026-07-06): a terminal with a
    /// READABLE grid caret armed the guarded corrector, which then diverged and
    /// stood down — replacements never applied. The terminal verdict now selects
    /// the hold-back stream: replacement applied before typing.
    func testTerminalVerdictSelectsHoldBackAndAppliesReplacement() {
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            frontmostBundleID: "com.mitchellh.ghostty"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        stop(harness.viewModel)

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        // The terminal sanitizer buffers the trailing space until stop, so the
        // release may arrive as more than one chunk — assert the joined text.
        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral ")
    }

    func testTerminalVerdictWithDictionaryDisabledStillSanitizesNewlines() {
        let harness = makeHarness(
            dictionaryEnabled: false,
            frontmostBundleID: "com.mitchellh.ghostty"
        )

        harness.viewModel.handle(event: .partialTranscript("ls -la\nnext "))
        stop(harness.viewModel)

        XCTAssertEqual(harness.field.value, "ls -la next ")
    }

    func testUserAllowlistedBundleSelectsHoldBack() {
        // The original cmux field case (writable AX value, only the user's
        // terminal_apps.toml entry can classify it) — cmux itself is built-in
        // now, so an unknown stand-in keeps the user path exercised. The
        // session must behave exactly like a built-in terminal.
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            configStore: MockAppConfigStore(
                replacementDictionary: voxtralDictionary,
                terminalAppBundleIDs: ["com.example.myterminal"]
            ),
            frontmostBundleID: "com.example.myterminal"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        stop(harness.viewModel)

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral ")
    }

    func testCmuxIsTerminalLikeViaBuiltInAllowlist() {
        // cmux graduated from the user allowlist to built-in (owner request,
        // 2026-07-08): terminal behavior with zero config, even though its AX
        // value reads writable.
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: voxtralDictionary,
            frontmostBundleID: "com.cmuxterm.app"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral\nls "))
        stop(harness.viewModel)

        XCTAssertEqual(
            harness.field.value, "localvoxtral ls ",
            "replacement applied AND the newline sanitized — full terminal treatment with zero config"
        )
    }

    // MARK: - Harness

    private var voxtralDictionary: ReplacementDictionary {
        ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
        ])
    }

    private func stop(_ viewModel: DictationViewModel) {
        viewModel.isDictating = false
        viewModel.isFinalizingStop = true
        viewModel.finishStoppedSession(promotePendingSegment: false)
    }

    private func makeHarness(
        dictionaryEnabled: Bool = true,
        dictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        configStore: MockAppConfigStore? = nil,
        field: TestField = TestField(""),
        typed: Box<[String]> = Box([]),
        unicodePoster: ((String) -> Bool)? = nil,
        frontmostBundleID: String? = nil
    ) -> (
        viewModel: DictationViewModel,
        field: TestField,
        typed: Box<[String]>
    ) {
        let suiteName = "localvoxtral.DictationViewModelLiveReplacementCorrectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .liveAutoPaste
        settings.replacementDictionaryEnabled = dictionaryEnabled

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore ?? MockAppConfigStore(replacementDictionary: dictionary)
        Self.retainedViewModels.append(viewModel)

        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: unicodePoster ?? { chunk in
                typed.value.append(chunk)
                field.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        if let frontmostBundleID {
            TerminalTargetDetector.debugFrontmostBundleIDOverride = { frontmostBundleID }
            TerminalTargetDetector.debugSecureEventInputOverride = { false }
            viewModel.captureSessionTargetVerdict()
            viewModel.applyPreCapturedSessionTargetVerdict()
        }

        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.configureLiveAutoPasteReplacementCorrectorForSession()

        return (viewModel, field, typed)
    }
}

@MainActor
private final class TestField {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: CGRect(x: 0, y: 0, width: 100, height: 24), source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        commitOutcome
    }
    func reset() {}
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func captureLiveCommitTargetAppPID() {}
}

private final class MockAppConfigStore: AppConfigServing {
    private let replacementDictionary: ReplacementDictionary
    private let terminalAppBundleIDs: [String]
    private(set) var loadReplacementDictionaryCallCount = 0

    init(
        replacementDictionary: ReplacementDictionary,
        terminalAppBundleIDs: [String] = []
    ) {
        self.replacementDictionary = replacementDictionary
        self.terminalAppBundleIDs = terminalAppBundleIDs
    }

    func configDirectoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        loadReplacementDictionaryCallCount += 1
        return replacementDictionary
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "{{input_text}}", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        terminalAppBundleIDs
    }
}
#endif
