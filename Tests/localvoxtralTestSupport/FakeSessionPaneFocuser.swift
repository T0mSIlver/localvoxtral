import ClaudeContextWire
import Foundation
import localvoxtralCore

/// Answers the read-back before a Return into a joined session's pane.
/// `onReadBack` runs first, so a test can move what it reads as frontmost;
/// `holdReadBack` keeps the read-back pending until the test lets it go.
@MainActor
package final class FakeSessionPaneFocuser: SessionPaneFocusing {
    package init() {}

    /// The answer to the read-back before a Return; `onReadBack` runs first.
    package var paneStillShowsSession = true
    package private(set) var readBackSessionIDs: [String] = []
    package var onReadBack: (@MainActor (String) -> Void)?
    package var holdReadBack: (@MainActor () async -> Void)?

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID _: String) async -> Bool {
        readBackSessionIDs.append(session.sessionID)
        onReadBack?(session.sessionID)
        await holdReadBack?()
        return paneStillShowsSession
    }
}
