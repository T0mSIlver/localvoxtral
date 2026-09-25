import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
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
