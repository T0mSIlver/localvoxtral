import Foundation

/// Hands a committed, joined dictation to `ProjectTermProposer` (#609).
extension DictationSessionController {
    /// The project names every polish carries (#1024), from the learned
    /// terms' project list: with `join`, only its project's group's (#1005).
    /// Empty without a store.
    func polishProjectNames(join: ClaudeSessionJoin? = nil) -> [String] {
        guard let learnedTermStore else { return [] }
        let memory = learnedTermStore.snapshot()
        return PolishProjectNames.names(from: memory.inGroup(memory.group(ofJoin: join)), now: Date())
    }

    /// Looks up the joined local session's git root and its repository's
    /// main checkout, and keeps them on the join (#1155). A session in a
    /// linked worktree outside its main checkout sits under no recorded
    /// checkout, so only the main checkout finds its project group, and the
    /// commit path must not touch the disk to get it. Runs at start, beside
    /// the dictation, through the second pass's bounded lookup; only when a
    /// project has a group and the session's directory alone finds none.
    /// Nothing it finds is sent anywhere: it only narrows what is read.
    func lookUpJoinedRepositoryRoot() async {
        guard let join = context.claudeSessionJoin, let workspace = join.localWorkspacePath,
            let memory = learnedTermStore?.snapshot(), memory.hasGroups,
            memory.group(ofJoin: join) == nil
        else { return }
        let root = await repoVocabularyGrounding.repositoryRoot(
            joinedWorkspace: workspace, sleep: dependencies.clock.sleep)
        // A later dictation may hold another join by now.
        guard !Task.isCancelled, context.claudeSessionJoin == join else { return }
        context.claudeSessionJoin?.repositoryRoot = root
        Log.backends.info("joined session git root: \(Self.describe(root), privacy: .public)")
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
