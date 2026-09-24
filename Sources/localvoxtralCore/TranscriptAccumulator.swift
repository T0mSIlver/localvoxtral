import Foundation

/// The text one dictation builds from the realtime events: the partial in
/// flight, the dictation event the overlay commits, the latest segment the
/// copy actions read, and the running transcript the popover shows.
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
    /// What "Copy latest segment" and "Paste latest segment" read.
    package var lastFinalSegment = ""

    package init() {}

    /// A final that produced a segment, and what Live Auto-Paste still has
    /// to type for it.
    package struct FinalizedSegment: Equatable, Sendable {
        package let text: String
        /// The whole segment when no partial was typed live; the missing
        /// suffix when the final purely extends what was typed; nil when the
        /// final revises typed text, which live mode cannot rewrite.
        package let liveInsertion: String?
    }

    /// Appends one preprocessed partial delta.
    package mutating func appendPartial(_ processedDelta: String) {
        pendingSegmentText.append(processedDelta)
        livePartialText = pendingSegmentText
    }

    /// Folds a preprocessed final into the dictation event. Nil when the
    /// final and the buffered partials resolve to nothing; the buffers are
    /// cleared either way.
    package mutating func applyFinal(_ processedText: String) -> FinalizedSegment? {
        let finalizedSegment = resolvedFinalizedSegment(from: processedText)
        let segmentStartsMidWord = TextMergingAlgorithms.startsMidWord(
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

        let liveInsertion: String?
        if !hadLiveDelta {
            // No partials were typed live: insert the whole segment.
            liveInsertion = finalizedSegment
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
        return FinalizedSegment(text: finalizedSegment, liveInsertion: liveInsertion)
    }

    /// Promotes the buffered partial into the dictation event, as if a final
    /// had delivered it. Returns the promoted segment, or nil when nothing
    /// was buffered.
    package mutating func promotePendingToLatestSegment() -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText,
            segmentStartsMidWord: TextMergingAlgorithms.startsMidWord(bufferedRawText)
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""

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

    package func resolvedFinalizedSegment(from finalText: String) -> String {
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

    /// The overlay's text while the user speaks, before streaming correction.
    package var overlayDisplayText: String {
        OverlayBufferTextAssembler.displayText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText,
            pendingStartsMidWord: TextMergingAlgorithms.startsMidWord(bufferedRawText)
        )
    }

    /// The overlay's commit source, before streaming correction.
    package var overlayCommitText: String {
        OverlayBufferTextAssembler.commitText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText,
            pendingStartsMidWord: TextMergingAlgorithms.startsMidWord(bufferedRawText)
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
    }

    /// A new session starts with an empty dictation event. The running
    /// transcript and the latest segment carry over.
    package mutating func resetForNewSession() {
        livePartialText = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
    }
}
