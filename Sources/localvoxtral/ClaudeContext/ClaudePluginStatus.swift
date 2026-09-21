import Foundation

/// What the Integrations pane can say about the local Claude Code plugin.
///
/// Derived from `claude plugin list --json`, never from Claude Code's
/// internals: the install lives in Claude Code's own config, and the CLI's
/// machine-readable listing is the supported way to ask about it. The human
/// listing is never parsed: its shape changed once (the version moved to its
/// own `Version:` line) and silently took the version out of this row. The
/// bundled version comes from the bundled plugin's own `plugin.json` — the
/// number the listing names — so "update available" means "this app ships a
/// newer plugin than the listing names", nothing about what Claude Code would
/// do with it. (The marketplace's `metadata.version` is a different number;
/// comparing against it made every install read as outdated.)
public enum ClaudePluginStatus: Sendable, Equatable {
    /// The CLI is missing or the listing failed. The row still offers its
    /// buttons — pressing one reports the real error — but claims nothing.
    case unknown
    case notInstalled
    case installed(version: String?)
    case updateAvailable(installed: String, bundled: String)
    /// Installed and enabled, and loading nothing: Claude Code cannot read the
    /// marketplace it was installed from, so no session runs its hooks. Its
    /// own state is fine — what rotted is the PATH it was registered with.
    case failedToLoad(version: String?)

    /// One short sentence, per the pane's copy rule.
    public var sentence: String {
        switch self {
        case .unknown: return "Could not check plugin status."
        case .notInstalled: return "Not installed."
        case .installed(let version):
            guard let version else { return "Installed." }
            return "Installed \(version)."
        case .updateAvailable: return "Update available."
        case .failedToLoad: return "Installed, but not loading."
        }
    }

    /// The row's install button, named for what pressing it would do.
    public enum PrimaryAction: Sendable, Equatable {
        case install
        case update
        /// The state is unreadable, so the button claims neither.
        case installOrUpdate
        /// Re-register the marketplace where the plugin is loaded from.
        case repair

        public var title: String {
            switch self {
            case .install: return "Install"
            case .update: return "Update"
            case .installOrUpdate: return "Install or update"
            case .repair: return "Repair"
            }
        }
    }

    /// The install button to show, or nil when the installed plugin is at
    /// least the bundled version: reinstalling the same files changes nothing.
    /// An installed plugin whose version the listing could not name is not
    /// known to be current, so it keeps the button.
    public var primaryAction: PrimaryAction? {
        switch self {
        case .unknown: return .installOrUpdate
        case .notInstalled: return .install
        case .updateAvailable: return .update
        case .failedToLoad: return .repair
        case .installed(let version): return version == nil ? .installOrUpdate : nil
        }
    }

    /// Remove is offered unless the listing says there is nothing to remove.
    public var offersRemove: Bool { self != .notInstalled }

    /// Derive the status from a `claude plugin list --json` capture.
    ///
    /// - Parameters:
    ///   - listOutput: the CLI's stdout (a JSON array of entries), or nil
    ///     when the CLI is missing or the listing failed. A nil capture is `.unknown`, never
    ///     `.notInstalled`: absence of evidence is not evidence of absence,
    ///     and claiming "not installed" would invite an install over a setup
    ///     we simply failed to read.
    ///   - bundledVersion: the bundled plugin's `plugin.json` version, or nil
    ///     when the bundled manifest could not be read. Without it there is
    ///     nothing to compare against, so a found plugin is just installed.
    public static func derive(
        listOutput: String?,
        bundledVersion: String?
    ) -> ClaudePluginStatus {
        guard let listOutput else { return .unknown }
        // An undecodable capture is a listing we could not read, which is
        // the same verdict as no listing at all — never "not installed".
        guard let entries = ClaudePluginListing.entries(in: listOutput) else { return .unknown }
        guard let entry = ClaudePluginListing.entry(for: listReference(), in: entries) else {
            return .notInstalled
        }
        // Checked before the version comparison: a plugin that loads nothing
        // is not made well by being the newest one.
        if entry.marketplaceFailedToLoad { return .failedToLoad(version: entry.knownVersion) }
        guard let installed = entry.knownVersion else { return .installed(version: nil) }
        // m7: inequality is not ordering — a manually installed NEWER
        // marketplace must read as installed, never as an update onto an
        // older bundled one.
        if let bundledVersion, compareVersions(installed, bundledVersion) == .orderedAscending {
            return .updateAvailable(installed: installed, bundled: bundledVersion)
        }
        return .installed(version: installed)
    }

    /// Dotted-numeric ordering (`1.5.0` > `1.4.0`; a missing component reads
    /// as 0, so `1.4` == `1.4.0`). Non-numeric components read as 0 rather
    /// than refusing: versions here come from our own regex and manifest.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lparts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rparts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lparts.count, rparts.count) {
            let left = index < lparts.count ? lparts[index] : 0
            let right = index < rparts.count ? rparts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    /// The fully-qualified reference `claude plugin list` prints for an
    /// installed plugin, e.g. `localvoxtral@localvoxtral`.
    static func listReference(
        pluginName: String = ClaudePluginAssets.pluginName,
        marketplaceName: String = ClaudePluginAssets.marketplaceName
    ) -> String {
        "\(pluginName)@\(marketplaceName)"
    }

}
