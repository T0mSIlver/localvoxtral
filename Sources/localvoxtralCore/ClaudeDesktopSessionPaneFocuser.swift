import ClaudeContextWire
import Foundation

/// Reads back whether Claude Desktop's focused session view is a registry
/// session (#834), on this Mac or on an ssh host Desktop runs it on: the
/// way the join reads Desktop, `true` only when Desktop is frontmost and its
/// focused session view resolves to this session (focus in the prompt of the
/// primary pane, the view's id reported by this session alone). Asked right
/// before a Return into the session; it opens nothing and types nothing.
@MainActor
package final class ClaudeDesktopSessionPaneFocuser: SessionPaneFocusing {
    private let desktopPID: () -> pid_t?
    private let frontmostPID: () -> pid_t?
    private let shownSessionID: (pid_t) async -> String?

    /// - Parameters:
    ///   - desktopPID: the running Claude Desktop, nil when it is not
    ///     running.
    ///   - shownSessionID: the registry session Desktop's focused view shows,
    ///     read as the join reads it (`ClaudeSessionJoinResolver.sessionShown`).
    package init(
        desktopPID: @escaping () -> pid_t?,
        frontmostPID: @escaping () -> pid_t?,
        shownSessionID: @escaping (pid_t) async -> String?
    ) {
        self.desktopPID = desktopPID
        self.frontmostPID = frontmostPID
        self.shownSessionID = shownSessionID
    }

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID _: String) async -> Bool {
        guard let pid = desktopPID() else { return false }
        return await shows(session, pid: pid)
    }

    /// Frontmost is checked again after the read: the user can switch apps
    /// while it is suspended, and a dictation started on a stale `true`
    /// would go to the app they switched to.
    private func shows(_ session: ClaudeSessionSnapshot, pid: pid_t) async -> Bool {
        guard frontmostPID() == pid else { return false }
        guard await shownSessionID(pid) == session.sessionID else { return false }
        return frontmostPID() == pid
    }
}

/// The read-back dispatched on the session's route: a terminal tab, a Claude
/// Desktop session or a herdr pane.
@MainActor
package final class SessionPaneFocuserRouter: SessionPaneFocusing {
    private let terminal: any SessionPaneFocusing
    private let claudeDesktop: any SessionPaneFocusing
    private let herdr: any SessionPaneFocusing

    package init(
        terminal: any SessionPaneFocusing,
        claudeDesktop: any SessionPaneFocusing,
        herdr: any SessionPaneFocusing
    ) {
        self.terminal = terminal
        self.claudeDesktop = claudeDesktop
        self.herdr = herdr
    }

    private func focuser(for session: ClaudeSessionSnapshot) -> any SessionPaneFocusing {
        switch SessionPaneFocusRoute.of(session) {
        case .claudeDesktop: claudeDesktop
        case .herdrPane: herdr
        case .terminalTTY, .unsupported: terminal
        }
    }

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID: String) async -> Bool {
        await focuser(for: session).focusedPaneShows(session, bundleID: bundleID)
    }
}
