import Foundation

/// T3 Code's desktop app, whose threads run Claude Code sessions the app may
/// join (LVX-55).
///
/// A fourth list, disjoint from `TerminalScreenAllowlist`,
/// `BrowserTabAllowlist` and `ClaudeDesktopAllowlist`, for the reason those
/// are disjoint: it grants one capability only, the read of the address of
/// the web view whose thread composer holds keyboard focus, and never a
/// screen read. `TerminalScreenClaudeJoinAuthorizer` refuses the `.t3Thread`
/// mechanism outright.
package enum T3CodeAllowlist {
    /// T3 Code's bundle identifier, as the diagnostic records name its
    /// dictation target (Oct 2026).
    package static let bundleID = "com.t3tools.t3code"

    /// Exact match only.
    package static func isSupported(_ bundleID: String?) -> Bool {
        bundleID == Self.bundleID
    }
}
