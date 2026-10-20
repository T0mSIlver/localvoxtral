import Foundation
import XCTest
@testable import localvoxtralCore

/// The splice of a stall's batch text into the realtime text (#1648).
final class StallBackfillTests: XCTestCase {
    // MARK: - Seams

    func testTheWordsBetweenBothOverlapsAreInserted() {
        XCTAssertEqual(
            StallBackfill.wordsToInsert(
                batch: "Ship it tonight, then archive every session. And then",
                before: "we should ship it tonight",
                after: " and then start fresh"),
            "then archive every session.")
    }

    func testAWordTheWindowCutInHalfMayPrecedeTheOverlap() {
        XCTAssertEqual(
            StallBackfill.wordsToInsert(
                batch: "ight ship it tonight then archive",
                before: "we should ship it tonight", after: ""),
            "then archive")
    }

    /// Placing words with nothing in common with the text before the hole
    /// could repeat or misorder a phrase.
    func testNoOverlapWithTheTextBeforeKeepsTheHole() {
        XCTAssertNil(StallBackfill.wordsToInsert(
            batch: "something else entirely", before: "we should ship it tonight", after: ""))
        XCTAssertNil(
            StallBackfill.wordsToInsert(
                batch: "ship tonight then archive", before: "we should ship it tonight", after: ""),
            "one common word is not enough")
    }

    func testAStallAtTheStartNeedsNoLeadingOverlap() {
        XCTAssertEqual(
            StallBackfill.wordsToInsert(
                batch: "Open the release notes and", before: "", after: " and read them"),
            "Open the release notes")
    }

    func testABatchThatSaysNothingNewInsertsNothing() {
        XCTAssertNil(StallBackfill.wordsToInsert(
            batch: "ship it tonight. And then", before: "ship it tonight", after: " and then go"))
    }

    func testOnlyAQuietStallIsSkipped() {
        let speech = MistralStreamHealth.StallEnd(silentFor: 7.5, audioSeconds: 7.5, loudestDBFS: -33)
        let quiet = MistralStreamHealth.StallEnd(silentFor: 7.5, audioSeconds: 7.5, loudestDBFS: -55)
        let unmeasured = MistralStreamHealth.StallEnd(silentFor: 7.5, audioSeconds: 7.5, loudestDBFS: nil)
        XCTAssertTrue(StallBackfill.isWorthBackfilling(speech))
        XCTAssertFalse(StallBackfill.isWorthBackfilling(quiet))
        XCTAssertFalse(StallBackfill.isWorthBackfilling(unmeasured))
        XCTAssertEqual(StallBackfill.windowBytes(for: speech), Int((7.5 + StallBackfill.leadSeconds) * 32_000))
    }

    // MARK: - Accumulator

    /// The backend's final repeats its deltas, which lack the backfilled
    /// words; folding it in must keep them, and add what the final adds.
    func testABackfillSurvivesTheFinalThatLacksIt() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("we should ship it tonight")
        let mark = transcript.stallMark()
        transcript.appendPartial(" and then start fresh")

        XCTAssertEqual(
            transcript.spliceBackfill("ship it tonight then archive every session and then", at: mark),
            "then archive every session")
        XCTAssertEqual(
            transcript.overlayDisplayText, "we should ship it tonight then archive every session and then start fresh")
        transcript.appendPartial(" tomorrow")

        _ = transcript.applyFinal("we should ship it tonight and then start fresh tomorrow.")
        XCTAssertEqual(
            transcript.currentDictationEventText,
            "we should ship it tonight then archive every session and then start fresh tomorrow.")
    }

    func testABackfillForACommittedSegmentIsDropped() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("we should ship it tonight")
        let mark = transcript.stallMark()
        _ = transcript.applyFinal("we should ship it tonight")
        transcript.appendPartial(" new segment")

        XCTAssertNil(transcript.spliceBackfill("ship it tonight then archive", at: mark))
        XCTAssertEqual(transcript.pendingSegmentText, " new segment")
    }

    /// After a reconnect committed the text before the stall, the lead
    /// repeats its end: those words are not inserted again.
    func testAtASegmentsStartTheCommittedTextIsTheTextBefore() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("we should ship it tonight")
        _ = transcript.promotePendingToLatestSegment()
        let mark = transcript.stallMark()
        transcript.appendPartial(" and then start fresh")

        XCTAssertEqual(
            transcript.spliceBackfill("ship it tonight then archive every session and then", at: mark),
            "then archive every session")
        XCTAssertNil(
            transcript.spliceBackfill("something unrelated and then", at: mark),
            "no overlap with the committed text keeps the hole")
    }

    /// A backfill that lands before the segment's first delta goes ahead of
    /// the final, set off by a space.
    func testABackfillIntoAnEmptySegmentPrecedesTheFinal() {
        var transcript = TranscriptAccumulator()
        let mark = transcript.stallMark()
        XCTAssertEqual(transcript.spliceBackfill("Open the release notes", at: mark), "Open the release notes")

        _ = transcript.applyFinal("and read them")
        XCTAssertEqual(transcript.currentDictationEventText, "Open the release notes and read them")
    }

    /// A later stall's backfill landing first must not shift an earlier one.
    func testTwoBackfillsLandOutOfOrder() {
        var transcript = TranscriptAccumulator()
        transcript.appendPartial("alpha beta")
        let first = transcript.stallMark()
        transcript.appendPartial(" gamma delta")
        let second = transcript.stallMark()
        transcript.appendPartial(" epsilon")

        XCTAssertNotNil(transcript.spliceBackfill("gamma delta two three", at: second))
        XCTAssertNotNil(transcript.spliceBackfill("alpha beta one", at: first))
        XCTAssertEqual(transcript.pendingSegmentText, "alpha beta one gamma delta two three epsilon")
    }
}
