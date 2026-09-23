import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: opencode plugin

    /// The row's one status sentence.
    public var opencodeSentence: String {
        OpencodePluginInstallService.sentence(for: opencodeStatus)
    }

    public func refreshOpencodeStatus() {
        guard let service = opencodeService() else {
            opencodeStatus = .unknown
            return
        }
        opencodeStatus = service.status()
    }

    public func installOpencodePlugin() async {
        guard let service = opencodeService(), !isPerformingOpencodeAction else { return }
        isPerformingOpencodeAction = true
        opencodeResult = nil
        defer { isPerformingOpencodeAction = false }
        let failure = await performAsync { try service.install() }
        if let failure {
            alert = DetailAlert(
                title: "Could not install the opencode plugin",
                detail: failure.describedError
            )
            opencodeResult = "Could not install."
        } else {
            opencodeResult = "Installed."
        }
        refreshOpencodeStatus()
    }

    public func removeOpencodePlugin() async {
        guard let service = opencodeService(), !isPerformingOpencodeAction else { return }
        isPerformingOpencodeAction = true
        opencodeResult = nil
        defer { isPerformingOpencodeAction = false }
        let failure = await performAsync { try service.remove() }
        if let failure {
            alert = DetailAlert(
                title: "Could not remove the opencode plugin",
                detail: failure.describedError
            )
            opencodeResult = "Could not remove."
        } else {
            opencodeResult = "Removed."
        }
        refreshOpencodeStatus()
    }
}
