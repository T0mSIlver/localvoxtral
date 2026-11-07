import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: Dictation note

    public func dictationNoteStatus(for agent: DictationNoteAgent) -> DictationNoteInstallService.Status {
        dictationNoteStatuses[agent] ?? .unknown
    }

    /// The row's one status sentence.
    public func dictationNoteSentence(for agent: DictationNoteAgent) -> String {
        dictationNoteResults[agent]
            ?? DictationNoteInstallService.sentence(for: dictationNoteStatus(for: agent))
    }

    /// Every agent at once: opencode reads `~/.claude/CLAUDE.md` while its own
    /// file is absent, so one row's action can change another's status.
    public func refreshDictationNoteStatuses() {
        for agent in DictationNoteAgent.allCases {
            dictationNoteStatuses[agent] = dictationNoteService(agent)?.status() ?? .unknown
        }
    }

    public func addDictationNote(for agent: DictationNoteAgent) async {
        await performDictationNoteAction(for: agent, failureTitle: "Could not add the dictation note",
                                         failureLine: "Could not add.") { try $0.add() }
    }

    public func removeDictationNote(for agent: DictationNoteAgent) async {
        await performDictationNoteAction(for: agent, failureTitle: "Could not remove the dictation note",
                                         failureLine: "Could not remove.") { try $0.remove() }
    }

    private func performDictationNoteAction(
        for agent: DictationNoteAgent,
        failureTitle: String,
        failureLine: String,
        _ action: @escaping @Sendable (DictationNoteInstallService) throws -> Void
    ) async {
        guard let service = dictationNoteService(agent), !isPerformingDictationNoteAction else { return }
        isPerformingDictationNoteAction = true
        dictationNoteResults = [:]
        defer { isPerformingDictationNoteAction = false }
        if let failure = await performAsync({ try action(service) }) {
            alert = DetailAlert(title: failureTitle, detail: failure.describedError)
            dictationNoteResults[agent] = failureLine
        }
        refreshDictationNoteStatuses()
    }
}
