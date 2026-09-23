import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: Status line

    /// The row's one status sentence.
    public var statuslineSentence: String {
        ClaudeStatuslineInstallService.sentence(for: statuslineStatus)
    }

    public func refreshStatuslineStatus() {
        guard let service = statuslineService() else {
            statuslineStatus = .unknown
            return
        }
        statuslineStatus = service.status(currentHookCommand: statuslineHookCommand())
    }

    /// Exact generated JSON retained for service tests. Settings never renders
    /// it.
    public var statuslinePreview: String? {
        guard let hookCommand = statuslineHookCommand() else { return nil }
        return ClaudeStatuslineInstallService.preview(hookCommand: hookCommand)
    }

    public var canApplyStatuslineSetup: Bool { statuslineHookCommand() != nil }

    /// What the row's setup button does for the current status: install or
    /// update our entry, combine with the user's own, or update the combined
    /// script.
    public func applyStatuslineSetup() async {
        guard
            let service = statuslineService(),
            let hookCommand = statuslineHookCommand(),
            !isPerformingStatuslineAction
        else { return }
        isPerformingStatuslineAction = true
        statuslineResult = nil
        defer { isPerformingStatuslineAction = false }
        let status = statuslineStatus
        let failure = await performAsync {
            switch status {
            case .foreign: try service.combine(hookCommand: hookCommand)
            case .combinedOutdated: try service.updateCombined(hookCommand: hookCommand)
            default: try service.apply(hookCommand: hookCommand)
            }
        }
        if let failure {
            alert = DetailAlert(
                title: status == .foreign
                    ? "Could not combine the status lines"
                    : "Could not install the status line",
                detail: failure.describedError
            )
            statuslineResult = status == .foreign ? "Could not combine." : "Could not install."
        } else {
            statuslineResult = status == .foreign ? "Combined." : "Installed."
        }
        refreshStatuslineStatus()
        // M3: an edited formerly-ours entry refuses with its own sentence —
        // the generic failure line would hide what to do next.
        if failure != nil, statuslineStatus == .edited {
            statuslineResult = ClaudeStatuslineInstallService.sentence(for: .edited)
        }
    }

    public func removeStatusline() async {
        guard let service = statuslineService(), !isPerformingStatuslineAction else { return }
        isPerformingStatuslineAction = true
        statuslineResult = nil
        defer { isPerformingStatuslineAction = false }
        let failure = await performAsync { try service.remove() }
        if let failure {
            alert = DetailAlert(
                title: "Could not remove the status line",
                detail: failure.describedError
            )
            statuslineResult = "Could not remove."
        } else {
            statuslineResult = "Removed."
        }
        refreshStatuslineStatus()
        if failure != nil, statuslineStatus == .edited {
            statuslineResult = ClaudeStatuslineInstallService.sentence(for: .edited)
        }
    }
}
