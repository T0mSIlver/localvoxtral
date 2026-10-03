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
        /// True once LLM polishing has changed the displayed text vs the raw
        /// transcript for this session. The header then says "Polished" and
        /// the words polish wrote are marked while the panel is held before
        /// dismissal (#1074). Set only by the stop-commit polish path; cleared
        /// on every new session.
        package let polished: Bool
        /// The text on screen just before the polished text replaced it,
        /// while `polished`: the view marks the words that differ.
        package var polishedFrom: String? = nil
        /// The polish request is out: the header says "Polishing" and a band
        /// sweeps the words until the reply lands (#1074).
        package var polishing = false
        /// What to say about this dictation's Claude Code session join. Set
        /// once, from the join resolved at session start; cleared on every new
        /// session. `.hidden` renders nothing at all.
        package let claudeJoin: OverlayClaudeJoinBadge
        /// Where the words go at stop (#840), nil when the overlay has no
        /// choice to offer. Replaced whenever Tab moves or the list changes.
        package var destinations: OverlayDestinationStrip? = nil
        /// The draft a review dictation acts on (#927), nil otherwise.
        package var draftReview: QuickCaptureDraftSnapshot? = nil
        package let anchor: OverlayAnchor

        package init(
            phase: OverlayBufferPhase,
            bufferText: String,
            errorMessage: String?,
            secureInputActive: Bool,
            polished: Bool,
            polishedFrom: String? = nil,
            polishing: Bool = false,
            claudeJoin: OverlayClaudeJoinBadge,
            destinations: OverlayDestinationStrip? = nil,
            draftReview: QuickCaptureDraftSnapshot? = nil,
            anchor: OverlayAnchor
        ) {
            self.phase = phase
            self.bufferText = bufferText
            self.errorMessage = errorMessage
            self.secureInputActive = secureInputActive
            self.polished = polished
            self.polishedFrom = polishedFrom
            self.polishing = polishing
            self.claudeJoin = claudeJoin
            self.destinations = destinations
            self.draftReview = draftReview
            self.anchor = anchor
        }
    }

    package init() {}

    package private(set) var phase: OverlayBufferPhase = .idle
    package private(set) var bufferText = ""
    package private(set) var errorMessage: String?
    package private(set) var secureInputActive = false
    package private(set) var polished = false
    package private(set) var polishedFrom: String?
    package private(set) var polishing = false
    package private(set) var claudeJoin: OverlayClaudeJoinBadge = .hidden
    package private(set) var destinations: OverlayDestinationStrip?
    package private(set) var draftReview: QuickCaptureDraftSnapshot?
    package private(set) var anchor: OverlayAnchor?

    package var snapshot: Snapshot? {
        guard phase != .idle, let anchor else { return nil }
        return Snapshot(
            phase: phase,
            bufferText: bufferText,
            errorMessage: errorMessage,
            secureInputActive: secureInputActive,
            polished: polished,
            polishedFrom: polishedFrom,
            polishing: polishing,
            claudeJoin: claudeJoin,
            destinations: destinations,
            draftReview: draftReview,
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
        polished = false
        polishedFrom = nil
        polishing = false
        // Assigned, never merely cleared: the previous dictation's join
        // describes the previous dictation's session, and a badge that survived
        // into this one would vouch for a grounding this session was not given.
        self.claudeJoin = claudeJoin
        destinations = nil
        draftReview = nil
        self.anchor = anchor
    }

    /// Shows where the words go. Only while the dictation runs: once it
    /// stops, the destination is decided.
    package mutating func setDestinations(_ strip: OverlayDestinationStrip?) {
        guard phase == .buffering else { return }
        destinations = strip
    }

    /// Shows the draft under review. Only while the dictation runs; it stays
    /// through finalizing, so the panel does not jump at the stop.
    package mutating func setDraftReview(_ draft: QuickCaptureDraftSnapshot?) {
        guard phase == .buffering else { return }
        draftReview = draft
    }

    /// Marks that LLM polishing changed the displayed text vs the raw
    /// transcript. Set from the stop-commit polish path just before the
    /// polished text reaches the buffer, so the buffer still holds what the
    /// user saw: that is what the marks compare against. The flag then rides
    /// the finalizing/hold snapshot. Ignored when idle (no session to
    /// annotate); a new session clears it.
    package mutating func setPolished(_ value: Bool) {
        guard phase != .idle else { return }
        polished = value
        polishedFrom = value ? bufferText : nil
        polishing = false
    }

    /// The polish request is out. Only while finalizing: a reply, a failure
    /// or a new session ends it.
    package mutating func setPolishing(_ value: Bool) {
        guard phase == .finalizing else { return }
        polishing = value
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
        polishing = false
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
        polished = false
        polishedFrom = nil
        polishing = false
        claudeJoin = .hidden
        destinations = nil
        anchor = nil
    }
}
