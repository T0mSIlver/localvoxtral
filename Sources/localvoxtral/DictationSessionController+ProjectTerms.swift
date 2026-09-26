import Foundation

/// Hands a committed, joined dictation to `ProjectTermProposer` (#609).
extension DictationSessionController {
    /// Called once the commit inserted its text. Returns at once: the
    /// proposer resolves the project and runs the agent in a detached task,
    /// so neither this commit nor the next dictation waits for it.
    func proposeProjectTermsIfNew(join: ClaudeSessionJoin?) {
        projectTermProposalTask = projectTermProposer?.dictationCommitted(
            join: join?.snapshot,
            enabled: settings.projectTermProposalsEnabled,
            excluding: settings.polishSpeakerTerms + settings.polishDismissedTermSuggestions
        )
    }
}
