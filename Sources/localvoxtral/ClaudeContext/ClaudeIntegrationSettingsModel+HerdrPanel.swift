import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    public func requestLocalHerdrPanelConfiguration() {
        guard !isPerformingEnrollmentAction, hasEnabledHerdrMachine else { return }
        localHerdrPanelResult = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .configureLocalHerdrPanel,
            title: ClaudeRemoteEnrollmentService.localHerdrPanelConsentTitle,
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
        localHerdrPanelResult = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let attempt = await performEnrollmentAsync {
            try service.configureLocalHerdrPanel()
        }
        if let failure = attempt.failure {
            alert = DetailAlert(
                title: "Local herdr panel",
                detail: Self.enrollmentFailureDetail(failure, subject: "Local herdr panel setup")
            )
            Log.claudeContext.error(
                "Claude local herdr panel configuration failed: \(failure.describedError, privacy: .public)"
            )
        } else {
            localHerdrPanelResult = attempt.steps.first?.message
                ?? ClaudeRemoteEnrollmentService.localHerdrPanelReloadStatus
        }
        localHerdrPanelStatus = service.localHerdrPanelStatus()
    }
}
