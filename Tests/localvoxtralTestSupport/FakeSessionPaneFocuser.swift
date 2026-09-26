import ClaudeContextWire
import Foundation
import localvoxtralCore

/// Records the sessions it was asked to bring forward and answers with
/// `outcome`.
@MainActor
package final class FakeSessionPaneFocuser: SessionPaneFocusing {
    package var outcome: SessionPaneFocusOutcome
    package private(set) var focusedSessionIDs: [String] = []

    package init(outcome: SessionPaneFocusOutcome = .focused(bundleID: "com.mitchellh.ghostty")) {
        self.outcome = outcome
    }

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        focusedSessionIDs.append(session.sessionID)
        return outcome
    }
}
