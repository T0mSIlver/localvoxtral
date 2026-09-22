import XCTest
@testable import localvoxtral

/// The transcript merge without a session: what a final resolves to against
/// the buffered partials, what Live Auto-Paste still has to type for it, and
/// what a promotion keeps. The view model suites prove the events reach it.
final class TranscriptAccumulatorTests: XCTestCase {
    // MARK: - resolvedFinalizedSegment boundary logic

    func testResolvedFinalizedSegment_finalExtendsPartialWithPeriod() {
        // Partial streamed "sparisce", final delivers the trailing period:
        // the resolved segment is the full "sparisce." — punctuation stays at
        // the end, never mid-word.
        var transcript = TranscriptAccumulator()
        transcript.pendingSegmentText = "sparisce"

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: "sparisce."), "sparisce.")
    }

    func testResolvedFinalizedSegment_finalOnlyPunctuation_appendsWithSpace() {
        // If the final carries only the punctuation, it appends after the
        // buffered word (with a space, per the existing boundary rule) — it
        // never splices into the word.
        var transcript = TranscriptAccumulator()
        transcript.pendingSegmentText = "sparisce"

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: "."), "sparisce .")
    }

    func testResolvedFinalizedSegment_emptyFinalReturnsPending() {
        var transcript = TranscriptAccumulator()
        transcript.pendingSegmentText = "al fondo"

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: ""), "al fondo")
    }

    func testResolvedFinalizedSegment_emptyPendingReturnsFinal() {
        let transcript = TranscriptAccumulator()

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: "al fondo,"), "al fondo,")
    }

    func testResolvedFinalizedSegment_disjointWordsJoinWithSpace() {
        // "al" buffered, "fondo," final → "al fondo," (space-joined).
        var transcript = TranscriptAccumulator()
        transcript.pendingSegmentText = "al"

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: "fondo,"), "al fondo,")
    }

    func testResolvedFinalizedSegment_partialPrefixOfFinal_returnsFinal() {
        var transcript = TranscriptAccumulator()
        transcript.pendingSegmentText = "al fon"

        XCTAssertEqual(transcript.resolvedFinalizedSegment(from: "al fondo,"), "al fondo,")
    }

    // MARK: - Partials

    func testPartialsAppendInArrivalOrderAndMirrorIntoTheLivePartial() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("spar")
        transcript.appendPartial("isce")
        transcript.appendPartial(".")

        XCTAssertEqual(transcript.pendingSegmentText, "sparisce.")
        XCTAssertEqual(transcript.livePartialText, "sparisce.")
        XCTAssertEqual(transcript.currentDictationEventText, "")
    }

    // MARK: - Finals and the live insertion

    func testFinalWithNoTypedPartialInsertsTheWholeSegment() {
        var transcript = TranscriptAccumulator()

        let finalized = transcript.applyFinal("al fondo,")

        XCTAssertEqual(
            finalized,
            TranscriptAccumulator.FinalizedSegment(text: "al fondo,", liveInsertion: "al fondo,")
        )
        XCTAssertEqual(transcript.currentDictationEventText, "al fondo,")
        XCTAssertEqual(transcript.lastFinalSegment, "al fondo,")
        XCTAssertEqual(transcript.transcriptText, "al fondo,")
        XCTAssertEqual(transcript.pendingSegmentText, "")
        XCTAssertEqual(transcript.livePartialText, "")
    }

    func testFinalThatExtendsTypedPartialsInsertsOnlyTheSuffix() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("you are")
        transcript.appendPartial(" right")

        let finalized = transcript.applyFinal("you are right, right?")

        XCTAssertEqual(finalized?.text, "you are right, right?")
        XCTAssertEqual(finalized?.liveInsertion, ", right?")
    }

    func testFinalThatRevisesTypedPartialsInsertsNothing() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("sparisce")

        let finalized = transcript.applyFinal("sparisci.")

        XCTAssertNotNil(finalized)
        XCTAssertNil(finalized?.liveInsertion, "live mode cannot rewrite typed text")
        XCTAssertEqual(transcript.pendingSegmentText, "")
    }

    func testFinalIdenticalToTypedPartialsInsertsNothing() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("sparisce")

        let finalized = transcript.applyFinal("sparisce")

        XCTAssertEqual(finalized?.text, "sparisce")
        XCTAssertNil(finalized?.liveInsertion)
    }

    func testEmptyFinalWithNothingBufferedResolvesToNothingAndClearsTheBuffers() {
        var transcript = TranscriptAccumulator()
        transcript.livePartialText = "   "

        XCTAssertNil(transcript.applyFinal(""))
        XCTAssertEqual(transcript.livePartialText, "")
        XCTAssertEqual(transcript.pendingSegmentText, "")
        XCTAssertEqual(transcript.currentDictationEventText, "")
        XCTAssertEqual(transcript.transcriptText, "")
    }

    func testSecondFinalJoinsTheDictationEventAndAddsATranscriptLine() {
        var transcript = TranscriptAccumulator()
        _ = transcript.applyFinal("first part.")
        _ = transcript.applyFinal("second part.")

        XCTAssertEqual(
            transcript.currentDictationEventText,
            TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: "second part.", existingText: "first part.")
        )
        XCTAssertEqual(transcript.lastFinalSegment, transcript.currentDictationEventText)
        XCTAssertEqual(transcript.transcriptText, "first part.\nsecond part.")
    }

    // MARK: - Promotion

    func testPromotionKeepsTheBufferedPartialInTheDictationEvent() {
        var transcript = TranscriptAccumulator()
        _ = transcript.applyFinal("first part.")
        transcript.appendPartial("and the rest")

        XCTAssertEqual(transcript.promotePendingToLatestSegment(), "and the rest")
        XCTAssertEqual(
            transcript.currentDictationEventText,
            TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: "and the rest", existingText: "first part.")
        )
        XCTAssertEqual(transcript.lastFinalSegment, transcript.currentDictationEventText)
        XCTAssertEqual(transcript.pendingSegmentText, "")
        XCTAssertEqual(transcript.livePartialText, "")
        XCTAssertEqual(
            transcript.transcriptText, "first part.",
            "a promotion does not add a transcript line; the reconnect path adds it itself"
        )
    }

    func testPromotionWithNothingBufferedChangesNothing() {
        var transcript = TranscriptAccumulator()
        _ = transcript.applyFinal("done.")
        let before = transcript

        XCTAssertNil(transcript.promotePendingToLatestSegment())
        XCTAssertEqual(transcript, before)
    }

    // MARK: - Resets and the popover transcript

    func testNewSessionEmptiesTheDictationEventButKeepsTheTranscript() {
        var transcript = TranscriptAccumulator()
        _ = transcript.applyFinal("kept.")
        transcript.appendPartial("dropped")

        transcript.resetForNewSession()

        XCTAssertEqual(transcript.currentDictationEventText, "")
        XCTAssertEqual(transcript.pendingSegmentText, "")
        XCTAssertEqual(transcript.livePartialText, "")
        XCTAssertEqual(transcript.transcriptText, "kept.")
        XCTAssertEqual(transcript.lastFinalSegment, "kept.")
    }

    func testFullTranscriptPutsThePartialInFlightOnTheLastLine() {
        var transcript = TranscriptAccumulator()
        XCTAssertEqual(transcript.fullTranscript, "")
        transcript.appendPartial(" typing ")
        XCTAssertEqual(transcript.fullTranscript, "typing")
        _ = transcript.applyFinal("typing done.")
        transcript.appendPartial("next")
        XCTAssertEqual(transcript.fullTranscript, "typing done.\nnext")
    }
}
