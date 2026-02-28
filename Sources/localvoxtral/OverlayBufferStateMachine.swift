import CoreGraphics
import Foundation
import os

struct OverlayAnchor: Equatable {
    enum Source: Equatable {
        case focusedWindow
        case cursor
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
///   in the overlay panel. Uses tail-overlap merging to avoid visual duplication.
/// - **Insertion text** (`insertionText`): The trimmed buffer text used for final
///   text insertion into the focused app. No merging — just the raw buffer content.
struct OverlayBufferTextAssembler {
    /// Returns the merged text suitable for **overlay display only**.
    /// Combines committed and pending text with tail-overlap deduplication.
    static func displayText(
        committedText: String,
        pendingText: String,
        fallbackPendingText: String
    ) -> String {
        let normalizedCommitted = committedText.replacingOccurrences(of: "\n", with: " ")
        let pendingCandidate = pendingText.trimmed.isEmpty ? fallbackPendingText : pendingText
        let normalizedPending = pendingCandidate.replacingOccurrences(of: "\n", with: " ")

        guard !normalizedPending.trimmed.isEmpty else {
            return normalizedCommitted
        }
        guard !normalizedCommitted.trimmed.isEmpty else {
            return normalizedPending
        }

        return TextMergingAlgorithms.appendWithTailOverlap(
            existing: normalizedCommitted,
            incoming: normalizedPending
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
//   finalizing → idle        (commitSucceeded)
//   finalizing → commitFailed (commitFailed)
//   buffering/finalizing → idle (reset)
//   commitFailed → idle      (reset)
//   any → idle               (reset)
@MainActor
struct OverlayBufferStateMachine {
    struct Snapshot: Equatable {
        let phase: OverlayBufferPhase
        let bufferText: String
        let errorMessage: String?
        let anchor: OverlayAnchor
    }

    private(set) var phase: OverlayBufferPhase = .idle
    private(set) var bufferText = ""
    private(set) var errorMessage: String?
    private(set) var anchor: OverlayAnchor?

    var snapshot: Snapshot? {
        guard phase != .idle, let anchor else { return nil }
        return Snapshot(
            phase: phase,
            bufferText: bufferText,
            errorMessage: errorMessage,
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
        self.anchor = anchor
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

    mutating func commitSucceeded() {
        guard phase == .finalizing else {
            let currentPhase = phase
            Log.overlay.warning("commitSucceeded called but phase is \(String(describing: currentPhase)), not finalizing — ignoring")
            return
        }
        reset()
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
        anchor = nil
    }
}
