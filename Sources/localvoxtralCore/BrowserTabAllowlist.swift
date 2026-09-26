import Foundation

/// Bundle IDs whose FOCUSED TAB URL may be read to join a Claude Code
/// "Remote Control" session.
///
/// Deliberately a separate list from `TerminalScreenAllowlist`, not an
/// extension of it, because it grants a different capability. That list answers
/// "may this app's visible screen be read", and every member has a verified
/// per-pane capture route. This one answers only "may we ask this app for the
/// URL of its focused tab" — one short string, matched against ids the user's
/// own hooks published. A browser NEVER gets a screen read: there is no
/// verified route, the page is arbitrary web content, and
/// `TerminalScreenClaudeJoinAuthorizer` refuses the `.browserTab` mechanism
/// outright. Keeping the lists apart is what makes that impossible to widen by
/// accident — adding a browser here can never hand it a screen capability.
///
/// Membership is exact-match and reviewed. Chromium forks share Chrome's
/// scripting dictionary (`active tab of front window`), so Brave uses the same
/// script under its own bundle id; Safari has its own (`current tab`). Firefox
/// is out of scope: it exposes no AppleScript surface for the focused tab's
/// URL, so there is nothing to read and nothing to abstain about.
package enum BrowserTabAllowlist {
    /// Google Chrome's shipped bundle identifier.
    package static let chromeBundleID = "com.google.Chrome"
    /// Brave Browser's shipped bundle identifier (Chromium fork; Chrome's
    /// scripting dictionary).
    package static let braveBundleID = "com.brave.Browser"
    /// Safari's bundle identifier.
    package static let safariBundleID = "com.apple.Safari"

    /// Browsers whose focused tab URL may be read for a Claude session join.
    package static let supportedBundleIDs: Set<String> = [
        chromeBundleID, braveBundleID, safariBundleID,
    ]

    /// Exact-match only: no prefix matching (which would admit unverified
    /// channel builds and every "…Chrome Canary"-shaped id) and no user list.
    package static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return supportedBundleIDs.contains(bundleID)
    }
}
