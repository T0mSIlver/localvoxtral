import AppKit
import ClaudeContextWire
import Foundation

/// Reads back which session a local terminal's focused pane shows, by the
/// tty its hooks reported: the commit asks it right before a Return into a
/// joined session's pane, so a switch to another tab of the same terminal
/// meanwhile cannot take the key (#1712). It brings nothing forward and
/// types nothing.
///
/// The answer is the way the join reads a pane: the terminal's focused-pane
/// tty (`TerminalFocusedTTYReading`) must equal the session's.
@MainActor
final class TerminalSessionPaneFocuser: SessionPaneFocusing {
    private let focusedTTY: (String) async -> String?
    private let frontmostBundleID: () -> String?

    init(
        focusedTTY: @escaping (String) async -> String?,
        frontmostBundleID: @escaping () -> String?
    ) {
        self.focusedTTY = focusedTTY
        self.frontmostBundleID = frontmostBundleID
    }

    static func live(ttyReader: any TerminalFocusedTTYReading) -> TerminalSessionPaneFocuser {
        TerminalSessionPaneFocuser(
            focusedTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        )
    }

    /// The terminal's focused-pane tty, or nil when the terminal is not
    /// frontmost once the read returns: the read answers for its front
    /// window whatever app the user switched to meanwhile. The herdr
    /// reader checks its window through this after herdr's awaits.
    func frontmostTTY(bundleID: String) async -> String? {
        let tty = await focusedTTY(bundleID)
        return frontmostBundleID() == bundleID ? tty : nil
    }

    func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID: String) async -> Bool {
        guard case .terminalTTY(let tty, _) = SessionPaneFocusRoute.of(session) else { return false }
        return await focusedTTY(bundleID) == tty
    }
}
