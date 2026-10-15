import Foundation

/// Recognizes a Claude project's page in Claude Desktop:
/// `https://claude.ai/epitaxy/project/chan_<id>`, with `?thread=cmsg_<id>`
/// while one of its threads is open. MEASURED on Claude Desktop 2.16120.0
/// (2026-10-01, #1194): the address of the web view holding the project chat's
/// prompt box. The thread form is how the page links its threads; the
/// address with a thread open is not measured yet.
///
/// The page names the project and the thread, never a Claude Code session.
/// The project chat joins nothing: it only tells the app that the dictation
/// goes to coding agents, which picks the agent polish profile. A thread
/// joins the one session that has seen the same thread id in its prompts
/// (`ClaudeProjectThreadEnvelope`). Same strict checks as the session
/// addresses (`ClaudeSessionPageURL`).
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

    /// The `cmsg_…` id of the thread open on the project page `rawURL`, or nil
    /// when it is not a project page or its query is anything but one
    /// well-formed `thread` item. Read from the percent-ENCODED query, like
    /// the path: an escape never reaches the id check undecoded.
    package static func threadID(inPageURL rawURL: String) -> String? {
        guard isProjectPage(rawURL),
              let items = URLComponents(string: rawURL)?.percentEncodedQueryItems
        else { return nil }
        let threads = items.filter { $0.name == "thread" }
        guard threads.count == 1, let threadID = threads[0].value,
              ClaudeProjectThreadEnvelope.isThreadID(threadID)
        else { return nil }
        return threadID
    }
}
