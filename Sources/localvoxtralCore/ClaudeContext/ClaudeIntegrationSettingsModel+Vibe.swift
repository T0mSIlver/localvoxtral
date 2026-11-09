import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: Mistral Vibe hooks

    /// The row's one status sentence.
    public var vibeSentence: String {
        VibeHooksInstallService.sentence(for: vibeStatus)
    }

    public func refreshVibeStatus() {
        guard let service = vibeService() else {
            vibeStatus = .unknown
            return
        }
        vibeStatus = service.status()
    }

    public func installVibeHooks() async {
        guard let service = vibeService(), !isPerformingVibeAction else { return }
        isPerformingVibeAction = true
        vibeResult = nil
        defer { isPerformingVibeAction = false }
        let failure = await performAsync { try service.install() }
        if let failure {
            alert = DetailAlert(
                title: "Could not install the Mistral Vibe hooks",
                detail: failure.describedError
            )
            vibeResult = "Could not install."
        } else {
            vibeResult = "Installed."
        }
        refreshVibeStatus()
    }

    public func removeVibeHooks() async {
        guard let service = vibeService(), !isPerformingVibeAction else { return }
        isPerformingVibeAction = true
        vibeResult = nil
        defer { isPerformingVibeAction = false }
        let failure = await performAsync { try service.remove() }
        if let failure {
            alert = DetailAlert(
                title: "Could not remove the Mistral Vibe hooks",
                detail: failure.describedError
            )
            vibeResult = "Could not remove."
        } else {
            vibeResult = "Removed."
        }
        refreshVibeStatus()
    }
}
