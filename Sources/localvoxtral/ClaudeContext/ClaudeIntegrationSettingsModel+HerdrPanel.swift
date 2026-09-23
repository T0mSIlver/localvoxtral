import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    public func requestHerdrPanelConfiguration(hostID: String) {
        guard !isPerformingEnrollmentAction,
              let host = hosts.first(where: { $0.id == hostID }),
              host.sshHostAlias != nil
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .configureHerdrPanel(hostID: hostID),
            title: "Configure this exact herdr agents-panel row?",
            preview: ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet,
            confirmButtonTitle: "Confirm configuration"
        )
        Log.claudeContext.info("Claude remote herdr panel configuration confirmation requested")
    }

    public func requestLocalHerdrPanelConfiguration() {
        guard !isPerformingEnrollmentAction, hasEnabledHerdrMachine else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        localHerdrPanelResult = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .configureLocalHerdrPanel,
            title: ClaudeRemoteEnrollmentService.localHerdrPanelConsentTitle,
            preview: ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet,
            confirmButtonTitle: "Confirm configuration"
        )
        Log.claudeContext.info("Claude local herdr panel configuration confirmation requested")
    }

    func performHerdrPanelConfiguration(_ confirmation: EnrollmentConfirmation) async {
        guard case .configureHerdrPanel(let hostID) = confirmation.action,
              let host = hosts.first(where: { $0.id == hostID }),
              let alias = host.sshHostAlias
        else { return }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let attempt = await performEnrollmentAsync {
            try service.configureRemoteHerdrPanel(sshHostAlias: alias)
        }
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        publish(attempt, action: confirmation.action)
        if attempt.failure == nil { herdrPanelStatus = .ok }
    }

    func performLocalHerdrPanelConfiguration(_ confirmation: EnrollmentConfirmation) async {
        // Re-check the offer gate at perform time, not just at request time:
        // a machine disabled between consent and confirm must not be written
        // for. The report is live (production re-reads the catalog per call),
        // never the cached row value.
        guard case .configureLocalHerdrPanel = confirmation.action,
              hasEnabledHerdrMachineReport()
        else { return }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        localHerdrPanelResult = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let attempt = await performEnrollmentAsync {
            try service.configureLocalHerdrPanel()
        }
        publish(attempt, action: confirmation.action)
        if attempt.failure == nil {
            herdrPanelStatus = .ok
            localHerdrPanelResult = attempt.steps.first?.message
                ?? ClaudeRemoteEnrollmentService.localHerdrPanelReloadStatus
        }
        localHerdrPanelStatus = service.localHerdrPanelStatus()
    }
}
