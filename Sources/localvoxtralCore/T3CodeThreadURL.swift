import Foundation

/// Parses the T3 Code thread id out of the address of the web view T3 Code's
/// desktop app shows a thread in.
///
/// T3 Code (`com.t3tools.t3code`) is an Electron app whose router keeps the
/// route in the address FRAGMENT: under Electron it builds TanStack Router's
/// hash history, so a thread's view is `<origin>/#/<environmentId>/<threadId>`
/// (read from T3 Code's web bundle 0.1.7-nightly.20261104, route
/// `/$environmentId/$threadId`). Every Claude Code session T3 Code runs carries
/// the same `<threadId>` as `T3CODE_THREAD_ID` (measured on the dev box,
/// 2026-11-03 and 2026-11-04): a UUID for a thread the user started,
/// `mcp:launch:<64 hex>` for one an agent launched. The environment id names
/// the machine the thread runs on; the hooks do not know it, so only the
/// thread id is matched. Both are UNDOCUMENTED: a T3 Code update that moves
/// the route stops this arm joining, never makes it join the wrong session.
///
/// Strict, for the reason `ClaudeDesktopSessionURL` is: a false positive is a
/// join. The fragment must be exactly `/<environmentId>/<threadId>` with at
/// most one trailing slash and no query; each component is read
/// percent-DECODED once (T3's router may encode `:` in a param) and must
/// match its charset. The origin must be exactly `t3code://app`, the
/// production app's privileged scheme and host (T3 Code
/// `apps/desktop/src/electron/ElectronProtocol.ts`, `getDesktopUrl`): the
/// integrated browser's pages are http(s) and never match.
package enum T3CodeThreadURL {
    /// Longest thread id accepted. Real ones are 36 (UUID) or 75
    /// (`mcp:launch:` + 64 hex) characters.
    package static let maxThreadIDCount = 128
    private static let maxEnvironmentIDCount = 128

    /// The thread id named by `rawURL`, or nil when the URL is not exactly a
    /// T3 Code thread address.
    package static func threadID(inWebAreaURL rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              components.user == nil, components.password == nil,
              isT3Origin(components),
              let fragment = components.percentEncodedFragment
        else { return nil }
        var route = fragment
        if let query = route.firstIndex(of: "?") {
            // The hash router keeps search params after the path; a thread
            // view with one (an open panel) still names the thread.
            route = String(route[..<query])
        }
        if route.hasSuffix("/") { route.removeLast() }
        let parts = route.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty,
              let environmentID = String(parts[1]).removingPercentEncoding,
              let threadID = String(parts[2]).removingPercentEncoding,
              isEnvironmentID(environmentID), isThreadID(threadID),
              !staticRouteNames.contains(environmentID)
        else { return nil }
        return threadID
    }

    /// T3 Code's static first route segments. The router matches a static
    /// segment before a param, so `#/draft/<id>` (a new thread not yet sent)
    /// and `#/projects/<key>` never name a thread.
    private static let staticRouteNames: Set<String> = [
        "draft", "projects", "threads", "settings", "connect", "pair", "welcome", "guest",
    ]

    /// `[A-Za-z0-9_:-]+`, bounded. Byte-wise, so a non-ASCII look-alike fails.
    package static func isThreadID(_ candidate: String) -> Bool {
        isToken(candidate, maxCount: maxThreadIDCount, allowColon: true)
    }

    private static func isEnvironmentID(_ candidate: String) -> Bool {
        isToken(candidate, maxCount: maxEnvironmentIDCount, allowColon: true)
    }

    private static func isToken(_ candidate: String, maxCount: Int, allowColon: Bool) -> Bool {
        guard !candidate.isEmpty, candidate.utf8.count <= maxCount else { return false }
        return candidate.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            case UInt8(ascii: ":"):
                return allowColon
            default:
                return false
            }
        }
    }

    /// `t3code://app`, no port. `t3code-dev` is a development build's.
    private static func isT3Origin(_ components: URLComponents) -> Bool {
        components.scheme?.lowercased() == "t3code"
            && components.host?.lowercased() == "app"
            && components.port == nil
            && (components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/")
    }
}
