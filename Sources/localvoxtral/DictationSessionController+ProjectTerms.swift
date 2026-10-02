import Foundation

/// Hands a committed, joined dictation to `ProjectTermProposer` (#609).
extension DictationSessionController {
    /// The project names every polish carries (#1024), from the learned
    /// terms' project list: with `join`, only its project's group's (#1005).
    /// Empty without a store.
    func polishProjectNames(join: ClaudeSessionJoin? = nil) -> [String] {
        guard let learnedTermStore else { return [] }
        let memory = learnedTermStore.snapshot()
        let group = memory.group(ofJoinedWorkspace: join?.snapshot.learnedTermWorkspace)
        return PolishProjectNames.names(from: memory.inGroup(group), now: Date())
    }

    /// The skill names every polish carries (#1024): this Mac's and every
    /// reporting host's.
    func polishSkillNames() -> [String] {
        agentSkillStore?.names() ?? []
    }

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
            excluding: settings.polishSpeakerTerms + settings.polishDismissedTermSuggestions + polishProjectNames() + polishSkillNames()
        )
    }
}
