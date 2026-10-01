import Foundation

/// Recognizes a Claude project's page in Claude Desktop:
/// `https://claude.ai/epitaxy/project/chan_<id>`, with `?thread=cmsg_<id>`
/// while one of its threads is open. MEASURED on Claude Desktop 2.16120.0
/// (2026-10-01, #1194): the address of the web view holding the project chat's
/// prompt box, and of the same view with a thread open.
///
/// The page names the project and the thread, never a Claude Code session, so
/// it joins nothing. It tells the app only that the dictation goes to coding
/// agents, which picks the agent polish profile. Same strict checks as the
/// session addresses (`ClaudeSessionPageURL`), the query ignored.
package enum ClaudeProjectPageURL {
    private static let pathPrefix = "/epitaxy/project/"
    private static let projectIDPrefix = "chan_"
    private static let maxProjectIDCount = 128

    /// Whether `rawURL` is exactly a Claude project page, a thread open or not.
    package static func isProjectPage(_ rawURL: String) -> Bool {
        guard let projectID = ClaudeSessionPageURL.lastComponent(
            of: rawURL, underPathPrefix: pathPrefix
        ) else { return false }
        return ClaudeSessionPageURL.isIdentifier(
            projectID, prefix: projectIDPrefix, maxCount: maxProjectIDCount
        )
    }
}
