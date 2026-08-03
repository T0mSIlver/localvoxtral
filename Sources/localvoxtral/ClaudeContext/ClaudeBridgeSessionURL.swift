import Foundation

/// Parses the Claude Code "Remote Control" session id out of a browser tab URL.
///
/// A Remote Control session runs the `claude` process on the user's own machine
/// while `claude.ai/code` in a browser is its UI, and Claude Code ≥ 2.1.199
/// exports `CLAUDE_CODE_BRIDGE_SESSION_ID` into every hook subprocess for as
/// long as that connection is up. Its value is exactly the `session_…`
/// component of the browser URL, which is what makes an exact-equality join
/// possible with no heuristics at all: the tab the user is looking at names the
/// session, and the session's own hooks published the same name.
///
/// Everything here is pure and deliberately strict, because a false positive is
/// a join — and a join attaches a session's prior prompt and repository to the
/// user's words. So this accepts EXACTLY `https://claude.ai/code/session_…`:
///
/// * scheme `https` (case-insensitive), never `http` — the real UI is https,
///   and accepting http would let a plain-text host on a hijacked DNS answer;
/// * host exactly `claude.ai` after ASCII-lowercasing, so `claude.ai.evil.com`,
///   `x.claude.ai`, and `evil.com/claude.ai/code/…` all fail;
/// * no userinfo and no port — `https://claude.ai@evil.com/…` puts the real
///   host after the `@`, and a port means something other than the site;
/// * path exactly `/code/<id>` with at most one trailing slash;
/// * `<id>` matching `session_[A-Za-z0-9_-]+` on the PERCENT-ENCODED path, so
///   an escape (`%2F`, `%00`) can never decode into a shape this accepted;
/// * query and fragment ignored — the app appends both, and neither is part of
///   the identity.
///
/// Anything else returns nil, which means "no join", never "guess".
enum ClaudeBridgeSessionURL {
    /// Hosts whose `/code/session_…` URLs identify a Remote Control session.
    /// Exact match after lowercasing; there is deliberately no suffix match.
    static let host = "claude.ai"

    /// The path prefix the session id follows.
    private static let pathPrefix = "/code/"

    /// The id's required prefix. Anthropic allocates the whole value; this is
    /// the part of its shape we can check without inventing rules about the
    /// rest.
    private static let sessionIDPrefix = "session_"

    /// Hard cap on the id. Real ids are ~30 characters; anything approaching
    /// this is not one, and the value becomes a registry lookup key.
    private static let maxSessionIDCount = 128

    /// The bridge session id named by `rawURL`, or nil when the URL is not
    /// exactly a Claude Code session URL.
    static func sessionID(inTabURL rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL) else { return nil }
        // `scheme` is already the parsed scheme, so a string like
        // "https://claude.ai@evil.com/..." cannot fake it — the userinfo check
        // below is what covers that shape.
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else { return nil }
        guard components.user == nil, components.password == nil, components.port == nil
        else { return nil }
        guard let rawHost = components.host?.lowercased(), rawHost == host else { return nil }

        // The PERCENT-ENCODED path on purpose: `components.path` would decode
        // `%2F` to `/` and `%00` to NUL, so a decoded read could accept a value
        // that is not what the browser's address bar says. Encoded, every
        // escape still carries its `%`, which the id charset rejects.
        var path = components.percentEncodedPath
        // At most ONE trailing slash is tolerated (`…/session_x/`); `//` is a
        // different path and is not this one.
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix(pathPrefix) else { return nil }

        let sessionID = String(path.dropFirst(pathPrefix.count))
        guard isSessionID(sessionID) else { return nil }
        return sessionID
    }

    /// `session_[A-Za-z0-9_-]+`, ASCII only, bounded.
    static func isSessionID(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(sessionIDPrefix), candidate.count <= maxSessionIDCount
        else { return false }
        let rest = candidate.dropFirst(sessionIDPrefix.count)
        guard !rest.isEmpty else { return false }
        // Byte-wise, like the remote env charset check: every byte of a
        // non-ASCII scalar is ≥ 0x80 and therefore outside the set, so this
        // rejects Cyrillic look-alikes without a separate ASCII test.
        return rest.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }
}
