import Foundation
import XCTest
@testable import localvoxtral

// Characterization tests for issue #13 (punctuation inserted mid-word in Live
// Auto-Paste + voxmlx). These drive the production RealtimeAPI event path
// through DictationViewModel and capture exactly what TextInsertionService
// would type into the focused field, via the `#if DEBUG` insertion hooks.
//
// They lock in two invariants that are central to the issue analysis:
//   1. The RealtimeAPI partial-delta path is purely append-only: each
//      `.partialTranscript` delta is appended to `pendingSegmentText` and
//      forwarded verbatim to the insertion queue. There is no overlap/boundary
//      merge on this path, so punctuation can only land where the deltas
//      deliver it.
//   2. `resolvedFinalizedSegment` (the only boundary logic on the RealtimeAPI
//      path) never relocates punctuation into the middle of a word.
#if DEBUG
@MainActor
final class RealtimeAPILivePastePunctuationTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain instances for the
    // process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    private var insertedChunks: [String] = []

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.RealtimeAPILivePastePunctuationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .liveAutoPaste

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        Self.retainedViewModels.append(viewModel)

        // Configure the VM as an active Live Auto-Paste session so
        // `handle(event:)` accepts and routes transcript events.
        viewModel.isDictating = true

        // Capture every chunk the insertion service would type, and report
        // success so the pending buffer drains synchronously each enqueue.
        insertedChunks = []
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { [weak self] chunk in
                self?.insertedChunks.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        return viewModel
    }

    private func sendPartials(_ deltas: [String], to viewModel: DictationViewModel) {
        for delta in deltas {
            viewModel.handle(event: .partialTranscript(delta))
        }
    }

    // MARK: - Append-only partial path

    func testPartialDeltasAreInsertedVerbatimInArrivalOrder() {
        // A realistic incremental delta stream for "sparisce." delivered
        // left-to-right. The field must receive exactly these characters in
        // this order.
        let viewModel = makeViewModel()
        sendPartials(["spar", "isce", "."], to: viewModel)

        XCTAssertEqual(insertedChunks, ["spar", "isce", "."])
        XCTAssertEqual(viewModel.pendingSegmentText, "sparisce.")
        XCTAssertEqual(viewModel.livePartialText, "sparisce.")
    }

    func testPartialDeltasWholeWordThenPeriod_staysCorrect() {
        // The model emitting the whole word then a detached period is the
        // other common emission shape. It must still produce "sparisce.".
        let viewModel = makeViewModel()
        sendPartials(["sparisce", "."], to: viewModel)

        XCTAssertEqual(insertedChunks, ["sparisce", "."])
        XCTAssertEqual(viewModel.pendingSegmentText, "sparisce.")
    }

    func testPartialDeltasItalianPhraseWithComma_staysCorrect() {
        // "al fondo," emitted as incremental deltas keeps the comma at the end.
        let viewModel = makeViewModel()
        sendPartials(["al", " fondo", ","], to: viewModel)

        XCTAssertEqual(insertedChunks, ["al", " fondo", ","])
        XCTAssertEqual(viewModel.pendingSegmentText, "al fondo,")
    }

    func testPartialDeltasItalianApostropheElision_staysCorrect() {
        // Elisions ("l'acqua", "un'altra") must stream intact.
        let viewModel = makeViewModel()
        sendPartials(["l", "'acqua"], to: viewModel)
        sendPartials([" un", "'altra"], to: viewModel)

        XCTAssertEqual(insertedChunks, ["l", "'acqua", " un", "'altra"])
        XCTAssertEqual(viewModel.pendingSegmentText, "l'acqua un'altra")
    }

    func testMidWordPunctuationOnlyOccursWhenDeltasDeliverItOutOfOrder() {
        // This is the KEY characterization for issue #13: the ONLY way the
        // append-only live path yields "sparis.ce" is if the delta stream
        // itself delivers ".", then "ce" — i.e. punctuation arrives before the
        // rest of the word. The app faithfully types what it receives; it does
        // not synthesize this ordering from a well-formed stream.
        let viewModel = makeViewModel()
        sendPartials(["sparis", ".", "ce"], to: viewModel)

        XCTAssertEqual(insertedChunks, ["sparis", ".", "ce"])
        XCTAssertEqual(viewModel.pendingSegmentText, "sparis.ce")

        // Conversely, the same characters in left-to-right order are correct:
        let viewModel2 = makeViewModel()
        sendPartials(["sparisce", "."], to: viewModel2)
        XCTAssertEqual(viewModel2.pendingSegmentText, "sparisce.")
    }

    // MARK: - resolvedFinalizedSegment boundary logic

    func testResolvedFinalizedSegment_finalExtendsPartialWithPeriod() {
        // Partial streamed "sparisce", final delivers the trailing period:
        // the resolved segment is the full "sparisce." — punctuation stays at
        // the end, never mid-word.
        let viewModel = makeViewModel()
        viewModel.pendingSegmentText = "sparisce"

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: "sparisce."), "sparisce.")
    }

    func testResolvedFinalizedSegment_finalOnlyPunctuation_appendsWithSpace() {
        // If the final carries only the punctuation, it appends after the
        // buffered word (with a space, per the existing boundary rule) — it
        // never splices into the word.
        let viewModel = makeViewModel()
        viewModel.pendingSegmentText = "sparisce"

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: "."), "sparisce .")
    }

    func testResolvedFinalizedSegment_emptyFinalReturnsPending() {
        let viewModel = makeViewModel()
        viewModel.pendingSegmentText = "al fondo"

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: ""), "al fondo")
    }

    func testResolvedFinalizedSegment_emptyPendingReturnsFinal() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: "al fondo,"), "al fondo,")
    }

    func testResolvedFinalizedSegment_disjointWordsJoinWithSpace() {
        // "al" buffered, "fondo," final → "al fondo," (space-joined).
        let viewModel = makeViewModel()
        viewModel.pendingSegmentText = "al"

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: "fondo,"), "al fondo,")
    }

    func testResolvedFinalizedSegment_partialPrefixOfFinal_returnsFinal() {
        let viewModel = makeViewModel()
        viewModel.pendingSegmentText = "al fon"

        XCTAssertEqual(viewModel.resolvedFinalizedSegment(from: "al fondo,"), "al fondo,")
    }

    // MARK: - Final transcript vs live deltas

    func testFinalTranscriptInsertsTrailingPunctuationSuffixFromPureExtension() {
        // Regression for the trailing-punctuation finding from issue #13's
        // investigation: partials typed "sparisce" live, then the final
        // delivers the trailing "." that never came as a partial delta. The
        // final is a *pure extension* of the live-typed text, so the missing
        // suffix (".") is inserted into the field — without duplicating the
        // "sparisce" that is already there. Previously the `hadLiveDelta`
        // guard skipped re-insertion entirely and the field ended "sparisce".
        let viewModel = makeViewModel()
        sendPartials(["sparisce"], to: viewModel)
        XCTAssertEqual(insertedChunks, ["sparisce"])

        viewModel.handle(event: .finalTranscript("sparisce."))

        XCTAssertEqual(insertedChunks, ["sparisce", "."])
        XCTAssertEqual(viewModel.currentDictationEventText, "sparisce.")
        XCTAssertEqual(viewModel.pendingSegmentText, "")
    }

    func testFinalTranscriptInsertsMultiCharSuffixFromPureExtension() {
        // A multi-char trailing addition (", right?") that only arrives in the
        // final is inserted as the missing suffix.
        let viewModel = makeViewModel()
        sendPartials(["you are", " right"], to: viewModel)
        XCTAssertEqual(insertedChunks, ["you are", " right"])

        viewModel.handle(event: .finalTranscript("you are right, right?"))

        XCTAssertEqual(insertedChunks, ["you are", " right", ", right?"])
        XCTAssertEqual(viewModel.currentDictationEventText, "you are right, right?")
        XCTAssertEqual(viewModel.pendingSegmentText, "")
    }

    func testFinalTranscriptThatRevisesLiveTextIsNotInserted() {
        // When the final REVISES earlier content (not a pure extension — here
        // the spelling "sparisce" is corrected to "sparisci"), live mode
        // cannot rewrite already-typed text, so nothing extra is inserted.
        // Today's behavior is preserved (issue #23's territory).
        let viewModel = makeViewModel()
        sendPartials(["sparisce"], to: viewModel)
        XCTAssertEqual(insertedChunks, ["sparisce"])

        viewModel.handle(event: .finalTranscript("sparisci."))

        // The field keeps the live-typed text; no extra chunk is inserted.
        XCTAssertEqual(insertedChunks, ["sparisce"])
        XCTAssertEqual(viewModel.pendingSegmentText, "")
    }

    func testEmptyFinalTranscriptWithNoLiveDeltasInsertsNothing() {
        // No partials and an empty final: nothing is ever inserted.
        let viewModel = makeViewModel()

        viewModel.handle(event: .finalTranscript(""))

        XCTAssertEqual(insertedChunks, [])
        XCTAssertEqual(viewModel.currentDictationEventText, "")
        XCTAssertEqual(viewModel.pendingSegmentText, "")
    }

    func testFinalTranscriptIdenticalToLiveTextIsNoOp() {
        // Final equals the already-typed live text: the missing suffix is
        // empty, so nothing is inserted (no-op, no duplication).
        let viewModel = makeViewModel()
        sendPartials(["sparisce"], to: viewModel)
        XCTAssertEqual(insertedChunks, ["sparisce"])

        viewModel.handle(event: .finalTranscript("sparisce"))

        XCTAssertEqual(insertedChunks, ["sparisce"])
        XCTAssertEqual(viewModel.currentDictationEventText, "sparisce")
        XCTAssertEqual(viewModel.pendingSegmentText, "")
    }
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded
    var commitTargetAppPID: pid_t? = nil
    var captureLiveCommitTargetAppPIDCallCount = 0

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
    func captureLiveCommitTargetAppPID() {
        captureLiveCommitTargetAppPIDCallCount += 1
    }
}
#endif
