import ClaudeContextWire
import Foundation

/// Where a herdr-hosted session's pane lives, as the session's own hooks
/// reported it.
package enum HerdrPaneFocusTarget: Equatable, Sendable {
    /// A pane of a herdr on this Mac: the socket its pane env published.
    case local(paneID: String, socketPath: String)
    /// A pane of a herdr on an enrolled ssh host. `remoteSocketPath` is a
    /// label from that host; it is only ever an argv token of the app's own
    /// `ssh -L` forward, never dialed.
    case remote(hostID: String, paneID: String, remoteSocketPath: String)

    package var paneID: String {
        switch self {
        case .local(let paneID, _), .remote(_, let paneID, _): paneID
        }
    }
}

/// A socket a herdr focus can be sent over: herdr's own local socket, or the
/// local end of the join's `ssh -L` forward, released after use.
package struct HerdrFocusSocket: Sendable {
    package let path: String
    package let release: @Sendable () -> Void

    package init(path: String, release: @escaping @Sendable () -> Void = {}) {
        self.path = path
        self.release = release
    }
}

/// Brings a herdr-hosted session forward (#1012). Its one write is
/// `pane.focus` for the session's own pane (docs/agent/invariants.md, "herdr
/// focus for navigation"), sent only after the window is raised with the
/// terminal focuser's tty path and read back. `.focused` only when both read-backs agree: herdr's focused pane
/// is the session's, the terminal's focused tty is the window raised, and the
/// registry still resolves that pane to the session asked for (#1601).
/// Nothing is typed and no key is posted.
@MainActor
package final class HerdrSessionPaneFocuser: SessionPaneFocusing {
    private let windowTTY: (HerdrPaneFocusTarget) async -> String?
    private let openSocket: (HerdrPaneFocusTarget) async -> HerdrFocusSocket?
    private let focuser: any HerdrPaneFocusing
    private let panes: any HerdrPaneQuerying
    private let raiseTTY: (String, _ termProgram: String?) async -> SessionPaneFocusOutcome
    private let focusedTTY: (String) async -> String?
    private let paneSessionID: (HerdrPaneFocusTarget) -> String?

    /// - Parameters:
    ///   - windowTTY: the one local terminal tty showing that herdr
    ///     (`HerdrWindowLocator`), nil when none or several do.
    ///   - openSocket: the local socket, or a lease on the join's forward.
    ///   - raiseTTY: selects the tab holding a tty and activates its
    ///     terminal, answering `.focused` only when the terminal reads that
    ///     tty back (`TerminalSessionPaneFocuser`).
    ///   - focusedTTY: a terminal's focused tty, read as the join reads it.
    ///   - paneSessionID: the session the registry resolves the pane to, as
    ///     the join would (`ClaudeSessionRegistry.sessionID(shownIn:)`); nil
    ///     when none or several. One opencode TUI hosts several sessions in
    ///     one pane, and focusing the pane cannot pick among them.
    package init(
        windowTTY: @escaping (HerdrPaneFocusTarget) async -> String?,
        openSocket: @escaping (HerdrPaneFocusTarget) async -> HerdrFocusSocket?,
        focuser: any HerdrPaneFocusing,
        panes: any HerdrPaneQuerying,
        raiseTTY: @escaping (String, _ termProgram: String?) async -> SessionPaneFocusOutcome,
        focusedTTY: @escaping (String) async -> String?,
        paneSessionID: @escaping (HerdrPaneFocusTarget) -> String?
    ) {
        self.windowTTY = windowTTY
        self.openSocket = openSocket
        self.focuser = focuser
        self.panes = panes
        self.raiseTTY = raiseTTY
        self.focusedTTY = focusedTTY
        self.paneSessionID = paneSessionID
    }

    package func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        guard case .herdrPane(let target) = SessionPaneFocusRoute.of(session) else {
            return .unsupported(.herdr)
        }
        guard let tty = await windowTTY(target) else {
            Log.claudeContext.info("go to session: no single terminal window shows that herdr")
            return .unsupported(.herdr)
        }
        guard let socket = await openSocket(target) else {
            Log.claudeContext.info("go to session: herdr socket unavailable")
            return .paneNotFound
        }
        defer { socket.release() }
        guard !Task.isCancelled else { return .paneNotFound }
        // The window first: herdr's focus is written only once the window
        // that shows it is confirmed in front, so a raise that fails leaves
        // herdr untouched (#1033). Anything that fails after the raise is
        // `.unverified`, whose window callers know is in front.
        let raised = await raiseTTY(tty, session.process?.termProgram)
        guard case .focused(let bundleID) = raised else { return raised }
        guard !Task.isCancelled else { return .unverified(bundleID: bundleID) }
        let focus = await focuser.focusPane(socketPath: socket.path, paneID: target.paneID)
        guard focus != .refused else {
            Log.claudeContext.info("go to session: herdr refused the focus")
            return .unverified(bundleID: bundleID)
        }
        var paneFocused = await panes.focusedPane(socketPath: socket.path)?.paneID == target.paneID
        // The window again after herdr's awaits: the user may have switched
        // the terminal to another tab, where keys would go instead, or the
        // client to another machine on the same tty.
        if paneFocused { paneFocused = await stillShows(target, on: tty, bundleID: bundleID) }
        if paneFocused { paneFocused = paneShows(session, target) }
        Log.claudeContext.info(
            "go to session: herdr focus answered \(String(describing: focus), privacy: .public); verified=\(paneFocused, privacy: .public)"
        )
        return paneFocused ? .focused(bundleID: bundleID) : .unverified(bundleID: bundleID)
    }

    package func focusedPaneShows(_ session: ClaudeSessionSnapshot, bundleID: String) async -> Bool {
        guard case .herdrPane(let target) = SessionPaneFocusRoute.of(session),
              let tty = await windowTTY(target),
              await focusedTTY(bundleID) == tty,
              let socket = await openSocket(target)
        else { return false }
        defer { socket.release() }
        guard await panes.focusedPane(socketPath: socket.path)?.paneID == target.paneID else { return false }
        return await stillShows(target, on: tty, bundleID: bundleID) && paneShows(session, target)
    }

    /// Whether the pane shows `session` rather than another session sharing
    /// it: an opencode TUI's other session keeps the pane, the pid and the
    /// tty, so herdr's and the terminal's read-backs cannot tell them apart.
    private func paneShows(_ session: ClaudeSessionSnapshot, _ target: HerdrPaneFocusTarget) -> Bool {
        guard paneSessionID(target) == session.sessionID else {
            Log.claudeContext.info("go to session: the herdr pane resolves to no session or another one")
            return false
        }
        return true
    }

    /// Asked after herdr's awaits: the window that shows the target is still
    /// `tty` (the client did not switch machine) and the terminal's front
    /// tab is still that tty.
    private func stillShows(_ target: HerdrPaneFocusTarget, on tty: String, bundleID: String) async -> Bool {
        guard await windowTTY(target) == tty else { return false }
        return await focusedTTY(bundleID) == tty
    }
}

/// Finds the terminal window on this Mac that shows a given herdr, with the
/// join's own process-table evidence and never a window title (herdr has no
/// client introspection). Exactly one candidate tty, or none.
///
/// - A local herdr: the one live local herdr socket is the pane's, the
///   saved-machine state shows Local (with machines saved, only for a lone
///   client surface, as the local join arm requires), and one tty runs a
///   herdr client.
/// - A remote herdr: a tty whose foreground ssh goes to exactly that
///   enrolled host with a plain herdr client of that socket's session and no
///   competing herdr view (the remote join arm's argv checks), or the lone
///   local herdr client whose saved-machine selection names that host and
///   session (the federated arm's checks).
@MainActor
package struct HerdrWindowLocator {
    private let herdrClientTTYs: @Sendable () -> [String]?
    private let sshClientTTYs: @Sendable () -> [String]?
    private let sshConnection: @Sendable (String) -> SSHDestinationTTYProbeResult
    private let federation: @Sendable () -> HerdrMachineFederation
    private let liveLocalHerdrSockets: () -> Set<String>
    private let enrolledHosts: @MainActor (String) -> [ClaudeRemoteHost]
    private let canonicalizedEnrolledHosts: @MainActor (String) async -> [ClaudeRemoteHost]

    /// - Parameters:
    ///   - herdrClientTTYs: the ttys this user runs a herdr client on, one per
    ///     client job; nil when the process table cannot be read.
    ///   - sshClientTTYs: the ttys whose foreground job is an ssh.
    ///   - sshConnection: the join's ssh probe for one tty.
    package init(
        herdrClientTTYs: @escaping @Sendable () -> [String]?,
        sshClientTTYs: @escaping @Sendable () -> [String]?,
        sshConnection: @escaping @Sendable (String) -> SSHDestinationTTYProbeResult,
        federation: @escaping @Sendable () -> HerdrMachineFederation,
        liveLocalHerdrSockets: @escaping () -> Set<String>,
        enrolledHosts: @escaping @MainActor (String) -> [ClaudeRemoteHost],
        canonicalizedEnrolledHosts: @escaping @MainActor (String) async -> [ClaudeRemoteHost]
    ) {
        self.herdrClientTTYs = herdrClientTTYs
        self.sshClientTTYs = sshClientTTYs
        self.sshConnection = sshConnection
        self.federation = federation
        self.liveLocalHerdrSockets = liveLocalHerdrSockets
        self.enrolledHosts = enrolledHosts
        self.canonicalizedEnrolledHosts = canonicalizedEnrolledHosts
    }

    package func windowTTY(for target: HerdrPaneFocusTarget) async -> String? {
        let candidates: Set<String>
        switch target {
        case .local(_, let socketPath):
            candidates = localCandidates(socketPath: socketPath)
        case .remote(let hostID, _, let remoteSocketPath):
            candidates = await remoteCandidates(hostID: hostID, remoteSocketPath: remoteSocketPath)
        }
        guard candidates.count == 1 else {
            Log.claudeContext.info(
                "go to session: \(candidates.count, privacy: .public) terminal windows show that herdr"
            )
            return nil
        }
        return candidates.first
    }

    private func localCandidates(socketPath: String) -> Set<String> {
        guard liveLocalHerdrSockets() == [socketPath], let clients = herdrClientTTYs() else { return [] }
        switch federation() {
        case .notFederated:
            return Set(clients)
        case .showingLocal:
            return clients.count == 1 ? Set(clients) : []
        case .showingMachine, .unreadable:
            return []
        }
    }

    private func remoteCandidates(hostID: String, remoteSocketPath: String) async -> Set<String> {
        var candidates = Set<String>()
        for tty in sshClientTTYs() ?? [] {
            guard case .connection(let connection) = sshConnection(tty),
                  case .plainClient(let selector) = connection.herdr,
                  !connection.hasCompetingHerdrClient,
                  HerdrSessionSocket.isSocket(
                      remoteSocketPath, ofSessionNamed: selector ?? HerdrMachineProfile.defaultSessionName
                  ),
                  await namesOnlyHost(hostID, destination: connection.destination)
            else { continue }
            candidates.insert(tty)
        }
        if case .showingMachine(let profile) = federation(),
           let clients = herdrClientTTYs(), clients.count == 1,
           HerdrSessionSocket.isSocket(remoteSocketPath, ofSessionNamed: profile.session),
           await namesOnlyHost(hostID, destination: profile.target) {
            candidates.formUnion(clients)
        }
        return candidates
    }

    /// Exact alias first, then `ssh -G`, as the join arms match a destination.
    private func namesOnlyHost(_ hostID: String, destination: String) async -> Bool {
        var hosts = enrolledHosts(destination).filter { !$0.isRevoked && $0.sshHostAlias != nil }
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(destination)
        }
        return hosts.count == 1 && hosts.first?.id == hostID
    }
}

extension HerdrWindowLocator {
    /// The ttys whose foreground job, owned by `user`, is a process named
    /// `name` (`herdr` for a client, `ssh` for a connection), one per tty;
    /// nil when the process table or a device name cannot be read.
    nonisolated package static func foregroundTTYs(
        named name: String,
        processes: [TTYProcessTable.Entry]?,
        user: uid_t,
        devicePath: (dev_t) -> String?
    ) -> [String]? {
        guard let processes else { return nil }
        var paths = Set<String>()
        for entry in processes where entry.name == name && entry.effectiveUserID == user {
            guard let device = entry.ttyDevice, entry.processGroupID == entry.terminalForegroundGroupID else {
                continue
            }
            guard let path = devicePath(device) else { return nil }
            paths.insert(path)
        }
        return paths.sorted()
    }

    /// The live process table's ttys for `name`.
    nonisolated package static func liveForegroundTTYs(named name: String) -> [String]? {
        #if canImport(Darwin)
        foregroundTTYs(named: name, processes: TTYProcessTable.allProcesses(), user: geteuid()) { device in
            devname(device, S_IFCHR).map { "/dev/" + String(cString: $0) }
        }
        #else
        nil
        #endif
    }
}

extension ClaudeSessionRegistry {
    /// The session a herdr pane shows, resolved as the joins resolve it
    /// (#1601). A local pane goes through `resolve(herdrPaneID:)`, whose
    /// opencode focus declarations pick among one TUI's sessions. A remote
    /// pane names a session only when exactly one live session of that host
    /// and socket claims it, as the remote arm requires. Nil otherwise.
    package func sessionID(shownIn target: HerdrPaneFocusTarget) -> String? {
        switch target {
        case .local(let paneID, _):
            guard case .resolved(let snapshot) = resolve(herdrPaneID: paneID) else { return nil }
            return snapshot.sessionID
        case .remote(let hostID, let paneID, let remoteSocketPath):
            let claims = liveRemoteHerdrSessions(hostID: hostID).filter {
                $0.remoteSessionEnvironment?.herdrPaneID == paneID
                    && $0.remoteSessionEnvironment?.herdrSocketPath == remoteSocketPath
            }
            guard claims.count == 1 else { return nil }
            return claims[0].sessionID
        }
    }
}
