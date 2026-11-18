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
/// tty (`TerminalFocusedTTYReading`) must equal the session's, and the
/// registry must still resolve that tty to this session. One opencode TUI
/// hosts several sessions on one tty and shows one, so the tty alone cannot
/// say which prompt a Return would submit.
@MainActor
final class TerminalSessionPaneFocuser: SessionPaneFocusing {
    private let focusedTTY: (String) async -> String?
    private let frontmostBundleID: () -> String?
    private let sessionOnTTY: (String) -> String?

    /// - Parameter sessionOnTTY: the session the registry resolves a tty to,
    ///   as the join does (`ClaudeSessionRegistry.resolve(tty:)`); nil when
    ///   none, several or a stale one.
    init(
        focusedTTY: @escaping (String) async -> String?,
        frontmostBundleID: @escaping () -> String?,
        sessionOnTTY: @escaping (String) -> String?
    ) {
        self.focusedTTY = focusedTTY
        self.frontmostBundleID = frontmostBundleID
        self.sessionOnTTY = sessionOnTTY
    }

    static func live(
        ttyReader: any TerminalFocusedTTYReading,
        sessionOnTTY: @escaping (String) -> String?
    ) -> TerminalSessionPaneFocuser {
        TerminalSessionPaneFocuser(
            focusedTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            sessionOnTTY: sessionOnTTY
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
        guard await focusedTTY(bundleID) == tty else { return false }
        guard sessionOnTTY(tty) == session.sessionID else {
            Log.claudeContext.info("pane read-back: the tty resolves to no session or another one")
            return false
        }
        return true
    }
}
