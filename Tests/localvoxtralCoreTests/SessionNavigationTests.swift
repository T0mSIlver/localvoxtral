import ClaudeContextWire
import Foundation
@testable import localvoxtralCore
import localvoxtralTestSupport
import XCTest

final class SessionNavigationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "host-a")

    // MARK: - Default names

    func testALinkedWorktreeAnswersToItsOwnNameAndItsRepositorys() {
        let session = localSession("a", cwd: "/Users/tom/localvoxtral/.claude/worktrees/cool-roentgen/Sources")
        let names = SessionDefaultNames.of(
            session,
            repositoryRoot: .root("/Users/tom/localvoxtral/.claude/worktrees/cool-roentgen", mainCheckout: "/Users/tom/localvoxtral")
        )
        XCTAssertEqual(names, SessionDefaultNames(primary: "cool-roentgen", repository: "localvoxtral"))
    }

    func testAMainCheckoutHasOneName() {
        let session = localSession("a", cwd: "/Users/tom/payments")
        XCTAssertEqual(
            SessionDefaultNames.of(session, repositoryRoot: .root("/Users/tom/payments")),
            SessionDefaultNames(primary: "payments", repository: nil)
        )
    }

    func testARootThatDoesNotHoldTheCwdIsIgnored() {
        let session = localSession("a", cwd: "/Users/tom/payments")
        XCTAssertEqual(
            SessionDefaultNames.of(session, repositoryRoot: .root("/Users/tom/other")).primary,
            "payments"
        )
        XCTAssertEqual(
            SessionDefaultNames.of(session, repositoryRoot: .unknown).primary,
            "payments"
        )
    }

    func testARemoteSessionAnswersToItsLabelAndItsHostsProjectName() {
        var session = ClaudeSessionSnapshot(sessionID: "r", origin: remote, firstSeen: epoch)
        session.workspace = ClaudeWorkspaceReference.make(rawCwd: "/srv/wt-17", origin: remote)
        session.remoteEnvironment = ClaudeRemoteSessionEnvironment(project: "billing")
        XCTAssertEqual(
            SessionDefaultNames.of(session, repositoryRoot: .unknown),
            SessionDefaultNames(primary: "wt-17", repository: "billing")
        )
    }

    // MARK: - One pane

    func testSessionsOnOneTTYAreOnePaneAndTheLatestStandsForIt() {
        let candidates = [
            candidate("old", tty: "/dev/ttys001", primary: "payments", activity: 10),
            candidate("new", tty: "/dev/ttys001", primary: "payments", activity: 20),
        ]
        XCTAssertEqual(SessionNameResolver.onePerPane(candidates).map(\.snapshot.sessionID), ["new"])
    }

    // MARK: - Focus route

    func testALocalTerminalTabOrAnyClaudeDesktopSessionHasARoute() {
        XCTAssertEqual(
            SessionPaneFocusRoute.of(localSession("a", cwd: "/p", tty: "/dev/ttys004", termProgram: "ghostty")),
            .terminalTTY("/dev/ttys004", termProgram: "ghostty")
        )
        XCTAssertEqual(SessionPaneFocusRoute.of(localSession("a", cwd: "/p")), .unsupported(.noTTY))

        var herdr = localSession("h", cwd: "/p", tty: "/dev/ttys004")
        herdr.process?.herdrPaneID = "p1"
        XCTAssertEqual(SessionPaneFocusRoute.of(herdr), .unsupported(.herdr), "no socket to ask")
        herdr.process?.herdrSocketPath = "/tmp/h.sock"
        XCTAssertEqual(SessionPaneFocusRoute.of(herdr), .herdrPane(.local(paneID: "p1", socketPath: "/tmp/h.sock")))

        var remoteHerdr = ClaudeSessionSnapshot(
            sessionID: "rh", origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: "h1")), firstSeen: epoch
        )
        remoteHerdr.remoteEnvironment = ClaudeRemoteSessionEnvironment(herdrPaneID: "w1:p3", herdrSocketPath: "/s")
        XCTAssertEqual(
            SessionPaneFocusRoute.of(remoteHerdr),
            .herdrPane(.remote(hostID: "h1", paneID: "w1:p3", remoteSocketPath: "/s"))
        )

        var cmux = localSession("c", cwd: "/p", tty: "/dev/ttys004")
        cmux.process?.cmuxSurfaceID = "s1"
        XCTAssertEqual(SessionPaneFocusRoute.of(cmux), .unsupported(.cmux))

        let desktopID = "local_6d880b94-4414-4764-a024-c95df1af4456"
        let link = URL(string: "claude://code/continue?session=\(desktopID)")!
        var desktop = localSession("d", cwd: "/p", tty: "/dev/ttys004")
        desktop.process?.desktopSessionID = desktopID
        XCTAssertEqual(SessionPaneFocusRoute.of(desktop), .claudeDesktop(link))

        var remoteDesktop = ClaudeSessionSnapshot(sessionID: "rd", origin: remote, firstSeen: epoch)
        remoteDesktop.remoteEnvironment = ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)
        XCTAssertEqual(SessionPaneFocusRoute.of(remoteDesktop), .claudeDesktop(link), "Desktop shows an ssh session on this Mac")

        var remoteSession = ClaudeSessionSnapshot(sessionID: "r", origin: remote, firstSeen: epoch)
        remoteSession.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004")
        XCTAssertEqual(SessionPaneFocusRoute.of(remoteSession), .unsupported(.remote))
    }

    /// Desktop's handler takes `local_` plus 1 to 64 letters, digits and
    /// dashes; anything else would land on its empty Code tab.
    func testTheDesktopLinkCarriesOnlyAnIDDesktopsHandlerTakes() {
        XCTAssertEqual(
            ClaudeDesktopSessionLink.continueURL(desktopSessionID: "local_0f3a-b2")?.absoluteString,
            "claude://code/continue?session=local_0f3a-b2"
        )
        for bad in ["local_", "local_a_b", "local_a&x=1", "local_é", "session_abc", "local_" + String(repeating: "a", count: 65)] {
            XCTAssertNil(ClaudeDesktopSessionLink.continueURL(desktopSessionID: bad), bad)
        }
        var odd = localSession("d", cwd: "/p")
        odd.process?.desktopSessionID = "local_a_b"
        XCTAssertEqual(SessionPaneFocusRoute.of(odd), .unsupported(.claudeDesktop))
    }

    // MARK: - Read-back

    /// The agent exits while its pane is read back: the shell left in its
    /// tty must not count as the session (Codex audit 2026-10-02, #1219).
    @MainActor
    func testASessionThatEndsDuringTheReadBackIsNotThere() async {
        let session = localSession("s", cwd: "/r/payments", tty: "/dev/ttys002")
        let live = LiveSessions([session])
        let focuser = FakeSessionPaneFocuser()
        focuser.onReadBack = { _ in live.sessions = [] }
        let navigator = SessionNavigator(liveSessions: { live.sessions }, focuser: focuser)

        let shows = await navigator.focusedPaneShows(sessionID: "s", bundleID: "com.mitchellh.ghostty")
        XCTAssertFalse(shows, "read back, but the session ended meanwhile")
        XCTAssertEqual(focuser.readBackSessionIDs, ["s"])
    }

    /// A suspended agent's tab reads back as the session's, but its shell
    /// owns the terminal: no pane route may type there (#1249). An
    /// unreadable process table refuses too.
    @MainActor
    func testAPaneWhoseAgentIsNotInTheForegroundDoesNotShowTheSession() async {
        let session = localSession("s", cwd: "/r/payments", tty: "/dev/ttys002")
        let cases: [(foreground: [Int32]?, shows: Bool)] = [([1, 2], true), ([1], false), (nil, false)]
        for (foreground, expected) in cases {
            let navigator = SessionNavigator(
                liveSessions: { [session] },
                focuser: FakeSessionPaneFocuser(),
                ttyForegroundPIDs: { $0 == "/dev/ttys002" ? foreground : [2] }
            )
            let shows = await navigator.focusedPaneShows(sessionID: "s", bundleID: "com.mitchellh.ghostty")
            XCTAssertEqual(shows, expected, "foreground \(String(describing: foreground))")
        }
    }

    // MARK: - Helpers

    private func localSession(
        _ id: String,
        cwd: String,
        tty: String? = nil,
        termProgram: String? = nil
    ) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: epoch)
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: tty, termProgram: termProgram)
        return snapshot
    }

    private func candidate(
        _ id: String,
        tty: String,
        primary: String,
        repository: String? = nil,
        activity: TimeInterval = 0
    ) -> SessionNameCandidate {
        var snapshot = localSession(id, cwd: "/p/\(primary)", tty: tty)
        snapshot.lastActivity = epoch.addingTimeInterval(activity)
        return SessionNameCandidate(
            snapshot: snapshot,
            names: SessionDefaultNames(primary: primary, repository: repository)
        )
    }
}

/// The registry's answer, changed by a test while the navigator awaits.
private final class LiveSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [ClaudeSessionSnapshot]

    init(_ sessions: [ClaudeSessionSnapshot]) {
        value = sessions
    }

    var sessions: [ClaudeSessionSnapshot] {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
