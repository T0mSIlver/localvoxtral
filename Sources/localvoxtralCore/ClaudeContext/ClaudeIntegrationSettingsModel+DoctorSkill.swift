import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: Doctor skill

    public func doctorSkillStatus(for agent: DictationNoteAgent) -> AgentSkillInstallService.Status {
        doctorSkillStatuses[agent] ?? .unknown
    }

    /// The row's one status sentence.
    public func doctorSkillSentence(for agent: DictationNoteAgent) -> String {
        doctorSkillResults[agent]
            ?? AgentSkillInstallService.sentence(for: doctorSkillStatus(for: agent), agent: agent)
    }

    public func refreshDoctorSkillStatuses() {
        for agent in DictationNoteAgent.allCases {
            doctorSkillStatuses[agent] = doctorSkillService(agent)?.status() ?? .unknown
        }
    }

    public func addDoctorSkill(for agent: DictationNoteAgent) async {
        await performDoctorSkillAction(for: agent, failureTitle: "Could not add the doctor skill",
                                       failureLine: "Could not add.") { try $0.add() }
    }

    public func removeDoctorSkill(for agent: DictationNoteAgent) async {
        await performDoctorSkillAction(for: agent, failureTitle: "Could not remove the doctor skill",
                                       failureLine: "Could not remove.") { try $0.remove() }
    }

    private func performDoctorSkillAction(
        for agent: DictationNoteAgent,
        failureTitle: String,
        failureLine: String,
        _ action: @escaping @Sendable (AgentSkillInstallService) throws -> Void
    ) async {
        guard let service = doctorSkillService(agent), !isPerformingDoctorSkillAction else { return }
        isPerformingDoctorSkillAction = true
        doctorSkillResults = [:]
        defer { isPerformingDoctorSkillAction = false }
        if let failure = await performAsync({ try action(service) }) {
            alert = DetailAlert(title: failureTitle, detail: failure.describedError)
            doctorSkillResults[agent] = failureLine
        }
        refreshDoctorSkillStatuses()
    }
}
