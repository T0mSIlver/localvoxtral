import CoreGraphics
import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
@MainActor
final class DictationViewModelLiveReplacementCorrectorTests: XCTestCase {
    private enum InsertionEvent: Equatable {
        case type(String)
        case backspace(Int)
    }

    private static var retainedViewModels: [DictationViewModel] = []

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    func testCorrectsWordCompletedAcrossDeltaBoundaries() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("vox"))
        harness.viewModel.handle(event: .partialTranscript("tral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("vox"),
            .type("tral "),
            .backspace(8),
            .type("localvoxtral "),
        ])
        XCTAssertEqual(harness.viewModel.pendingSegmentText, "voxtral ")
    }

    func testCorrectsMultiWordKeyWithLookbackWindow() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("local "))
        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("local "),
            .type("voxtral "),
            .backspace(14),
            .type("localvoxtral "),
        ])
    }

    func testCorrectsFinalUnboundedWordOnStopFlush() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral"))
        harness.viewModel.handle(event: .finalTranscript("voxtral"))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(harness.field.value, "localvoxtral")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral"),
            .backspace(7),
            .type("localvoxtral"),
        ])
        XCTAssertEqual(harness.viewModel.currentDictationEventText, "voxtral")
    }

    func testFinalTranscriptSuffixCanCompleteAndCorrectWordBeforeStop() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral"))
        harness.viewModel.handle(event: .finalTranscript("voxtral."))

        XCTAssertEqual(harness.field.value, "localvoxtral.")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral"),
            .type("."),
            .backspace(8),
            .type("localvoxtral."),
        ])
        XCTAssertEqual(harness.viewModel.currentDictationEventText, "voxtral.")
    }

    func testNoMatchWordsAreUntouched() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("hello "))

        XCTAssertEqual(harness.field.value, "hello ")
        XCTAssertEqual(harness.events.value, [.type("hello ")])
    }

    func testCorrectorDefersWhenCaretHasNotSettled() async {
        let field = TestField("")
        let events = Box<[InsertionEvent]>([])
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            field: field,
            events: events,
            caretLocationReader: { _ in
                if field.value.isEmpty { return 0 }
                return max(0, (field.value as NSString).length - 1)
            },
            liveReplacementSettleSleep: {}
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertTrue(harness.viewModel.textInsertion.debugLiveReplacementCorrectionIsInFlight)

        await harness.viewModel.textInsertion.debugWaitForLiveReplacementCorrectionTasks()
    }

    func testCorrectorStandsDownAfterCaretSettleTimeout() async {
        let field = TestField("")
        let events = Box<[InsertionEvent]>([])
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            field: field,
            events: events,
            caretLocationReader: { _ in
                if field.value.isEmpty { return 0 }
                return max(0, (field.value as NSString).length - 1)
            },
            liveReplacementSettleSleep: {}
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        await harness.viewModel.textInsertion.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral "),
        ])
        XCTAssertFalse(harness.viewModel.textInsertion.debugLiveReplacementCorrectorIsActive)
    }

    func testCorrectorWaitsForLaggedCaretAndThenCorrects() async {
        let field = TestField("")
        var staleReadsRemaining = 3
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            field: field,
            caretLocationReader: { _ in
                let currentLocation = (field.value as NSString).length
                guard currentLocation > 0, staleReadsRemaining > 0 else {
                    return currentLocation
                }
                staleReadsRemaining -= 1
                return 0
            },
            liveReplacementSettleSleep: {}
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertTrue(harness.viewModel.textInsertion.debugLiveReplacementCorrectionIsInFlight)

        await harness.viewModel.textInsertion.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral "),
            .backspace(8),
            .type("localvoxtral "),
        ])
        XCTAssertTrue(harness.viewModel.textInsertion.debugLiveReplacementCorrectorIsActive)
    }

    // Replaces the retired unguarded-correction test: a session without a
    // readable caret used to post blind backspaces; it now applies
    // replacements before typing via the hold-back stream instead.
    func testCaretUnavailableSessionAppliesReplacementBeforeTypingWithoutBackspaces() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            caretLocationReader: { _ in nil }
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("localvoxtral "),
        ])
        XCTAssertTrue(harness.viewModel.textInsertion.debugLiveHoldBackStreamIsActive)
    }

    func testDeltasArrivingDuringInFlightCorrectionAreBufferedUntilAfterCorrection() async {
        let field = TestField("")
        var staleReadsRemaining = 3
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            field: field,
            caretLocationReader: { _ in
                let currentLocation = (field.value as NSString).length
                guard currentLocation > 0, staleReadsRemaining > 0 else {
                    return currentLocation
                }
                staleReadsRemaining -= 1
                return 0
            },
            liveReplacementSettleSleep: {}
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        harness.viewModel.textInsertion.enqueueRealtimeInsertion("next ")

        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertEqual(harness.events.value, [.type("voxtral ")])

        await harness.viewModel.textInsertion.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(harness.field.value, "localvoxtral next ")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral "),
            .backspace(8),
            .type("localvoxtral "),
            .type("next "),
        ])
    }

    func testFailedReplacementRetypesOriginalTextBeforeStandingDown() {
        let field = TestField("")
        let events = Box<[InsertionEvent]>([])
        var replacementFailuresRemaining = 1
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            field: field,
            events: events,
            unicodePoster: { chunk in
                if chunk == "localvoxtral ", replacementFailuresRemaining > 0 {
                    replacementFailuresRemaining -= 1
                    return false
                }
                events.value.append(.type(chunk))
                field.value.append(chunk)
                return true
            }
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral "),
            .backspace(8),
            .type("voxtral "),
        ])
        XCTAssertFalse(harness.viewModel.textInsertion.debugLiveReplacementCorrectorIsActive)
        XCTAssertEqual(replacementFailuresRemaining, 0)
    }

    func testBackspaceCountUsesGraphemeCountForEmojiMatch() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "developer", matches: ["👩‍💻"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("👩‍💻 "))

        XCTAssertEqual(harness.field.value, "developer ")
        XCTAssertEqual(harness.events.value, [
            .type("👩‍💻 "),
            .backspace(2),
            .type("developer "),
        ])
    }

    func testShorterReplacementPreservesBoundary() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"]),
            ])
        )

        harness.viewModel.handle(event: .partialTranscript("dash,"))

        XCTAssertEqual(harness.field.value, "-,")
        XCTAssertEqual(harness.events.value, [
            .type("dash,"),
            .backspace(5),
            .type("-,"),
        ])
    }

    func testBoundaryCharactersArePreserved() {
        let cases: [(String, String)] = [
            ("voxtral,", "localvoxtral,"),
            ("voxtral.", "localvoxtral."),
            ("voxtral\n", "localvoxtral\n"),
        ]

        for (input, expected) in cases {
            let harness = makeHarness(
                dictionary: ReplacementDictionary(entries: [
                    ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                ])
            )

            harness.viewModel.handle(event: .partialTranscript(input))

            XCTAssertEqual(harness.field.value, expected)
            XCTAssertEqual(harness.events.value.last, .type(expected))
        }
    }

    func testReplacementDictionarySettingOffLeavesLivePathUntouchedAndDoesNotLoadDictionary() {
        let configStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ])
        )
        let harness = makeHarness(
            dictionaryEnabled: false,
            configStore: configStore
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(configStore.loadReplacementDictionaryCallCount, 0)
        XCTAssertEqual(harness.field.value, "voxtral ")
        XCTAssertEqual(harness.events.value, [.type("voxtral ")])
    }

    // MARK: - Terminal target wiring (TerminalTargetDetector → hold-back strategy)

    /// End-to-end regression for the field bug (2026-07-06): a terminal with a
    /// READABLE grid caret armed the guarded corrector, which then diverged and
    /// stood down — replacements never applied. With the detector wired, the
    /// terminal verdict must select the hold-back strategy: replacement applied
    /// before typing, zero backspace events.
    func testTerminalVerdictSelectsHoldBackAndAppliesReplacementWithoutBackspaces() {
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            caretLocationReader: { _ in 0 },
            frontmostBundleID: "com.mitchellh.ghostty"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertFalse(harness.events.value.contains {
            if case .backspace = $0 { return true }
            return false
        })
    }

    func testTerminalVerdictWithDictionaryDisabledStillSanitizesNewlines() {
        let harness = makeHarness(
            dictionaryEnabled: false,
            frontmostBundleID: "com.mitchellh.ghostty"
        )

        harness.viewModel.handle(event: .partialTranscript("ls -la\nnext "))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(harness.field.value, "ls -la next ")
        XCTAssertFalse(harness.events.value.contains {
            if case .backspace = $0 { return true }
            return false
        })
    }

    func testUserAllowlistedBundleSelectsHoldBack() {
        // cmux field case: the app reports a writable AX value, so detection
        // needs the user's terminal_apps.toml entry to classify it — and the
        // session must then behave exactly like a built-in terminal.
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            configStore: MockAppConfigStore(
                replacementDictionary: ReplacementDictionary(entries: [
                    ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                ]),
                terminalAppBundleIDs: ["com.cmuxterm.app"]
            ),
            frontmostBundleID: "com.cmuxterm.app"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        harness.viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertFalse(harness.events.value.contains {
            if case .backspace = $0 { return true }
            return false
        })
    }

    func testNonTerminalVerdictKeepsGuardedCorrector() {
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        let harness = makeHarness(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            frontmostBundleID: "com.example.editor"
        )

        harness.viewModel.handle(event: .partialTranscript("voxtral "))

        XCTAssertEqual(harness.field.value, "localvoxtral ")
        XCTAssertEqual(harness.events.value, [
            .type("voxtral "),
            .backspace(8),
            .type("localvoxtral "),
        ])
    }

    private func makeHarness(
        dictionaryEnabled: Bool = true,
        dictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        configStore: MockAppConfigStore? = nil,
        field: TestField = TestField(""),
        events: Box<[InsertionEvent]> = Box([]),
        caretLocationReader: ((pid_t?) -> Int?)? = nil,
        unicodePoster: ((String) -> Bool)? = nil,
        backspacePoster: ((Int) -> Bool)? = nil,
        liveReplacementSettleSleep: (() async -> Void)? = nil,
        frontmostBundleID: String? = nil
    ) -> (
        viewModel: DictationViewModel,
        field: TestField,
        events: Box<[InsertionEvent]>
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
                events.value.append(.type(chunk))
                field.value.append(chunk)
                return true
            },
            backspacePoster: backspacePoster ?? { count in
                events.value.append(.backspace(count))
                for _ in 0 ..< count {
                    if !field.value.isEmpty {
                        field.value.removeLast()
                    }
                }
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            caretLocationReader: caretLocationReader ?? { _ in (field.value as NSString).length },
            liveReplacementSettleSleep: liveReplacementSettleSleep
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

        return (viewModel, field, events)
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
