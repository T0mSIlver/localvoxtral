import Foundation

/// Assembles text for the overlay buffer display and insertion.
///
/// There are two distinct text representations:
/// - **Display text** (`displayText`): Merged view of committed + pending text shown
///   in the overlay panel. Uses tail-overlap merging and newline flattening to keep
///   panel rendering stable.
/// - **Commit text** (`commitText`): Merged view of committed + pending text used as
///   the insertion source for final commit. Preserves newline structure.
/// - **Insertion text** (`insertionText`): Final edge-trim pass applied right before
///   text insertion into the focused app.
package enum OverlayBufferTextAssembler {
    /// Returns the merged text suitable for **overlay display only**.
    /// Combines committed and pending text with tail-overlap deduplication.
    package static func displayText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String,
        pendingStartsMidWord: Bool = false
    ) -> String {
        mergedText(
            committedText: committedText,
            pendingText: pendingText,
            fallbackPendingText: fallbackPendingText,
            pendingStartsMidWord: pendingStartsMidWord,
            normalizeNewlinesForDisplay: true
        )
    }

    /// Returns the merged text used as the source for final commit insertion.
    package static func commitText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String,
        pendingStartsMidWord: Bool = false
    ) -> String {
        mergedText(
            committedText: committedText,
            pendingText: pendingText,
            fallbackPendingText: fallbackPendingText,
            pendingStartsMidWord: pendingStartsMidWord,
            normalizeNewlinesForDisplay: false
        )
    }

    private static func mergedText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String,
        pendingStartsMidWord: Bool,
        normalizeNewlinesForDisplay: Bool
    ) -> String {
        let pendingCandidate = pendingText.trimmed.isEmpty ? fallbackPendingText : pendingText
        let mergedCommitted = normalizeNewlinesForDisplay
            ? committedText.replacingOccurrences(of: "\n", with: " ")
            : committedText
        let mergedPending = normalizeNewlinesForDisplay
            ? pendingCandidate.replacingOccurrences(of: "\n", with: " ")
            : pendingCandidate

        guard !mergedPending.trimmed.isEmpty else {
            return mergedCommitted
        }
        guard !mergedCommitted.trimmed.isEmpty else {
            return mergedPending
        }

        return TextMergingAlgorithms.appendWithTailOverlap(
            existing: mergedCommitted,
            incoming: mergedPending,
            incomingStartsMidWord: pendingStartsMidWord
        ).merged
    }

    /// Returns the trimmed buffer text suitable for **text insertion** into the focused app.
    package static func insertionText(from bufferText: String) -> String {
        bufferText.trimmed
    }
}
