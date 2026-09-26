import ClaudeContextWire
import Foundation
@testable import localvoxtralCore
import localvoxtralTestSupport
import XCTest

final class SessionNavigationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "host-a")

    // MARK: - The command

    func testTheWholeDictationMustBeTheCommand() {
        let cases: [(String, String?)] = [
            ("go to payments", "payments"),
            ("Go to Payments.", "Payments"),
            ("  go   to local voxtral!  ", "local voxtral"),
            ("Goto payments", "payments"),
            ("go to cool roentgen twenty one", "cool roentgen twenty one"),
            // A sentence, not a name.
            ("go to the tests folder and fix the failing one", nil),
            ("please go to payments", nil),
            ("go to", nil),
            ("go to ...", nil),
            ("go payments", nil),
            ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SessionVoiceCommandParser.spokenName(in: text), expected, text)
        }
    }

    /// #723 step 2. Not "call this one": that is a coding prompt.
    func testNamingThisSessionIsACommandOnlyAsTheWholeText() {
        let cases: [(String, SessionVoiceCommand?)] = [
            ("call this session payments", .nameThisSession("payments")),
            ("Name this session Payments API.", .nameThisSession("Payments API")),
            ("go to payments", .goTo("payments")),
            ("call this one payments", nil),
            ("call this session", nil),
            ("call this session the one that fixes the build", nil),
            ("please call this session payments", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SessionVoiceCommandParser.command(in: text), expected, text)
        }
        XCTAssertNil(SessionVoiceCommandParser.spokenName(in: "call this session payments"))
    }

    /// #747: Live Auto-Paste holds a segment only while it may read "go to".
    func testALiveSegmentIsHeldOnlyWhileItMayReadGoTo() {
        let cases: [(String, SessionVoiceCommandParser.SegmentPrefix)] = [
            ("", .undecided),
            (" G", .undecided),
            (" Go", .undecided),
            ("Go ", .undecided),
            ("go t", .undecided),
            ("Go to", .undecided),
            ("Got", .undecided),
            ("Go to p", .possibleCommand),
            ("go to local voxtral", .possibleCommand),
            ("Goto pay", .possibleCommand),
            ("go to cool roentgen twenty one", .possibleCommand),
            // Five name words: a sentence, typed from here on.
            ("go to the tests folder and f", .ordinary),
            ("Good", .ordinary),
            ("Go ahead", .ordinary),
            ("Gotta", .ordinary),
            ("run the tests", .ordinary),
            ("please go to payments", .ordinary),
            // #723 step 2's phrase is held the same way.
            ("Call this", .undecided),
            ("call this session pay", .possibleCommand),
            ("Call the tests", .ordinary),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SessionVoiceCommandParser.segmentPrefix(text), expected, text)
        }
    }

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

    // MARK: - Resolution

    func testSpokenFormsMatchTheDirectoryName() {
        let candidates = [candidate("a", tty: "/dev/ttys001", primary: "payments-api")]
        for spoken in ["payments api", "Payments-API", "paymentsapi"] {
            XCTAssertEqual(resolvedID(spoken, candidates), "a", spoken)
        }
        XCTAssertEqual(SessionNameResolver.resolve(spokenName: "payments", candidates: candidates), .unknown)
    }

    func testAWorktreeNameWinsOverTheRepositoryName() {
        let candidates = [
            candidate("main", tty: "/dev/ttys001", primary: "localvoxtral"),
            candidate("wt", tty: "/dev/ttys002", primary: "cool-roentgen", repository: "localvoxtral"),
        ]
        XCTAssertEqual(resolvedID("cool roentgen", candidates), "wt")
        XCTAssertEqual(resolvedID("localvoxtral", candidates), "main")
    }

    func testTheRepositoryNameReachesALoneWorktree() {
        let candidates = [candidate("wt", tty: "/dev/ttys002", primary: "cool-roentgen", repository: "localvoxtral")]
        XCTAssertEqual(resolvedID("local voxtral", candidates), "wt")
    }

    func testANicknameWinsOverEveryDefaultName() {
        var named = candidate("wt", tty: "/dev/ttys002", primary: "cool-roentgen", repository: "localvoxtral")
        named.nickname = "payments"
        let candidates = [candidate("pay", tty: "/dev/ttys001", primary: "payments"), named]
        XCTAssertEqual(resolvedID("payments", candidates), "wt")
        XCTAssertEqual(resolvedID("cool roentgen", candidates), "wt", "the default names still work")
    }

    @MainActor
    func testANamedSessionIsFoundByItsNickname() async {
        let session = localSession("s", cwd: "/r/localvoxtral", tty: "/dev/ttys002")
        let store = SessionNicknameStore(load: []) { _ in }
        let navigator = SessionNavigator(
            liveSessions: { [session] },
            repositoryRoot: { _ in .unknown },
            focuser: FakeSessionPaneFocuser(),
            sleep: ManualSessionClock().sleep,
            nicknames: store
        )
        XCTAssertFalse(navigator.name(sessionID: "gone", nickname: "payments"), "only a live session")
        XCTAssertTrue(navigator.name(sessionID: "s", nickname: "payments"))
        let resolution = await navigator.resolve(spokenName: "Payments")
        XCTAssertEqual(resolution, .resolved(session))
    }

    func testTwoPanesOnOneNameAreAmbiguous() {
        let candidates = [
            candidate("wt1", tty: "/dev/ttys001", primary: "wt-a", repository: "localvoxtral"),
            candidate("wt2", tty: "/dev/ttys002", primary: "wt-b", repository: "localvoxtral"),
        ]
        XCTAssertEqual(
            SessionNameResolver.resolve(spokenName: "localvoxtral", candidates: candidates),
            .ambiguous(count: 2)
        )
    }

    func testSessionsOnOneTTYAreOnePaneAndTheLatestStandsForIt() {
        let candidates = [
            candidate("old", tty: "/dev/ttys001", primary: "payments", activity: 10),
            candidate("new", tty: "/dev/ttys001", primary: "payments", activity: 20),
        ]
        XCTAssertEqual(resolvedID("payments", candidates), "new")
    }

    // MARK: - Focus route

    func testOnlyALocalSessionInAPlainTerminalHasARoute() {
        XCTAssertEqual(
            SessionPaneFocusRoute.of(localSession("a", cwd: "/p", tty: "/dev/ttys004", termProgram: "ghostty")),
            .terminalTTY("/dev/ttys004", termProgram: "ghostty")
        )
        XCTAssertEqual(SessionPaneFocusRoute.of(localSession("a", cwd: "/p")), .unsupported(.noTTY))

        var herdr = localSession("h", cwd: "/p", tty: "/dev/ttys004")
        herdr.process?.herdrPaneID = "p1"
        XCTAssertEqual(SessionPaneFocusRoute.of(herdr), .unsupported(.herdr))

        var cmux = localSession("c", cwd: "/p", tty: "/dev/ttys004")
        cmux.process?.cmuxSurfaceID = "s1"
        XCTAssertEqual(SessionPaneFocusRoute.of(cmux), .unsupported(.cmux))

        var desktop = localSession("d", cwd: "/p", tty: "/dev/ttys004")
        desktop.process?.desktopSessionID = "local_x"
        XCTAssertEqual(SessionPaneFocusRoute.of(desktop), .unsupported(.claudeDesktop))

        var remoteSession = ClaudeSessionSnapshot(sessionID: "r", origin: remote, firstSeen: epoch)
        remoteSession.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004")
        XCTAssertEqual(SessionPaneFocusRoute.of(remoteSession), .unsupported(.remote))
    }

    // MARK: - Navigator

    @MainActor
    func testTheNavigatorNamesAWorktreeByTheGitRootWalk() async {
        let wt = localSession("wt", cwd: "/r/localvoxtral/.claude/worktrees/cool-roentgen/Sources", tty: "/dev/ttys002")
        let navigator = SessionNavigator(
            liveSessions: { [wt] },
            repositoryRoot: { _ in
                .root("/r/localvoxtral/.claude/worktrees/cool-roentgen", mainCheckout: "/r/localvoxtral")
            },
            focuser: FakeSessionPaneFocuser(),
            sleep: ManualSessionClock().sleep
        )
        let byWorktree = await navigator.resolve(spokenName: "cool roentgen")
        XCTAssertEqual(byWorktree, .resolved(wt))
        let byRepository = await navigator.resolve(spokenName: "localvoxtral")
        XCTAssertEqual(byRepository, .resolved(wt))
    }

    @MainActor
    func testAWalkThatDoesNotAnswerFallsBackToTheCwdName() async {
        let session = localSession("s", cwd: "/r/payments", tty: "/dev/ttys002")
        let clock = ManualSessionClock()
        let release = DispatchSemaphore(value: 0)
        let navigator = SessionNavigator(
            liveSessions: { [session] },
            repositoryRoot: { _ in
                // A stat parked on a dead mount.
                release.wait()
                return .root("/r/elsewhere")
            },
            focuser: FakeSessionPaneFocuser(),
            sleep: clock.sleep
        )
        async let resolution = navigator.resolve(spokenName: "payments")
        await clock.waitForSleepers(1)
        clock.advance(by: 0.25)
        let answer = await resolution
        XCTAssertEqual(answer, .resolved(session))
        release.signal()
    }

    @MainActor
    func testFocusByIDReachesTheFocuserOnlyForALiveSession() async {
        let session = localSession("s", cwd: "/r/payments", tty: "/dev/ttys002")
        let focuser = FakeSessionPaneFocuser(outcome: .unverified(bundleID: "com.googlecode.iterm2"))
        let navigator = SessionNavigator(
            liveSessions: { [session] },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep
        )
        let live = await navigator.focusPane(sessionID: "s")
        XCTAssertEqual(live, .unverified(bundleID: "com.googlecode.iterm2"))
        let gone = await navigator.focusPane(sessionID: "gone")
        XCTAssertNil(gone)
        XCTAssertEqual(focuser.focusedSessionIDs, ["s"])
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

    private func resolvedID(_ spoken: String, _ candidates: [SessionNameCandidate]) -> String? {
        guard case .resolved(let snapshot) = SessionNameResolver.resolve(spokenName: spoken, candidates: candidates)
        else { return nil }
        return snapshot.sessionID
    }
}
