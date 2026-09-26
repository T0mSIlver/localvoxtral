import Foundation

/// The Claude Desktop app, whose Code tab hosts Claude Code sessions the app
/// may join.
///
/// A separate list from `TerminalScreenAllowlist` and `BrowserTabAllowlist`,
/// for the reason those two are separate from each other: it grants a
/// different capability. Claude Desktop gets exactly one read — the address of
/// the web view that holds keyboard focus — and never a screen read.
/// `TerminalScreenClaudeJoinAuthorizer` refuses the `.desktopSession`
/// mechanism outright, and keeping the lists apart means adding the app here
/// can never hand it a screen capability.
package enum ClaudeDesktopAllowlist {
    /// Claude Desktop's shipped bundle identifier (measured on 2.2553.1).
    package static let bundleID = "com.anthropic.claudefordesktop"

    /// Exact match only.
    package static func isSupported(_ bundleID: String?) -> Bool {
        bundleID == Self.bundleID
    }
}
