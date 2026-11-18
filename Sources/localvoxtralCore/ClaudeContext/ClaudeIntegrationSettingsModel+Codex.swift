import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: Codex plugin

    /// The row's one status sentence.
    public var codexSentence: String {
        codexStatus.sentence(hookHeard: codexHookHeard)
    }

    /// Off the main actor: `codex plugin list` shells out.
    public func refreshCodexStatus() async {
        codexHookHeard = codexHookMemory?.hasHeard() ?? false
        guard let service = codexService() else {
            codexStatus = .unknown
            return
        }
        let bundledVersion = codexBundledVersion
        codexStatus = await Task.detached(priority: .userInitiated) {
            service.status(bundledVersion: bundledVersion)
        }.value
    }

    public func installCodexPlugin() async {
        await performCodexAction(
            failureTitle: "Could not install the Codex plugin",
            failure: "Could not install."
        ) { try $0.install() }
    }

    public func removeCodexPlugin() async {
        await performCodexAction(
            failureTitle: "Could not remove the Codex plugin",
            failure: "Could not remove."
        ) { try $0.remove() }
    }

    /// Both actions change what Codex runs, so a hook heard before them
    /// proves nothing afterwards. A success leaves the status sentence in
    /// place: after an install it is the one that says what is left to do.
    private func performCodexAction(
        failureTitle: String,
        failure: String,
        _ body: @escaping @Sendable (CodexPluginInstallService) throws -> Void
    ) async {
        guard let service = codexService(), !isPerformingCodexAction else { return }
        isPerformingCodexAction = true
        codexResult = nil
        defer { isPerformingCodexAction = false }
        let error = await performAsync { try body(service) }
        codexHookMemory?.reset()
        if let error {
            alert = DetailAlert(title: failureTitle, detail: error.describedError)
            codexResult = failure
        }
        await refreshCodexStatus()
    }
}
