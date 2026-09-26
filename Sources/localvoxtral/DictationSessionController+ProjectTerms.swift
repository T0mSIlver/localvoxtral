import Foundation

/// Hands a committed, joined dictation to `ProjectTermProposer` (#609).
extension DictationSessionController {
    /// Called once the commit inserted `inserted`. Returns at once: the
    /// proposer resolves the project and runs the agent in a detached task,
    /// so neither this commit nor the next dictation waits for it. Nothing
    /// is asked for an empty commit, which an empty buffer reports as a
    /// success: an accidental tap must not spend a run, nor the project's
    /// one ask.
    func proposeProjectTermsIfNew(join: ClaudeSessionJoin?, inserted: String) {
        guard !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            projectTermProposalTask = nil
            return
        }
        projectTermProposalTask = projectTermProposer?.dictationCommitted(
            join: join?.snapshot,
            enabled: settings.projectTermProposalsEnabled,
            excluding: settings.polishSpeakerTerms + settings.polishDismissedTermSuggestions
        )
    }
}
