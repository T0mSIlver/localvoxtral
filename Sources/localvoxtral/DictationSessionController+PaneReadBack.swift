import ClaudeContextWire
import Foundation
import os

/// The read-back before keys carry a commit into a joined session's pane.
extension DictationSessionController {
    /// Asked by a commit task after an await (the polish, the second pass),
    /// right before it inserts: two tabs of one terminal share its pid, so
    /// a tab switch while the task waited would take the words (#1056).
    /// `joined` is the session the dictation joined when keys will carry
    /// the commit; its pane is read back when it can be (#1668). True when
    /// there is nothing to read back or the focused pane still shows the
    /// session. Otherwise the text is saved as not inserted, the stop
    /// finishes, and the caller inserts nothing; a joined session's text
    /// also goes on the clipboard, as an overlay commit the keys could not
    /// make does. A cancelled task returns false and changes nothing.
    func commitPaneStillShownBeforeInsertion(
        sessionMode: DictationOutputMode, joined: ClaudeSessionJoin? = nil
    ) async -> Bool {
        guard let pane = joinedPaneToReadBack(joined) else { return true }
        var shows = false
        if let navigator = sessionNavigator {
            shows = await navigator.focusedPaneShows(sessionID: pane.sessionID, bundleID: pane.bundleID)
        }
        guard !Task.isCancelled else { return false }
        guard !shows else { return true }
        Log.dictation.notice("overlay commit: the joined session's pane left the front while the commit waited; nothing typed")
        let saveNotInserted = saveInterruptedPolishCommit
        saveInterruptedPolishCommit = nil
        saveNotInserted?()
        let text = transcript.currentDictationEventText
        overlayBufferCoordinator.reset()
        completeStoppedSessionCleanup(sessionMode: sessionMode, overlayCommitOutcome: nil, shouldCommitOverlay: true)
        if !text.isEmpty {
            statusText = copyUntypedText(text)
        }
        return false
    }

    /// The joined session's pane, when the commit types into its app and
    /// the pane can be read back (a terminal tab, a herdr pane, a Claude
    /// Desktop session). Nil otherwise: a plain ssh or cmux session, or no
    /// join, keeps the pid check alone, as the Live spoken send does.
    private func joinedPaneToReadBack(_ join: ClaudeSessionJoin?) -> (sessionID: String, bundleID: String)? {
        guard let join, sessionNavigator != nil,
              overlayBufferCoordinator.commitTargetAppPID == join.target.pid
        else { return nil }
        if case .unsupported = SessionPaneFocusRoute.of(join.snapshot) { return nil }
        return (join.snapshot.sessionID, join.target.bundleID)
    }
}
