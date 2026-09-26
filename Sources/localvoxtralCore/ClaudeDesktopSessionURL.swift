import Foundation

/// Parses the Claude Desktop Code-tab session id out of the address of the web
/// view the desktop app shows that session in.
///
/// Claude Desktop shows Code-tab sessions in a web view whose address is
/// `https://claude.ai/epitaxy/local_<uuid>`, and it exports the same
/// `local_<uuid>` into the session's environment as
/// `CLAUDE_CODE_HOST_SESSION_ID` — so every hook the session runs carries it,
/// on this Mac or on an ssh host the desktop app runs the session on. Both
/// were MEASURED on Claude Desktop 2.2553.1 (2026-09-18) and again on
/// 2.9939.2 (2026-09-26), where the address names the session in the
/// window's primary pane (`AXClaudeDesktopSessionURLReader` says which focus
/// may use it) and that session's Claude Code process, on an ssh host, had
/// the same id in its environment. Neither is documented, so a desktop update that renames either
/// stops this arm from joining; it cannot make it join the wrong session.
///
/// Strict for the reason `ClaudeBridgeSessionURL` is — a false positive is a
/// join — and through the same checks (`ClaudeSessionPageURL`): https only,
/// host exactly `claude.ai`, no userinfo or port, the path exactly
/// `/epitaxy/<id>` with at most one trailing slash, query and fragment
/// ignored, and `<id>` matching `local_[A-Za-z0-9_-]+` on the percent-ENCODED
/// path. Anything else returns nil, which means "no join", never "guess".
package enum ClaudeDesktopSessionURL {
    /// The path prefix the session id follows.
    private static let pathPrefix = "/epitaxy/"

    /// The id's required prefix. The desktop app allocates the whole value;
    /// this is the part of its shape we can check without inventing rules
    /// about the rest (today a lowercase UUID).
    private static let sessionIDPrefix = "local_"

    /// Hard cap on the id. Real ids are 42 characters; anything approaching
    /// this is not one, and the value becomes a registry lookup key.
    private static let maxSessionIDCount = 128

    /// The desktop session id named by `rawURL`, or nil when the URL is not
    /// exactly a Claude Desktop Code-tab session address.
    package static func sessionID(inWebAreaURL rawURL: String) -> String? {
        guard let sessionID = ClaudeSessionPageURL.lastComponent(
            of: rawURL, underPathPrefix: pathPrefix
        ) else { return nil }
        guard isSessionID(sessionID) else { return nil }
        return sessionID
    }

    /// `local_[A-Za-z0-9_-]+`, ASCII only, bounded.
    package static func isSessionID(_ candidate: String) -> Bool {
        ClaudeSessionPageURL.isIdentifier(
            candidate, prefix: sessionIDPrefix, maxCount: maxSessionIDCount
        )
    }
}
