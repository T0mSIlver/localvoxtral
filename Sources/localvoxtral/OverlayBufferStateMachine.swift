import CoreGraphics
import Foundation

struct OverlayAnchor: Equatable {
    enum Source: Equatable {
        case focusedInput
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

struct OverlayBufferTextAssembler {
    static func mergedBufferText(
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

    static func commitText(from bufferText: String) -> String {
        bufferText.trimmed
    }
}

@MainActor
final class OverlayBufferStateMachine {
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

    func startSession(anchor: OverlayAnchor) {
        phase = .buffering
        bufferText = ""
        errorMessage = nil
        self.anchor = anchor
    }

    func updateBuffer(text: String, anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        bufferText = text
        if let anchor {
            self.anchor = anchor
        }
    }

    func beginFinalizing(anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        phase = .finalizing
        if let anchor {
            self.anchor = anchor
        }
    }

    func commitSucceeded() {
        reset()
    }

    func commitFailed(error: String, anchor: OverlayAnchor?) {
        guard phase != .idle else { return }
        phase = .commitFailed
        errorMessage = error
        if let anchor {
            self.anchor = anchor
        }
    }

    func reset() {
        phase = .idle
        bufferText = ""
        errorMessage = nil
        anchor = nil
    }
}
