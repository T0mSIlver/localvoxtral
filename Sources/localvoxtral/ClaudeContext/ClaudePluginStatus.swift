import Foundation

/// What the Integrations pane can say about the local Claude Code plugin.
///
/// Derived from `claude plugin list --json`, never from Claude Code's
/// internals: the install lives in Claude Code's own config, and the CLI's
/// machine-readable listing is the supported way to ask about it. The human
/// listing is never parsed: its shape changed once (the version moved to its
/// own `Version:` line) and silently took the version out of this row. The bundled version comes from this repo's
/// own marketplace manifest (`metadata.version`), so "update available" means
/// "this app ships a newer marketplace than the listing names" — nothing
/// about what Claude Code would do with it.
public enum ClaudePluginStatus: Sendable, Equatable {
    /// The CLI is missing or the listing failed. The row still offers its
    /// buttons — pressing one reports the real error — but claims nothing.
    case unknown
    case notInstalled
    case installed(version: String?)
    case updateAvailable(installed: String, bundled: String)

    /// One short sentence, per the pane's copy rule.
    public var sentence: String {
        switch self {
        case .unknown: return "Could not check plugin status."
        case .notInstalled: return "Not installed."
        case .installed(let version):
            guard let version else { return "Installed." }
            return "Installed \(version)."
        case .updateAvailable: return "Update available."
        }
    }

    /// Derive the status from a `claude plugin list --json` capture.
    ///
    /// - Parameters:
    ///   - listOutput: the CLI's stdout (a JSON array of entries), or nil
    ///     when the CLI is missing or the listing failed. A nil capture is `.unknown`, never
    ///     `.notInstalled`: absence of evidence is not evidence of absence,
    ///     and claiming "not installed" would invite an install over a setup
    ///     we simply failed to read.
    ///   - bundledVersion: this app's marketplace `metadata.version`, or nil
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
