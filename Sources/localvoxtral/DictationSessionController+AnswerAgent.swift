import ClaudeContextWire
import Foundation
import os

/// The answer shortcut (#717): brings forward the pane of the session that
/// needs you (the oldest wait, else the oldest finished turn) and starts a
/// dictation there, so you answer by voice. Pressed again during that
/// dictation, it stops it. The pane comes forward through the go-to
/// primitive (`SessionNavigator`), and the dictation starts only when the
/// terminal confirmed that pane is the focused one (`.focused`): an
/// unconfirmed focus could put your answer in another session.
extension DictationSessionController {
    enum AnswerAgentStatus {
        static let nobodyWaiting = "No agent needs you"
        static let unconfirmed = "Couldn't confirm that session's window"
    }

    func answerAgentThatNeedsYou() {
        if isDictating {
            stopDictation(reason: "answer shortcut")
            return
        }
        guard !isConnectingRealtimeSession, !isFinalizingStop else {
            statusText = isConnectingRealtimeSession
                ? StatusStrings.connectingRealtimeBackend
                : StatusStrings.finalizingPreviousDictation
            return
        }
        guard let attention = agentAttention, let navigator = sessionNavigator else {
            Log.dictation.error("answer shortcut: the needs-you queue is not installed; nothing done")
            return
        }
        guard let entry = attention.tracker.next() else {
            Log.dictation.notice("answer shortcut: no session needs you")
            statusText = AnswerAgentStatus.nobodyWaiting
            return
        }
        // Out of the queue whatever the focus comes to: the status line says
        // why when it fails, and the next press goes to the next session.
        attention.tracker.answered(sessionID: entry.sessionID)
        answerAgentTask?.cancel()
        answerAgentTask = Task { @MainActor [weak self] in
            let outcome = await navigator.focusPane(sessionID: entry.sessionID)
            guard let self, !Task.isCancelled else { return }
            Log.dictation.notice(
                "answer shortcut: \(entry.kind.rawValue, privacy: .public) session, \(outcome.map { String(describing: $0) } ?? "no longer live", privacy: .public)"
            )
            switch outcome {
            case .focused?:
                // A dictation started while the pane came forward keeps it.
                guard !self.isDictating, !self.isConnectingRealtimeSession, !self.isFinalizingStop else { return }
                self.startDictation(outputMode: nil)
            case .unverified?:
                self.statusText = AnswerAgentStatus.unconfirmed
            case .paneNotFound?, nil:
                self.statusText = GoToSessionStatus.paneNotFound
            case .unsupported?:
                self.statusText = GoToSessionStatus.unsupported
            }
        }
    }

    /// A dictation joined `sessionID`: you reached it, so it needs you no
    /// longer.
    func noteDictationJoinedAgentSession(_ sessionID: String?) {
        guard let sessionID else { return }
        agentAttention?.tracker.answered(sessionID: sessionID)
    }
}
