import ClaudeContextWire
import Foundation

// Reading which session a terminal's focused pane shows: what the commit
// asks right before it presses a key into a joined session's pane ("send
// it", the mod's keyboard fallback), so a switch to another tab meanwhile
// cannot take the key (#1712). The Apple events live in the app
// (`TerminalSessionPaneFocuser`).

/// How a session's pane can be brought to the front.
package enum SessionPaneFocusRoute: Equatable, Sendable {
    /// A local session in a plain terminal tab or split, found by its tty.
    /// `termProgram` names the terminal to ask first.
    case terminalTTY(String, termProgram: String?)
    /// A Claude Desktop Code-tab session, on this Mac or on an ssh host
    /// Desktop runs it on (#834), found by the `local_<uuid>` id its hooks
    /// reported. Desktop's own link brings it forward.
    case claudeDesktop(URL)
    /// A session in a herdr pane, on this Mac or on an enrolled ssh host
    /// (#1012): herdr focuses the pane, then the terminal window showing that
    /// herdr is raised.
    case herdrPane(HerdrPaneFocusTarget)
    case unsupported(SessionPaneFocusUnsupported)

    package static func of(_ snapshot: ClaudeSessionSnapshot) -> SessionPaneFocusRoute {
        // Either origin: the id is Desktop's, and the session's view lives
        // in Desktop on this Mac wherever its process runs.
        if let desktopSessionID = snapshot.desktopSessionID {
            guard let link = ClaudeDesktopSessionLink.continueURL(desktopSessionID: desktopSessionID) else {
                return .unsupported(.claudeDesktop)
            }
            return .claudeDesktop(link)
        }
        if case .remote(let channel) = snapshot.origin {
            guard let environment = snapshot.remoteSessionEnvironment,
                  let paneID = environment.herdrPaneID,
                  let socketPath = environment.herdrSocketPath,
                  let hostID = ClaudeRemoteSessionScope.hostID(fromChannel: channel)
            else { return .unsupported(.remote) }
            return .herdrPane(.remote(hostID: hostID, paneID: paneID, remoteSocketPath: socketPath))
        }
        let process = snapshot.process
        // A herdr pane's or cmux surface's tty belongs to the multiplexer, not
        // to a terminal tab.
        if let paneID = process?.herdrPaneID {
            guard let socketPath = process?.herdrSocketPath else { return .unsupported(.herdr) }
            return .herdrPane(.local(paneID: paneID, socketPath: socketPath))
        }
        if process?.cmuxSurfaceID != nil { return .unsupported(.cmux) }
        guard let tty = process?.tty, !tty.isEmpty else { return .unsupported(.noTTY) }
        return .terminalTTY(tty, termProgram: process?.termProgram)
    }
}

package enum SessionPaneFocusUnsupported: String, Equatable, Sendable {
    case remote
    case claudeDesktop
    case herdr
    case cmux
    case noTTY
}

/// Reads back the pane a key would reach.
@MainActor
package protocol SessionPaneFocusing: AnyObject {
    /// Whether `bundleID`'s focused pane, read back the way the join reads
    /// it, still carries the session's tty. Asked again right before a
    /// Return into a joined session's pane.
    func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID: String) async -> Bool
}

/// The live sessions' panes, read back before a key.
@MainActor
package final class SessionNavigator {
    private let liveSessions: @Sendable () -> [ClaudeSessionSnapshot]
    private let ttyForegroundPIDs: @Sendable (String) -> [Int32]?
    package let focuser: any SessionPaneFocusing

    /// - Parameter ttyForegroundPIDs: the pids in a tty's foreground process
    ///   group, from the local process table. DEFAULTS TO ABSTAIN (nil),
    ///   which refuses every write into a local terminal pane; the app wires
    ///   the live table.
    package init(
        liveSessions: @escaping @Sendable () -> [ClaudeSessionSnapshot],
        focuser: any SessionPaneFocusing,
        ttyForegroundPIDs: @escaping @Sendable (String) -> [Int32]? = { _ in nil }
    ) {
        self.liveSessions = liveSessions
        self.ttyForegroundPIDs = ttyForegroundPIDs
        self.focuser = focuser
    }

    /// Whether `bundleID`'s focused pane, read back the way the join reads
    /// it, shows the live session `sessionID`; false once it is not live,
    /// before or after the read-back, or once its local agent no longer
    /// holds its terminal. An agent that exits leaves a shell on its tty,
    /// which reads back the same (#1219).
    package func focusedPaneShows(sessionID: String, bundleID: String) async -> Bool {
        guard let session = liveSession(sessionID) else { return false }
        let shows = await focuser.focusedPaneShows(session, bundleID: bundleID)
        return shows && liveSession(sessionID) != nil && agentHoldsItsTerminal(sessionID: sessionID)
    }

    /// Whether the live session `sessionID`'s local agent is in its tty's
    /// foreground process group, the herdr route's foreground test. A
    /// suspended agent (Ctrl-Z) is alive and registered, and its tty reads
    /// back as the session's, but its shell owns the terminal and runs
    /// typed text as a command (#1249). Asked right before each key into a
    /// local terminal pane. A session with no local tty (remote, Claude
    /// Desktop) has no shell here to reach and passes.
    package func agentHoldsItsTerminal(sessionID: String) -> Bool {
        guard let session = liveSession(sessionID) else { return false }
        guard session.origin.isLocalAuthenticated, let tty = session.process?.tty else { return true }
        guard let foreground = ttyForegroundPIDs(tty),
              ClaudeSessionJoinResolver.registeredAgentIsForeground(
                  snapshot: session, foregroundPIDs: foreground, abstain: { _ in }
              )
        else {
            Log.dictation.notice("session pane: the agent does not own its terminal's foreground; no key")
            return false
        }
        return true
    }

    private func liveSession(_ sessionID: String) -> ClaudeSessionSnapshot? {
        liveSessions().first { $0.sessionID == sessionID }
    }
}
