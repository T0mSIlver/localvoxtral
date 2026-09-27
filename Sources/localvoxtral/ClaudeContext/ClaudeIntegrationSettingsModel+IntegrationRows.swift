import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Integrations rows

    /// Re-read every Integrations row that comes from disk or a probe. Called
    /// with the rest of the pane's refresh and after every row action.
    public func refreshIntegrationsStatuses() async {
        let output = await fetchPluginListOutput()
        localPluginStatus = ClaudePluginStatus.derive(
            listOutput: output, bundledVersion: bundledPluginVersion
        )
        refreshStatuslineStatus()
        refreshOpencodeStatus()
        refreshVibeStatus()
        refreshDictationNoteStatuses()
        await refreshCodexStatus()
        isHerdrDetected = herdrBinaryAvailable() || herdrPresenceReport()
        hasEnabledHerdrMachine = hasEnabledHerdrMachineReport()
        localHerdrPanelStatus = enrollmentService.localHerdrPanelStatus()
        refreshHerdrPaneHostLabels()
    }

    /// The panel row's one line: the last action's outcome while the config
    /// still holds the row, else what the config holds. Nil when there is
    /// nothing to say before Set up….
    public var localHerdrPanelSentence: String? {
        if let localHerdrPanelResult, localHerdrPanelStatus == .added {
            return localHerdrPanelResult
        }
        switch localHerdrPanelStatus {
        case .notAdded: return nil
        case .added: return "Added."
        case .customized: return "Your herdr config sets its own agents rows."
        case .unknown: return "Could not read your herdr config."
        }
    }

    /// Set up… is offered only where it would write: never over the row
    /// already there, over agents rows the user wrote, or over a config it
    /// cannot read (it refuses all three).
    public var offersLocalHerdrPanelSetup: Bool {
        localHerdrPanelStatus == .notAdded
    }

    /// Maps the reporting host ids onto enrolled-host labels. An id with no
    /// enrolled row (a host removed while its sessions were still live) is
    /// dropped, not guessed from the id.
    private func refreshHerdrPaneHostLabels() {
        let reporting = Set(herdrPaneReportingHostIDs())
        herdrPaneHostLabels = hosts
            .filter { reporting.contains($0.id) }
            .map(\.label)
    }

    // MARK: Local plugin status

    /// The plugin row's one status sentence.
    public var localPluginSentence: String { localPluginStatus.sentence }
}
