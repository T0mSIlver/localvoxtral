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
        onFocus?(session.sessionID)
        return outcome
    }
}
