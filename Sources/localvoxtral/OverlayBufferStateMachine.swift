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
        /// What to say about this dictation's Claude Code session join. Set
        /// once, from the join resolved at session start; cleared on every new
        /// session. `.hidden` renders nothing at all.
        let claudeJoin: OverlayClaudeJoinBadge
        let anchor: OverlayAnchor
    }

    private(set) var phase: OverlayBufferPhase = .idle
    private(set) var bufferText = ""
    private(set) var errorMessage: String?
    private(set) var secureInputActive = false
    private(set) var polished = false
    private(set) var claudeJoin: OverlayClaudeJoinBadge = .hidden
    private(set) var anchor: OverlayAnchor?

    var snapshot: Snapshot? {
        guard phase != .idle, let anchor else { return nil }
        return Snapshot(
            phase: phase,
            bufferText: bufferText,
            errorMessage: errorMessage,
            secureInputActive: secureInputActive,
            polished: polished,
            claudeJoin: claudeJoin,
            anchor: anchor
        )
    }

    /// Starts a session, taking the Claude join badge WITH the anchor rather
    /// than through a follow-up setter.
    ///
    /// The join is resolved before the realtime socket connects and this call
    /// happens after it, so the badge is always already known here — unlike
    /// `polished`, which genuinely arrives later, at commit. Passing it in is
    /// what makes the ordering unbreakable: a separate setter had to run AFTER
    /// this method (which resets the session) to survive, and nothing in the
    /// type system said so.
    mutating func startSession(anchor: OverlayAnchor, claudeJoin: OverlayClaudeJoinBadge) {
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
        // Assigned, never merely cleared: the previous dictation's join
        // describes the previous dictation's session, and a badge that survived
        // into this one would vouch for a grounding this session was not given.
        self.claudeJoin = claudeJoin
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
        claudeJoin = .hidden
        anchor = nil
    }
}
