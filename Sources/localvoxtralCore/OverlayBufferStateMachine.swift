import Foundation
#if canImport(os)
import os
#endif

package struct OverlayAnchor: Equatable {
    package enum Source: Equatable {
        case windowCenter
        case mouseLocation
    }

    package var targetRect: CGRect
    package var source: Source

    package init(targetRect: CGRect, source: Source) {
        self.targetRect = targetRect
        self.source = source
    }
}

package enum OverlayBufferPhase: Equatable {
    case idle
    case buffering
    case finalizing
    case commitFailed
}

/// What LLM polish has done to the overlay's words this session (#1074).
/// Polish runs once per stop, while finalizing:
///
///     none ─▶ polishing ─▶ polished(from:)   (the reply changed the words)
///                 │
///                 └─▶ none                    (unchanged, failed or not sent)
package enum OverlayPolishState: Equatable, Sendable {
    case none
    /// The request is out: the header says "Polishing" and a band sweeps
    /// the words until the reply lands.
    case polishing
    /// The reply changed the words. `from` is the text on screen just
    /// before: the view marks the words that differ, and the header says
    /// "Polished" while the panel is held before dismissal.
    case polished(from: String)
}

// Valid state transitions:
//   idle → buffering         (startSession)
//   buffering → finalizing   (beginFinalizing)
//   finalizing → commitFailed (commitFailed)
//   any → idle               (reset)
@MainActor
package struct OverlayBufferStateMachine {
    package struct Snapshot: Equatable {
        package let phase: OverlayBufferPhase
        package let bufferText: String
        package let errorMessage: String?
        package let secureInputActive: Bool
        /// Set only by the stop-commit polish path; cleared on every new session.
        package var polish: OverlayPolishState = .none
        /// The stop's second pass missed its deadline: the header says so
        /// while the realtime text commits (#1867).
        package var secondPassMissed = false
        /// What to say about this dictation's Claude Code session join. Set
        /// once, from the join resolved at session start; cleared on every new
        /// session. `.hidden` renders nothing at all.
        package let claudeJoin: OverlayClaudeJoinBadge
        package let anchor: OverlayAnchor

        package init(
            phase: OverlayBufferPhase,
            bufferText: String,
            errorMessage: String?,
            secureInputActive: Bool,
            polish: OverlayPolishState = .none,
            secondPassMissed: Bool = false,
            claudeJoin: OverlayClaudeJoinBadge,
            anchor: OverlayAnchor
        ) {
            self.phase = phase
            self.bufferText = bufferText
            self.errorMessage = errorMessage
            self.secureInputActive = secureInputActive
            self.polish = polish
            self.secondPassMissed = secondPassMissed
            self.claudeJoin = claudeJoin
            self.anchor = anchor
        }

        package var polished: Bool { polish.isPolished }
        package var polishedFrom: String? { polish.polishedFrom }
        package var polishing: Bool { polish == .polishing }
    }

    package init() {}

    package private(set) var phase: OverlayBufferPhase = .idle
    package private(set) var bufferText = ""
    package private(set) var errorMessage: String?
    package private(set) var secureInputActive = false
    package private(set) var polish: OverlayPolishState = .none
    package var polished: Bool { polish.isPolished }
    package private(set) var secondPassMissed = false
    package private(set) var claudeJoin: OverlayClaudeJoinBadge = .hidden
    package private(set) var anchor: OverlayAnchor?

    package var snapshot: Snapshot? {
        guard phase != .idle, let anchor else { return nil }
        return Snapshot(
            phase: phase,
            bufferText: bufferText,
            errorMessage: errorMessage,
            secureInputActive: secureInputActive,
            polish: polish,
            secondPassMissed: secondPassMissed,
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
    package mutating func startSession(anchor: OverlayAnchor, claudeJoin: OverlayClaudeJoinBadge) {
        guard phase == .idle else {
            let currentPhase = phase
            Log.overlay.warning("startSession called but phase is \(String(describing: currentPhase)), not idle — ignoring")
            return
        }
        phase = .buffering
        bufferText = ""
        errorMessage = nil
        secureInputActive = false
        polish = .none
        secondPassMissed = false
        // Assigned, never merely cleared: the previous dictation's join
        // describes the previous dictation's session, and a badge that survived
        // into this one would vouch for a grounding this session was not given.
        self.claudeJoin = claudeJoin
        self.anchor = anchor
    }

    /// Marks that LLM polishing changed the displayed text vs the raw
    /// transcript. Set from the stop-commit polish path just before the
    /// polished text reaches the buffer, so the buffer still holds what the
    /// user saw: that is what the marks compare against. The flag then rides
    /// the finalizing/hold snapshot. Ignored when idle (no session to
    /// annotate); a new session clears it.
    package mutating func setPolished(_ value: Bool) {
        guard phase != .idle else { return }
        polish = value ? .polished(from: bufferText) : .none
    }

    /// The polish request is out. Only while finalizing: a reply, a failure
    /// or a new session ends it. Polish runs once per stop, so a request
    /// after a reply changed the words is refused and logged as a fault.
    package mutating func setPolishing(_ value: Bool) {
        guard phase == .finalizing else { return }
        switch (polish, value) {
        case (.polished, true):
            Log.overlay.fault("setPolishing(true) after polish changed the words; ignored")
        case (_, true):
            polish = .polishing
        case (.polishing, false):
            polish = .none
        case (_, false):
            break
        }
    }

    /// The stop's second pass missed its deadline. Only while finalizing:
    /// the realtime text is about to commit.
    package mutating func setSecondPassMissed() {
        guard phase == .finalizing else { return }
        secondPassMissed = true
    }

    /// Marks the buffering session as running under Secure Keyboard Entry.
    /// The overlay view folds this into the phase title (an actionable
    /// "select another field" hint) rather than a separate warning sentence —
    /// a warning line under the transcript read as clutter (owner feedback
    /// on #90). startSession resets it; it persists through finalizing so
    /// the marker doesn't blink away while the commit is still pending.
    package mutating func setSecureInputWarning() {
        guard phase == .buffering else { return }
        secureInputActive = true
    }

    package mutating func updateBuffer(text: String, anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        bufferText = text
        if let anchor {
            self.anchor = anchor
        }
    }

    package mutating func beginFinalizing(anchor: OverlayAnchor?) {
        guard phase == .buffering || phase == .finalizing else { return }
        phase = .finalizing
        if let anchor {
            self.anchor = anchor
        }
    }

    package mutating func commitFailed(error: String, anchor: OverlayAnchor?) {
        guard phase != .idle else { return }
        phase = .commitFailed
        // The sweep ends; a polish that landed stays, as the words on screen are its.
        if polish == .polishing { polish = .none }
        errorMessage = error
        if let anchor {
            self.anchor = anchor
        }
    }

    package mutating func reset() {
        phase = .idle
        bufferText = ""
        errorMessage = nil
        secureInputActive = false
        polish = .none
        secondPassMissed = false
        claudeJoin = .hidden
        anchor = nil
    }
}

extension OverlayPolishState {
    package var isPolished: Bool {
        if case .polished = self { true } else { false }
    }

    package var polishedFrom: String? {
        if case .polished(let from) = self { from } else { nil }
    }
}
