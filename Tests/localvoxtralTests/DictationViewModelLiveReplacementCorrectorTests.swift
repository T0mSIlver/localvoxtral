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

    private func makeHarness(
        dictionaryEnabled: Bool = true,
        dictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        configStore: MockAppConfigStore? = nil,
        field: TestField = TestField(""),
        events: Box<[InsertionEvent]> = Box([]),
        caretLocationReader: ((pid_t?) -> Int?)? = nil,
        unicodePoster: ((String) -> Bool)? = nil,
        backspacePoster: ((Int) -> Bool)? = nil,
        liveReplacementSettleSleep: (() async -> Void)? = nil
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
    private(set) var loadReplacementDictionaryCallCount = 0

    init(replacementDictionary: ReplacementDictionary) {
        self.replacementDictionary = replacementDictionary
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
}
#endif
