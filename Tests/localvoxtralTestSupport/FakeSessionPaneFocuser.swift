import ClaudeContextWire
import Foundation
import localvoxtralCore

/// Records the sessions it was asked to bring forward and answers with
/// `outcome`. `onFocus` runs as the pane comes forward, so a test can move
/// what it reads as frontmost.
@MainActor
package final class FakeSessionPaneFocuser: SessionPaneFocusing {
    package var outcome: SessionPaneFocusOutcome
    package private(set) var focusedSessionIDs: [String] = []
    package var onFocus: ((String) -> Void)?

    package init(outcome: SessionPaneFocusOutcome = .focused(bundleID: "com.mitchellh.ghostty")) {
        self.outcome = outcome
    }

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        focusedSessionIDs.append(session.sessionID)
        if holdsFocus {
            await withCheckedContinuation { heldFocuses.append($0) }
        }
        onFocus?(session.sessionID)
        return outcome
    }

    /// While true, `focusPane` waits for `releaseHeldFocuses()`, as a
    /// terminal slow to answer would.
    package var holdsFocus = false
    private var heldFocuses: [CheckedContinuation<Void, Never>] = [] {
        didSet { resumeHoldWaiters() }
    }
    private var holdWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Returns once `count` focuses are held.
    package func waitUntilHeld(_ count: Int) async {
        guard heldFocuses.count < count else { return }
        await withCheckedContinuation { holdWaiters.append((count, $0)) }
    }

    package func releaseHeldFocuses() {
        let held = heldFocuses
        heldFocuses = []
        held.forEach { $0.resume() }
    }

    private func resumeHoldWaiters() {
        let ready = holdWaiters.filter { $0.count <= heldFocuses.count }
        holdWaiters.removeAll { $0.count <= heldFocuses.count }
        ready.forEach { $0.continuation.resume() }
    }

    /// The answer to the read-back before a Return; `onReadBack` runs first.
    package var paneStillShowsSession = true
    package private(set) var readBackSessionIDs: [String] = []
    package var onReadBack: (@MainActor (String) -> Void)?

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID _: String) async -> Bool {
        readBackSessionIDs.append(session.sessionID)
        onReadBack?(session.sessionID)
        return paneStillShowsSession
    }
}
