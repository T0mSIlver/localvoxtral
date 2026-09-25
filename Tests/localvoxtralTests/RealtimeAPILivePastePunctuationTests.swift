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
//      path) never relocates punctuation into the middle of a word. That one
//      is pure, so `TranscriptAccumulatorTests` pins it without a view model.
#if DEBUG
@MainActor
final class RealtimeAPILivePastePunctuationTests: XCTestCase {
    private var insertedChunks: [String] = []

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.RealtimeAPILivePastePunctuationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.dictationOutputMode = .liveAutoPaste

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

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
            viewModel.session.handle(event: .partialTranscript(delta))
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
        XCTAssertEqual(viewModel.transcript.pendingSegmentText, "sparisce.")
        XCTAssertEqual(viewModel.transcript.livePartialText, "sparisce.")
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
        XCTAssertEqual(viewModel.transcript.pendingSegmentText, "sparis.ce")

        // Conversely, the same characters in left-to-right order are correct:
        let viewModel2 = makeViewModel()
        sendPartials(["sparisce", "."], to: viewModel2)
        XCTAssertEqual(viewModel2.transcript.pendingSegmentText, "sparisce.")
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

        viewModel.session.handle(event: .finalTranscript("sparisce."))

        XCTAssertEqual(insertedChunks, ["sparisce", "."])
        XCTAssertEqual(viewModel.transcript.currentDictationEventText, "sparisce.")
        XCTAssertEqual(viewModel.transcript.pendingSegmentText, "")
    }

    func testFinalTranscriptThatRevisesLiveTextIsNotInserted() {
        // When the final REVISES earlier content (not a pure extension — here
        // the spelling "sparisce" is corrected to "sparisci"), live mode
        // cannot rewrite already-typed text, so nothing extra is inserted.
        // Today's behavior is preserved (issue #23's territory).
        let viewModel = makeViewModel()
        sendPartials(["sparisce"], to: viewModel)
        XCTAssertEqual(insertedChunks, ["sparisce"])

        viewModel.session.handle(event: .finalTranscript("sparisci."))

        // The field keeps the live-typed text; no extra chunk is inserted.
        XCTAssertEqual(insertedChunks, ["sparisce"])
        XCTAssertEqual(viewModel.transcript.pendingSegmentText, "")
    }
}

#endif
