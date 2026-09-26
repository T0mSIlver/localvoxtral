import Foundation

extension ClaudeRemoteEnrollmentService {
    // MARK: Local herdr agents-panel configuration (federated 0.9 clients)

    /// The consent sentence for the local panel-row offer. Names the file the
    /// way the remote one names the channel: one sentence, no commands, no
    /// config text (owner rule).
    public static let localHerdrPanelConsentTitle =
        "Add this exact herdr agents-panel row to this Mac's herdr config?"

    /// One-line status for the row: the app appends the row but cannot reload
    /// herdr's config itself (the binary's location is not something a GUI app
    /// can resolve reliably), so the user must apply it in herdr. That
    /// residual is stated in `docs/agent/remote-herdr-panel-binding.md`.
    public static let localHerdrPanelReloadStatus =
        "Added. Reload config in herdr to apply it."

    /// Whether a herdr config's contents already carry an agents
    /// configuration. The SAME conservative rule the remote patch refuses on,
    /// ported line-for-line from the remote script's grep: an
    /// `[ui.sidebar.agents]` table header (optionally followed by a comment)
    /// or a `rows =` key at any indent.
    public static func localHerdrPanelConfigIsCustomized(_ content: String) -> Bool {
        content.split(whereSeparator: \.isNewline).contains { line in
            let trimmedHeader = line.trimmingCharacters(in: .whitespaces)
            if trimmedHeader.hasPrefix("[ui.sidebar.agents]") {
                let after = trimmedHeader.dropFirst("[ui.sidebar.agents]".count)
                    .trimmingCharacters(in: .whitespaces)
                return after.isEmpty || after.hasPrefix("#")
            }
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == "=" })
            guard fields.count == 2 else { return false }
            return fields[0].trimmingCharacters(in: .whitespaces) == "rows"
        }
    }

    /// What `configureLocalHerdrPanel` would find in this Mac's herdr config.
    public enum LocalHerdrPanelStatus: Sendable, Equatable {
        /// No agents table and no `rows` key: Set up… appends the row.
        case notAdded
        /// The row block is there exactly as Set up… writes it.
        case added
        /// Agents rows the user wrote: Set up… would refuse, so the row
        /// points at the manual placement instead.
        case customized
        /// Unreadable, a symlink, not UTF-8, or editing not configured.
        /// Set up… would refuse, so the row points at the manual placement.
        case unknown
    }

    /// Read-only: the same checks `configureLocalHerdrPanel` makes before it
    /// writes, so the row can tell whether pressing Set up… would do anything.
    public func localHerdrPanelStatus() -> LocalHerdrPanelStatus {
        guard let localHerdrConfigFileSystem,
              let state = try? localHerdrConfigFileSystem.readState(),
              !state.configIsSymlink
        else { return .unknown }
        guard let data = state.configData else { return .notAdded }
        guard let content = String(data: data, encoding: .utf8) else { return .unknown }
        // `split(whereSeparator: \.isNewline)` below treats CRLF as one
        // break; match the block the same way.
        if content.replacingOccurrences(of: "\r\n", with: "\n")
            .contains(Self.herdrPanelConfigSnippet) {
            return .added
        }
        return Self.localHerdrPanelConfigIsCustomized(content) ? .customized : .notAdded
    }

    /// Appends the agents-panel row block to the LOCAL herdr config — the
    /// config a federated herdr 0.9 client renders its agents panel from
    /// (`ClientShellConfig::from_config` reads `config.ui.sidebar.agents` on
    /// the machine the CLIENT runs on, which for a federated surface is this
    /// Mac, not the enrolled host).
    ///
    /// Same conservative rule as `setupRemoteHerdr`: append the
    /// three-row block only when the config carries no
    /// `[ui.sidebar.agents]` table and no `rows` key; refuse — leaving the
    /// file untouched — and point at the manual placement otherwise. The
    /// caller must obtain explicit consent immediately before invoking this.
    ///
    /// One deliberate difference from the remote path: this does NOT run
    /// `herdr server reload-config`. The app cannot locate the user's herdr
    /// binary reliably (a GUI app sees neither the shell's PATH nor the
    /// install prefix a non-brew install chose), so applying the change is
    /// the user's one step, and the Settings row says so
    /// (`localHerdrPanelReloadStatus`).
    @discardableResult
    public func configureLocalHerdrPanel() throws -> [ExecutionStep] {
        guard let localHerdrConfigFileSystem else {
            throw ServiceError.localHerdrConfigEditingNotConfigured
        }
        Log.claudeContext.info("Local herdr panel configuration requested")
        let state = try localHerdrConfigFileSystem.readState()
        guard !state.configIsSymlink else { throw ServiceError.localHerdrConfigUnreadable }

        var existing = ""
        if let data = state.configData {
            guard let decoded = String(data: data, encoding: .utf8) else {
                Log.claudeContext.error(
                    "Local herdr panel configuration failed: config is not valid UTF-8"
                )
                throw ServiceError.localHerdrConfigUnreadable
            }
            existing = decoded
        }
        if Self.localHerdrPanelConfigIsCustomized(existing) {
            Log.claudeContext.info(
                "Local herdr panel configuration refused: existing table or rows key; add manually:\n\(Self.herdrPanelConfigSnippet, privacy: .public)"
            )
            throw ServiceError.localHerdrPanelConfigAlreadyCustomized
        }

        // Append, preserving whatever the user's file already ends with so
        // the TOML stays one document: no gluing a table header onto the last
        // key's line, and no run of blank lines either.
        var updated = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updated.isEmpty { updated += "\n\n" }
        updated += Self.herdrPanelConfigSnippet + "\n"

        if !state.directoryExists {
            try localHerdrConfigFileSystem.createConfigDirectory(permissions: 0o755)
        }
        try localHerdrConfigFileSystem.atomicWriteConfig(
            Data(updated.utf8),
            permissions: state.configPermissions ?? 0o644,
            expectedConfigPresent: state.configData != nil
        )
        Log.claudeContext.info("Local herdr panel configuration completed")
        return [
            ExecutionStep(
                index: 0,
                command: "configure local herdr agents panel",
                message: Self.localHerdrPanelReloadStatus
            )
        ]
    }
}
