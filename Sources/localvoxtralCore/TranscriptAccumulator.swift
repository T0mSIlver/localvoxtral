import Foundation

/// The text one dictation builds from the realtime events: the partial in
/// flight, the dictation event the overlay commits and auto-copy reads, and
/// the running transcript the popover shows.
///
/// Pure: the view model feeds it the preprocessed deltas and finals and acts
/// on what it returns (the live insertion, the overlay text).
package struct TranscriptAccumulator: Equatable, Sendable {
    /// Every finalized segment of the session, one per line.
    package var transcriptText = ""
    /// The partial the backend is still revising. Mirrors
    /// `pendingSegmentText` while partials arrive; the fallback when a final
    /// lands with nothing buffered.
    package var livePartialText = ""
    /// The deltas since the last final, appended in arrival order.
    package var pendingSegmentText = ""
    /// The finalized segments of the current dictation event, joined: what
    /// the overlay commits and the polisher is handed.
    package var currentDictationEventText = ""
    /// `currentDictationEventText` as of the last final, despite the name:
    /// what auto-copy puts on the clipboard in Live Auto-Paste.
    package var lastFinalSegment = ""
    /// Whether a delta this session started with a space. Only then does a
    /// segment without one start mid-word: a server that strips every
    /// leading space says nothing about where its words start.
    package var hasSeenSpacePrefixedDelta = false
    /// Words a stall dropped from the stream and a batch pass found (#1648),
    /// each at its offset in the deltas as the backend sent them. Spliced
    /// into `pendingSegmentText`; cleared with it.
    private var backfills: [Backfill] = []
    /// `pendingSegmentText` without the backfills, which the backend's final
    /// repeats. Kept only while there are backfills.
    private var unsplicedPendingText = ""
    /// Counts the pending segments, so a stall's mark goes stale once its
    /// segment is gone.
    private var pendingEpoch = 0

    package init() {}

    private struct Backfill: Equatable, Sendable {
        let offset: Int
        let text: String
    }

    /// Where the stream was when a stall ended: the backfill for that stall
    /// goes here, if this segment is still the pending one when it lands.
    package struct StallMark: Equatable, Sendable {
        fileprivate let epoch: Int
        fileprivate let offset: Int
    }

    package func stallMark() -> StallMark {
        StallMark(epoch: pendingEpoch, offset: unsplicedPending.count)
    }

    private var unsplicedPending: String {
        backfills.isEmpty ? pendingSegmentText : unsplicedPendingText
    }

    /// Splices the words of `batchText` that the stream lacks at `mark` into
    /// the pending segment. Returns them, or nil when the mark's segment is
    /// gone or `StallBackfill.wordsToInsert` finds none to place.
    package mutating func spliceBackfill(_ batchText: String, at mark: StallMark) -> String? {
        guard mark.epoch == pendingEpoch else { return nil }
        let raw = unsplicedPending
        let offset = min(mark.offset, raw.count)
        let split = raw.index(raw.startIndex, offsetBy: offset)
        guard let words = StallBackfill.wordsToInsert(
            batch: batchText, before: String(raw[..<split]), after: String(raw[split...]))
        else { return nil }
        unsplicedPendingText = raw
        backfills.append(Backfill(offset: offset, text: words))
        backfills.sort { $0.offset < $1.offset }
        pendingSegmentText = Self.splicing(backfills, into: raw)
        livePartialText = pendingSegmentText
        return words
    }

    /// `raw` with each backfill at its offset, set off by spaces.
    private static func splicing(_ backfills: [Backfill], into raw: String) -> String {
        var text = ""
        var cursor = raw.startIndex
        for backfill in backfills {
            let at = raw.index(raw.startIndex, offsetBy: backfill.offset)
            text += raw[cursor..<at]
            if let last = text.last, !last.isWhitespace { text += " " }
            text += backfill.text
            if at < raw.endIndex, !raw[at].isWhitespace { text += " " }
            cursor = at
        }
        text += raw[cursor...]
        return text
    }

    private mutating func clearBackfills() {
        backfills = []
        unsplicedPendingText = ""
        pendingEpoch += 1
    }

    /// A final that produced a segment, and what Live Auto-Paste still has
    /// to type for it.
    package struct FinalizedSegment: Equatable, Sendable {
        package let text: String
        /// The whole segment, led by one space when the final starts with
        /// whitespace, when no partial was typed live; the missing
        /// suffix when the final purely extends what was typed; nil when the
        /// final revises typed text, which live mode cannot rewrite.
        package let liveInsertion: String?
        /// Whether the segment starts inside the word the text before it
        /// ends on, so whatever types it whole adds no space in front.
        package var startsMidWord = false
    }

    /// Appends one preprocessed partial delta.
    package mutating func appendPartial(_ processedDelta: String) {
        pendingSegmentText.append(processedDelta)
        if !backfills.isEmpty { unsplicedPendingText.append(processedDelta) }
        livePartialText = pendingSegmentText
        if processedDelta.first?.isWhitespace == true {
            hasSeenSpacePrefixedDelta = true
        }
    }

    /// Folds a preprocessed final into the dictation event. Nil when the
    /// final and the buffered partials resolve to nothing; the buffers are
    /// cleared either way.
    package mutating func applyFinal(_ processedText: String) -> FinalizedSegment? {
        let finalizedSegment = resolvedFinalizedSegment(from: processedText)
        let segmentStartsMidWord = startsMidWord(
            bufferedRawText.trimmed.isEmpty ? processedText : bufferedRawText
        )
        let hadLiveDelta = !pendingSegmentText.trimmed.isEmpty
            || !livePartialText.trimmed.isEmpty
        // Text already typed into the field by the live partial path. Derived
        // from the same state the `hadLiveDelta` guard reads (accumulated
        // pending text, with live-partial text as fallback) so it cannot drift
        // from a parallel bookkeeping. Captured before the reset below.
        let liveInsertedText = pendingSegmentText.trimmed.isEmpty
            ? livePartialText
            : pendingSegmentText
        guard !finalizedSegment.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            clearBackfills()
            return nil
        }

        appendToTranscript(finalizedSegment)
        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: finalizedSegment,
            existingText: currentDictationEventText,
            segmentStartsMidWord: segmentStartsMidWord
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        clearBackfills()

        let liveInsertion: String?
        if !hadLiveDelta {
            // No partials were typed live: insert the whole segment, with
            // the space the backend put in front of it, as a first delta's
            // would have been typed. Only the session's first chunk loses it.
            let separator = processedText.first?.isWhitespace == true ? " " : ""
            liveInsertion = separator + finalizedSegment
        } else {
            // Partials were already typed live and the final is a pure
            // extension of them (e.g. a trailing "." that only arrived in
            // the final): insert only the missing suffix so the trailing
            // addition reaches the field without duplicating earlier text.
            // When the final revises earlier content the helper returns nil
            // and nothing is inserted — live mode cannot rewrite already
            // typed text.
            liveInsertion = TextMergingAlgorithms.livePasteExtensionSuffix(
                finalText: processedText,
                liveInsertedText: liveInsertedText
            )
        }
        return FinalizedSegment(
            text: finalizedSegment,
            liveInsertion: liveInsertion,
            startsMidWord: segmentStartsMidWord
        )
    }

    /// Promotes the buffered partial into the dictation event, as if a final
    /// had delivered it. Returns the promoted segment, or nil when nothing
    /// was buffered. `keepingOverlayMerge` makes the event the overlay's
    /// commit text, so an Overlay Buffer commit holds what the overlay
    /// showed: its merge drops a partial that replays the final with only
    /// formatting changes, which the final's merge would append (#1479).
    package mutating func promotePendingToLatestSegment(keepingOverlayMerge: Bool = false) -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = keepingOverlayMerge
            ? overlayCommitText.trimmed
            : TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: pendingSegment,
                existingText: currentDictationEventText,
                segmentStartsMidWord: pendingStartsMidWord
            )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        clearBackfills()

        return pendingSegment
    }

    /// Append a finalized segment to the running transcript.
    package mutating func appendToTranscript(_ segment: String) {
        if transcriptText.isEmpty {
            transcriptText = segment
        } else {
            transcriptText += "\n" + segment
        }
    }

    private func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmed
        let bufferedText = pendingSegmentText.trimmed
        let fallbackBufferedText = livePartialText.trimmed
        let pendingText = bufferedText.isEmpty ? fallbackBufferedText : bufferedText

        if finalizedText.isEmpty {
            return pendingText
        }

        if pendingText.isEmpty {
            return finalizedText
        }

        // The final repeats the deltas the backend sent, which lack the
        // backfilled words: keep the spliced text, plus whatever the final
        // adds past the deltas.
        if !backfills.isEmpty {
            let unspliced = unsplicedPendingText.trimmed
            if finalizedText.hasPrefix(unspliced) {
                return pendingText + finalizedText.dropFirst(unspliced.count)
            }
            if unspliced.hasPrefix(finalizedText) {
                return pendingText
            }
        }

        if finalizedText.count > pendingText.count, finalizedText.hasPrefix(pendingText) {
            return finalizedText
        }
        if pendingText.hasSuffix(finalizedText) {
            return pendingText
        }
        if pendingText.hasPrefix(finalizedText) {
            return pendingText
        }

        if let pendingLast = pendingText.last,
            let finalizedFirst = finalizedText.first,
            !pendingLast.isWhitespace,
            !finalizedFirst.isWhitespace
        {
            return pendingText + " " + finalizedText
        }
        return pendingText + finalizedText
    }

    /// The partial in flight as the backend sent it, leading space included.
    private var bufferedRawText: String {
        pendingSegmentText.trimmed.isEmpty ? livePartialText : pendingSegmentText
    }

    private func startsMidWord(_ rawText: String) -> Bool {
        hasSeenSpacePrefixedDelta && TextMergingAlgorithms.startsMidWord(rawText)
    }

    /// Whether the partial in flight starts mid-word: read before
    /// `promotePendingToLatestSegment`, which clears it.
    package var pendingStartsMidWord: Bool {
        startsMidWord(bufferedRawText)
    }

    /// The overlay's text while the user speaks, before streaming correction.
    package var overlayDisplayText: String {
        OverlayBufferTextAssembler.displayText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText,
            pendingStartsMidWord: pendingStartsMidWord
        )
    }

    /// The overlay's commit source, before streaming correction.
    package var overlayCommitText: String {
        OverlayBufferTextAssembler.commitText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText,
            pendingStartsMidWord: pendingStartsMidWord
        )
    }

    /// The running transcript with the partial in flight on its last line.
    package var fullTranscript: String {
        let finalPart = transcriptText.trimmed
        let livePart = livePartialText.trimmed

        if finalPart.isEmpty { return livePart }
        if livePart.isEmpty { return finalPart }
        return finalPart + "\n" + livePart
    }

    /// Drops the partial in flight.
    package mutating func clearPending() {
        livePartialText = ""
        pendingSegmentText = ""
        clearBackfills()
    }

    /// A new session starts with an empty dictation event. The running
    /// transcript and the latest segment carry over.
    package mutating func resetForNewSession() {
        livePartialText = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        hasSeenSpacePrefixedDelta = false
        clearBackfills()
    }
}
