import Foundation
import XCTest
@testable import localvoxtral

// Integration tests for the Live Auto-Paste post-session dictionary sweep
// (issue #23, Stage 1). These drive the sweep through `finishStoppedSession`
// using the existing DI seams: `debugConfigureInsertionHooks` for the typing
// path, `debugConfigureSweepHooks` for the AX field operations, and a mock
// `OverlayBufferSessionCoordinating` + `AppConfigServing`.
//
// The sweep's safety property — it never corrupts user text — rests on the
// content-verification guard tested in `LiveAutoPasteSweepTests` and exercised
// here through the full view-model stop-finalization path.
#if DEBUG
@MainActor
final class DictationViewModelLiveAutoPasteSweepTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain instances for the
    // process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    // MARK: - Happy path: sweep applies replacements

    func testSweepAppliesReplacementsWhenEnabled() {
        let field = TestField("call me dash later")
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field
        )

        // Simulate a session that live-inserted "call me dash later" starting
        // at caret 0. The span bookkeeping is set up to match.
        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.textInsertion.recordSuccessfulLiveInsertion(
            utf16Length: ("call me dash later" as NSString).length
        )
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "call me - later")
        // Per design doc: currentDictationEventText stays as the raw spoken
        // text so the session record remains an accurate account.
        XCTAssertEqual(viewModel.currentDictationEventText, "call me dash later")
    }

    // MARK: - Setting disabled = no-op

    func testSweepIsNoOpWhenSettingDisabled() {
        let field = TestField("call me dash later")
        let spanReplacerCalls = CallCounter()
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: false,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            spanReplacerCalls: spanReplacerCalls
        )

        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.textInsertion.recordSuccessfulLiveInsertion(
            utf16Length: ("call me dash later" as NSString).length
        )
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "call me dash later")
        XCTAssertEqual(spanReplacerCalls.value, 0)
    }

    // MARK: - No dictionary entries = no-op

    func testSweepIsNoOpWhenDictionaryHasNoEntries() {
        let field = TestField("call me dash later")
        let spanReplacerCalls = CallCounter()
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: []),
            field: field,
            spanReplacerCalls: spanReplacerCalls
        )

        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.textInsertion.recordSuccessfulLiveInsertion(
            utf16Length: ("call me dash later" as NSString).length
        )
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "call me dash later")
        XCTAssertEqual(spanReplacerCalls.value, 0)
    }

    // MARK: - Non-pure case (content mismatch) = skip

    func testSweepSkipsWhenFieldContentDoesNotMatchRawText() {
        // The user manually edited "dash" to "DASH" inside the tracked span.
        // The sweep MUST NOT proceed — revising would destroy the user's edit.
        let field = TestField("call me DASH later")
        let spanReplacerCalls = CallCounter()
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            spanReplacerCalls: spanReplacerCalls
        )

        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.textInsertion.recordSuccessfulLiveInsertion(
            utf16Length: ("call me dash later" as NSString).length
        )
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        // Field is untouched; the user's edit survives.
        XCTAssertEqual(field.value, "call me DASH later")
        XCTAssertEqual(spanReplacerCalls.value, 0)
    }

    // MARK: - Span not tracked = no-op

    func testSweepSkipsWhenSpanNotTracked() {
        // beginLiveSessionSpan was never called (or the caret read failed).
        let field = TestField("call me dash later")
        let spanReplacerCalls = CallCounter()
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            spanReplacerCalls: spanReplacerCalls,
            caretLocationReader: { _ in nil }  // simulate caret read failure
        )

        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "call me dash later")
        XCTAssertEqual(spanReplacerCalls.value, 0)
    }

    // MARK: - Overlay mode = no sweep

    func testSweepDoesNotRunInOverlayMode() {
        let field = TestField("call me dash later")
        let spanReplacerCalls = CallCounter()
        let viewModel = makeViewModel(
            outputMode: .overlayBuffer,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            spanReplacerCalls: spanReplacerCalls
        )

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        // Overlay mode takes the overlay-commit path, not the live sweep path.
        XCTAssertEqual(field.value, "call me dash later")
        XCTAssertEqual(spanReplacerCalls.value, 0)
    }

    // MARK: - Full live event flow: span accumulated from real insertions

    func testSweepAppliesAfterLivePartialFlowAccumulatesSpan() {
        // Drive the sweep through the actual live partial path: partials are
        // typed via the unicode hook (which updates the field model), the span
        // accumulates from the successful insertions, then stop-finalization
        // runs the sweep. This is the regression test for issue #23 Stage 1.
        let field = TestField("")
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            unicodePosterAppendsToField: true
        )

        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)

        // One partial delivers the whole phrase; the unicode hook types it
        // into the field model and recordSuccessfulLiveInsertion accumulates.
        viewModel.handle(event: .partialTranscript("call me dash later"))
        XCTAssertEqual(field.value, "call me dash later")

        let span = viewModel.textInsertion.debugLiveSessionSpanSnapshot()
        XCTAssertEqual(span?.startCaret, 0)
        XCTAssertEqual(span?.insertedLength, ("call me dash later" as NSString).length)

        // Final transcript identical to the live text → no suffix insertion,
        // currentDictationEventText latches to the full phrase.
        viewModel.handle(event: .finalTranscript("call me dash later"))
        XCTAssertEqual(viewModel.currentDictationEventText, "call me dash later")

        viewModel.isDictating = false
        viewModel.isFinalizingStop = true
        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "call me - later")
    }

    // MARK: - Surrounding text preserved

    func testSweepPreservesSurroundingTextOutsideTheSpan() {
        // The session inserted text mid-document. The sweep must revise only
        // the tracked span, leaving the surrounding user text intact.
        let field = TestField("alpha call me dash later beta")
        let viewModel = makeViewModel(
            outputMode: .liveAutoPaste,
            sweepEnabled: true,
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "-", matches: ["dash"])
            ]),
            field: field,
            caretLocation: 6  // "alpha " is 6 chars
        )

        viewModel.textInsertion.beginLiveSessionSpan(preferredAppPID: nil)
        viewModel.textInsertion.recordSuccessfulLiveInsertion(
            utf16Length: ("call me dash later" as NSString).length
        )
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "call me dash later"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(field.value, "alpha call me - later beta")
    }

    // MARK: - Helpers

    private func makeViewModel(
        outputMode: DictationOutputMode,
        sweepEnabled: Bool,
        dictionary: ReplacementDictionary,
        field: TestField,
        spanReplacerCalls: CallCounter = CallCounter(),
        caretLocation: Int = 0,
        caretLocationReader: ((pid_t?) -> Int?)? = nil,
        unicodePosterAppendsToField: Bool = false
    ) -> DictationViewModel {
        let suiteName = "localvoxtral.DictationViewModelLiveAutoPasteSweepTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        settings.liveAutoPastePostProcessingEnabled = sweepEnabled

        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(replacementDictionary: dictionary)
        Self.retainedViewModels.append(viewModel)

        // Typing-path hooks: capture chunks and optionally model the field.
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                if unicodePosterAppendsToField {
                    field.value += chunk
                }
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        // Sweep hooks: model the target field's AX read/replace/selection.
        let resolvedCaretReader: (pid_t?) -> Int? = caretLocationReader ?? { _ in caretLocation }
        viewModel.textInsertion.debugConfigureSweepHooks(
            caretLocationReader: resolvedCaretReader,
            fieldReader: { _ in field.value },
            spanReplacer: { location, length, replacement, _ in
                spanReplacerCalls.value += 1
                let ns = field.value as NSString
                let safeLocation = min(max(0, location), ns.length)
                let safeLength = min(max(0, length), ns.length - safeLocation)
                field.value = ns.replacingCharacters(
                    in: NSRange(location: safeLocation, length: safeLength),
                    with: replacement
                )
                return field.value
            },
            selectionSetter: { _, _, _ in true }
        )

        return viewModel
    }
}

// MARK: - Test Helpers

@MainActor
private final class TestField {
    var value: String
    init(_ value: String) { self.value = value }
}

@MainActor
private final class CallCounter {
    var value: Int = 0
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
    ) -> OverlayBufferCommitOutcome { commitOutcome }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}

private final class MockAppConfigStore: AppConfigServing {
    private let replacementDictionary: ReplacementDictionary
    private(set) var loadReplacementDictionaryCallCount = 0

    init(replacementDictionary: ReplacementDictionary) {
        self.replacementDictionary = replacementDictionary
    }

    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        loadReplacementDictionaryCallCount += 1
        return replacementDictionary
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }
}
#endif
