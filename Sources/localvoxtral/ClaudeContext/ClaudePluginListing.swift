import Foundation

/// One entry of `claude plugin list --json` (Claude Code 2.1.x). Only the
/// keys the app reads; the decoder ignores everything else the CLI adds.
public struct ClaudePluginListEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let scope: String?
    public let enabled: Bool?

    /// The CLI prints `"unknown"` for a version it could not read. That is
    /// not a version.
    public var knownVersion: String? {
        version == "unknown" || version.isEmpty ? nil : version
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
}
