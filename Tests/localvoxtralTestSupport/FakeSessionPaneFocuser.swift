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
    /// Sessions whose focus was cancelled by the time `onFocus` returned:
    /// a real focuser activates no terminal for those.
    package private(set) var cancelledSessionIDs: [String] = []

    package init(outcome: SessionPaneFocusOutcome = .focused(bundleID: "com.mitchellh.ghostty")) {
        self.outcome = outcome
    }

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        focusedSessionIDs.append(session.sessionID)
        onFocus?(session.sessionID)
        if Task.isCancelled { cancelledSessionIDs.append(session.sessionID) }
        return outcome
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
