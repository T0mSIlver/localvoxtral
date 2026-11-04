import Foundation

extension DictationSessionController {
    /// A dictation joined `sessionID`: you reached it, so it needs you no
    /// longer.
    func noteDictationJoinedAgentSession(_ sessionID: String?) {
        guard let sessionID else { return }
        agentAttention?.tracker.answered(sessionID: sessionID)
    }
}
