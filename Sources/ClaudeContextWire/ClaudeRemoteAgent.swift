import Foundation

/// Which agent a REMOTE hook request speaks for, from the `X-Lvx-Agent`
/// request header.
///
/// The local wire carries the agent inside the record, written by our own
/// publisher binary. A remote host has no publisher: its shim posts a JSON
/// body in Claude Code's hook shape, so the agent rides beside it as a
/// header, like the environment labels do.
///
/// Absent means Claude Code — every remote plugin shipped before this header
/// existed is one. A value this build does not know is REFUSED rather than
/// defaulted: a newer shim's agent must not be filed as a Claude Code session
/// and inherit Claude Code's join rules. opencode has no remote path, so it is
/// not accepted here either.
///
/// Like every header, this is a claim by the authenticated host about its own
/// sessions. It decides id scoping and per-agent rules inside that host's
/// namespace and never trust: the origin stays `.remote`, keyed by the token.
public enum ClaudeRemoteAgentCodec {
    public static let headerName = "X-Lvx-Agent"
    static let lowercasedHeaderName = headerName.lowercased()

    /// Agents with a remote shim.
    static let remoteAgents: Set<ClaudeHookAgent> = [.claude, .vibe]

    /// - Parameter headers: request headers with LOWERCASED names, as
    ///   `ClaudeRemoteHTTPRequest` holds them.
    public static func agent(in headers: [String: String]) -> ClaudeHookAgent? {
        guard let value = headers[lowercasedHeaderName] else { return .claude }
        guard let agent = ClaudeHookAgent(rawValue: value), remoteAgents.contains(agent) else {
            return nil
        }
        return agent
    }

    /// Labels only Claude's own tooling allocates: a Remote Control bridge
    /// session and a Claude Desktop view. Another agent started inside such a
    /// session inherits the variables, and joining it to that Claude view
    /// would attach the wrong session's context. The local publisher withholds
    /// them for the same reason.
    static let claudeOnlyFields: [ClaudeRemoteEnvironmentField] = [.bridgeSessionID, .desktopSessionID]

    public static func environment(
        _ environment: ClaudeRemoteSessionEnvironment?,
        for agent: ClaudeHookAgent
    ) -> ClaudeRemoteSessionEnvironment? {
        guard agent != .claude, var environment else { return environment }
        for field in claudeOnlyFields { environment[field] = nil }
        return environment.isEmpty ? nil : environment
    }
}
