import XCTest
@testable import localvoxtralCore

/// The transcript merge without a session: what a final resolves to against
/// the buffered partials, what Live Auto-Paste still has to type for it, and
/// what a promotion keeps. The view model suites prove the events reach it.
final class TranscriptAccumulatorTests: XCTestCase {
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

    func testDisjointFinalJoinsBufferedTextWithASpace() {
        for (partial, final, expected) in [
            ("sparisce", ".", "sparisce ."),
            ("al", "fondo,", "al fondo,"),
        ] {
            var transcript = TranscriptAccumulator()
            transcript.appendPartial(partial)

            XCTAssertEqual(transcript.applyFinal(final)?.text, expected)
        }
    }

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

    // MARK: - A generation that ends mid-take (#516)

    // vLLM's realtime endpoint ends a generation with `transcription.done`
    // (the concatenated deltas) and the commit loop starts the next one on
    // the audio that follows, which can begin inside a word. Voxtral's
    // tokenizer carries a word's leading space on its first token, so the
    // next generation's first delta is the rest of that word with no space
    // in front ("e help" after "Pleas").

    /// Feeds one generation's raw deltas, then its `transcription.done`.
    private func feedGeneration(_ deltas: [String], into transcript: inout TranscriptAccumulator) {
        for delta in deltas {
            transcript.appendPartial(delta)
        }
        _ = transcript.applyFinal(deltas.joined())
    }

    func testAWordSplitAcrossGenerationsIsRejoined() {
        let specimens: [(first: [String], second: [String], expected: String)] = [
            (["So", " I", " need", " you", ".", " Pleas"], ["e", " help", " me", " construct"],
             "So I need you. Please help me construct"),
            (["Returni"], ["ng", " to", " the", " plan", ",", " what", " do", " I", " need", "?"],
             "Returning to the plan, what do I need?"),
            (["So", " ye"], ["ah", "'m", " going"], "So yeah'm going"),
        ]
        for specimen in specimens {
            var transcript = TranscriptAccumulator()
            feedGeneration(specimen.first, into: &transcript)
            feedGeneration(specimen.second, into: &transcript)

            XCTAssertEqual(transcript.currentDictationEventText, specimen.expected)
            XCTAssertEqual(transcript.overlayCommitText, specimen.expected)
        }
    }

    func testTheOverlayRejoinsTheWordBeforeTheNextGenerationEnds() {
        var transcript = TranscriptAccumulator()
        feedGeneration(["So", " I", " need", " you", ".", " Pleas"], into: &transcript)
        transcript.appendPartial("e")
        transcript.appendPartial(" help")

        XCTAssertEqual(transcript.overlayDisplayText, "So I need you. Please help")
        XCTAssertEqual(transcript.overlayCommitText, "So I need you. Please help")
    }

    func testAGenerationBoundaryIsNotALineBreak() {
        var transcript = TranscriptAccumulator()
        feedGeneration(["That", " is", " all", " the", " information", "."], into: &transcript)
        feedGeneration(["s"], into: &transcript)
        XCTAssertEqual(transcript.currentDictationEventText, "That is all the information. s")

        var wordBoundary = TranscriptAccumulator()
        feedGeneration(["First", " part", "."], into: &wordBoundary)
        feedGeneration([" Second", " part", "."], into: &wordBoundary)
        XCTAssertEqual(wordBoundary.currentDictationEventText, "First part. Second part.")
    }

    func testOneSharedLetterIsNotAnAlignment() {
        var transcript = TranscriptAccumulator()
        feedGeneration(["I", " need"], into: &transcript)
        feedGeneration([" doing", " this"], into: &transcript)
        XCTAssertEqual(transcript.currentDictationEventText, "I need doing this")

        var inFlight = TranscriptAccumulator()
        feedGeneration(["I", " need"], into: &inFlight)
        inFlight.appendPartial(" doing")
        XCTAssertEqual(inFlight.overlayDisplayText, "I need doing")
    }

    func testAMidWordSegmentThatRepeatsTheWordsTailIsNotDoubled() {
        var transcript = TranscriptAccumulator()
        feedGeneration(["The", " information"], into: &transcript)
        feedGeneration(["ation", " overload"], into: &transcript)
        XCTAssertEqual(transcript.currentDictationEventText, "The information overload")
    }

    func testAServerThatNeverSendsALeadingSpaceIsNotGlued() {
        // One final per utterance, lowercase, no leading space: nothing on
        // this wire says a segment starts mid-word.
        var transcript = TranscriptAccumulator()
        _ = transcript.applyFinal("hello world")
        _ = transcript.applyFinal("goodbye now")
        XCTAssertEqual(transcript.currentDictationEventText, "hello world goodbye now")

        var streamed = TranscriptAccumulator()
        feedGeneration(["hello", "world"], into: &streamed)
        feedGeneration(["goodbye"], into: &streamed)
        XCTAssertEqual(streamed.currentDictationEventText, "helloworld goodbye")
    }
}
