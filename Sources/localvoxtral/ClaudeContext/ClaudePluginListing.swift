import Foundation

/// One entry of `claude plugin list --json` (Claude Code 2.1.x). Only the
/// keys the app reads; the decoder ignores everything else the CLI adds.
public struct ClaudePluginListEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let scope: String?
    public let enabled: Bool?
    /// What Claude Code could not do with this plugin, in its own words. An
    /// installed, enabled plugin can still be loading NOTHING — the listing
    /// says so here and nowhere else, and the app used to read such an entry
    /// as a healthy install (field failure, 2026-09-21).
    public let errorDetails: [ErrorDetail]?

    /// One machine-readable entry of `errorDetails`. The human `errors`
    /// strings are deliberately not decoded: they are prose, and prose is not
    /// a branch condition.
    /// `type` is OPTIONAL although Claude Code always sends it today: this
    /// array is decoded for EVERY installed plugin, so one unfamiliar entry
    /// from somebody else's plugin would otherwise fail the whole listing and
    /// leave the row blind exactly when a plugin is inert (review, 2026-09-21).
    public struct ErrorDetail: Decodable, Equatable, Sendable {
        public let type: String?
        public let marketplace: String?

        public init(type: String?, marketplace: String? = nil) {
            self.type = type
            self.marketplace = marketplace
        }
    }

    /// The marketplace this plugin comes from could not be read, so the
    /// plugin is installed and inert: no hooks run for it in any session.
    public var marketplaceFailedToLoad: Bool {
        (errorDetails ?? []).contains { $0.type == "marketplace-load-failed" }
    }

    /// The CLI prints `"unknown"` for a version it could not read. That is
    /// not a version.
    public var knownVersion: String? {
        version == "unknown" || version.isEmpty ? nil : version
    }
}

/// One entry of `claude plugin marketplace list --json`: where Claude Code
/// will look for a marketplace at the next session start.
public struct ClaudeMarketplaceListEntry: Decodable, Equatable, Sendable {
    public let name: String
    public let source: String?
    /// Present for a `directory` source — the path as it was registered.
    public let path: String?

    public init(name: String, source: String? = nil, path: String? = nil) {
        self.name = name
        self.source = source
        self.path = path
    }
}

/// Decoding rules shared by the local plugin row and the remote plugin
/// setup, so the two never disagree about what a listing says.
public enum ClaudePluginListing {
    /// The decoded entries, or nil when the capture is not a JSON array of
    /// entries. Callers treat nil as "could not read", never as "empty".
    public static func entries(in output: String) -> [ClaudePluginListEntry]? {
        try? JSONDecoder().decode([ClaudePluginListEntry].self, from: Data(output.utf8))
    }

    /// The entry for `reference` (`<name>@<marketplace>`, compared
    /// case-insensitively as the CLI prints it). A user-scope entry wins
    /// over a project/local one; among equals the first wins.
    public static func entry(
        for reference: String,
        in entries: [ClaudePluginListEntry]
    ) -> ClaudePluginListEntry? {
        let matches = entries.filter { $0.id.caseInsensitiveCompare(reference) == .orderedSame }
        return matches.first { $0.scope == "user" } ?? matches.first
    }

    /// The decoded marketplace listing, or nil when the capture is not one.
    public static func marketplaces(in output: String) -> [ClaudeMarketplaceListEntry]? {
        try? JSONDecoder().decode([ClaudeMarketplaceListEntry].self, from: Data(output.utf8))
    }

    /// The directory path our marketplace is registered with, or nil when it
    /// is not registered, not a directory source, or the capture is unreadable.
    ///
    /// The source check is not decoration: a github-sourced registration also
    /// has a local clone, and re-pointing one at a directory is a different
    /// decision than repairing a path that rotted.
    public static func registeredMarketplacePath(
        in output: String,
        name: String = ClaudePluginAssets.marketplaceName
    ) -> String? {
        guard let entries = marketplaces(in: output) else { return nil }
        guard let entry = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        guard entry.source?.caseInsensitiveCompare("directory") == .orderedSame else { return nil }
        guard let path = entry.path, !path.isEmpty else { return nil }
        return path
    }
}
