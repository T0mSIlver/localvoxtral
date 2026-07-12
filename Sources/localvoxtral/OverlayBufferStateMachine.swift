import CoreGraphics
import Foundation
import os

struct OverlayAnchor: Equatable {
    enum Source: Equatable {
        case windowCenter
        case mouseLocation
    }

    var targetRect: CGRect
    var source: Source
}

enum OverlayBufferPhase: Equatable {
    case idle
    case buffering
    case finalizing
    case commitFailed
}

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
enum OverlayBufferTextAssembler {
    /// Returns the merged text suitable for **overlay display only**.
    /// Combines committed and pending text with tail-overlap deduplication.
    static func displayText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String
    ) -> String {
        mergedText(
            committedText: committedText,
            pendingText: pendingText,
            fallbackPendingText: fallbackPendingText,
            normalizeNewlinesForDisplay: true
        )
    }

    /// Returns the merged text used as the source for final commit insertion.
    static func commitText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String
    ) -> String {
        mergedText(
            committedText: committedText,
            pendingText: pendingText,
            fallbackPendingText: fallbackPendingText,
            normalizeNewlinesForDisplay: false
        )
    }

    private static func mergedText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String,
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
            incoming: mergedPending
        ).merged
    }

    /// Returns the trimmed buffer text suitable for **text insertion** into the focused app.
    static func insertionText(from bufferText: String) -> String {
        bufferText.trimmed
    }
}

// Valid state transitions:
//   idle → buffering         (startSession)
//   buffering → finalizing   (beginFinalizing)
//   finalizing → commitFailed (commitFailed)
//   any → idle               (reset)
@MainActor
struct OverlayBufferStateMachine {
    struct Snapshot: Equatable {
        let phase: OverlayBufferPhase
        let bufferText: String
        let errorMessage: String?
        let secureInputActive: Bool
        /// True once LLM polishing has changed the displayed text vs the raw
        /// transcript for this session. Drives the subtle "Polished" badge shown
        /// while the polished text is held before dismissal. Set only by the
        /// stop-commit polish path; cleared on every new session.
        let polished: Bool
        let anchor: OverlayAnchor
    }

    private(set) var phase: OverlayBufferPhase = .idle
    private(set) var bufferText = ""
    private(set) var errorMessage: String?
    private(set) var secureInputActive = false
    private(set) var polished = false
    private(set) var anchor: OverlayAnchor?

    var snapshot: Snapshot? {
        guard phase != .idle, let anchor else { return nil }
        return Snapshot(
            phase: phase,
            bufferText: bufferText,
            errorMessage: errorMessage,
            secureInputActive: secureInputActive,
            polished: polished,
            anchor: anchor
        )
    }

    mutating func startSession(anchor: OverlayAnchor) {
        guard phase == .idle else {
            let currentPhase = phase
            Log.overlay.warning("startSession called but phase is \(String(describing: currentPhase)), not idle — ignoring")
            return
        }
        phase = .buffering
        bufferText = ""
        errorMessage = nil
        secureInputActive = false
        polished = false
        self.anchor = anchor
    }

    /// Marks that LLM polishing changed the displayed text vs the raw
    /// transcript. Set from the stop-commit polish path once the polished text
    /// is on screen; the badge then rides the finalizing/hold snapshot. Ignored
    /// when idle (no session to annotate); a new session clears it.
    mutating func setPolished(_ value: Bool) {
        guard phase != .idle else { return }
        polished = value
    }

    /// Marks the buffering session as running under Secure Keyboard Entry.
    /// The overlay view folds this into the phase title (an actionable
    /// "select another field" hint) rather than a separate warning sentence —
    /// a warning line under the transcript read as clutter (owner feedback
    /// on #90). startSession resets it; it persists through finalizing so
    /// the marker doesn't blink away while the commit is still pending.
    mutating func setSecureInputWarning() {
        guard phase == .buffering else { return }
        secureInputActive = true
    }

    mutating func updateBuffer(text: String, anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        bufferText = text
        if let anchor {
            self.anchor = anchor
        }
    }

    mutating func beginFinalizing(anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        phase = .finalizing
        if let anchor {
            self.anchor = anchor
        }
    }

    mutating func commitFailed(error: String, anchor: OverlayAnchor?) {
        guard phase != .idle else { return }
        phase = .commitFailed
        errorMessage = error
        if let anchor {
            self.anchor = anchor
        }
    }

    mutating func reset() {
        phase = .idle
        bufferText = ""
        errorMessage = nil
        secureInputActive = false
        polished = false
        anchor = nil
    }
}
