import ClaudeContextWire
import Foundation

/// Brings a Claude Desktop Code-tab session forward (#834), on this Mac or on
/// an ssh host Desktop runs it on: opens Desktop's own link to the session
/// (`ClaudeDesktopSessionLink`), then reads Desktop back the way the join
/// does. `.focused` only when Desktop is frontmost and its focused session
/// view resolves to this registry session: focus in the prompt of the
/// primary pane, and the view's id reported by this session alone. Nothing
/// is typed and no key is posted.
///
/// MEASURED on Claude Desktop 2.9939.2 (2026-09-27), from Finder and from
/// Desktop showing another session: the link switched the primary pane to
/// an ssh-host session and activated Desktop, and the join's reader read the
/// session back from its prompt 0.2 s after the open.
@MainActor
package final class ClaudeDesktopSessionPaneFocuser: SessionPaneFocusing {
    /// How often, and how many times, Desktop is read back after the open.
    package static let readBackInterval: Duration = .milliseconds(100)
    package static let readBackAttempts = 20

    private let desktopPID: () -> pid_t?
    private let frontmostPID: () -> pid_t?
    private let open: (URL) -> Bool
    private let shownSessionID: (pid_t) async -> String?
    private let sleep: (Duration) async -> Void

    /// - Parameters:
    ///   - desktopPID: the running Claude Desktop, nil when it is not
    ///     running. The link is never opened then: it would launch Desktop.
    ///   - open: hands the link to Desktop.
    ///   - shownSessionID: the registry session Desktop's focused view shows,
    ///     read as the join reads it (`ClaudeSessionJoinResolver.sessionShown`).
    ///   - sleep: the clock the read-back waits on.
    package init(
        desktopPID: @escaping () -> pid_t?,
        frontmostPID: @escaping () -> pid_t?,
        open: @escaping (URL) -> Bool,
        shownSessionID: @escaping (pid_t) async -> String?,
        sleep: @escaping (Duration) async -> Void
    ) {
        self.desktopPID = desktopPID
        self.frontmostPID = frontmostPID
        self.open = open
        self.shownSessionID = shownSessionID
        self.sleep = sleep
    }

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        guard case .claudeDesktop(let link) = SessionPaneFocusRoute.of(session) else {
            return .unsupported(.claudeDesktop)
        }
        guard let pid = desktopPID() else {
            Log.claudeContext.info("go to session: Claude Desktop is not running")
            return .paneNotFound
        }
        guard !Task.isCancelled else { return .paneNotFound }
        guard open(link) else {
            Log.claudeContext.error("go to session: Claude Desktop's session link could not be opened")
            return .paneNotFound
        }
        for _ in 0..<Self.readBackAttempts {
            await sleep(Self.readBackInterval)
            guard !Task.isCancelled else { return .unverified(bundleID: ClaudeDesktopAllowlist.bundleID) }
            if await shows(session, pid: pid) {
                Log.claudeContext.info("go to session: Claude Desktop shows the session; verified=true")
                return .focused(bundleID: ClaudeDesktopAllowlist.bundleID)
            }
        }
        Log.claudeContext.info("go to session: Claude Desktop opened the link; verified=false")
        return .unverified(bundleID: ClaudeDesktopAllowlist.bundleID)
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

/// The one focus primitive "go to <name>" and the answer shortcut share,
/// dispatched on the session's route: a terminal tab, a Claude Desktop
/// session or a herdr pane.
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

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        await focuser(for: session).focusPane(of: session)
    }

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID: String) async -> Bool {
        await focuser(for: session).focusedPaneShows(session, bundleID: bundleID)
    }
}
