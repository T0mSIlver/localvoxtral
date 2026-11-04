import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// Reading a herdr pane back (#1012): herdr's focused pane over a real
/// `HerdrSocketClient` to a fake herdr, and the window found by the join's
/// process-table evidence. The read-back, which lets a Return into the
/// pane go, needs both.
@MainActor
final class HerdrSessionPaneFocuserTests: XCTestCase {
    private nonisolated static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let client = HerdrSocketClient(timeout: 2)
    private let ghostty = TerminalScreenAllowlist.ghosttyBundleID

    /// A herdr whose focused pane is `focused`, running `foreground` (pid,
    /// name) in its foreground. `localSession`'s agent is pid 2.
    private func herdr(
        focused: String = "w1:p2",
        foreground: @escaping @Sendable () -> [(pid: Int32, name: String)] = { [(2, "claude")] }
    ) throws -> FakeHerdrSocket {
        try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane(focused, foreground: foreground))
    }

    private func localSession(paneID: String = "w1:p2", socket: String) -> ClaudeSessionSnapshot {
        var session = ClaudeSessionSnapshot(
            sessionID: "s1", origin: .localAuthenticated(peerUID: 501), firstSeen: Self.epoch
        )
        session.process = ClaudeHookProcessInfo(
            hookPID: 1, claudePID: 2, tty: "/dev/ttys-inner", herdrPaneID: paneID, herdrSocketPath: socket
        )
        return session
    }

    /// The registry's answer when the pane holds only the session asked for.
    private nonisolated static func askedSessionID(_ target: HerdrPaneFocusTarget) -> String? {
        switch target {
        case .local: "s1"
        case .remote(let hostID, _, _): "remote:\(hostID):s1"
        }
    }

    private final class Box<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        func get() -> Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    private func focuser(
        herdr: FakeHerdrSocket,
        window: String? = "/dev/ttys007",
        windowReadBack: String? = "/dev/ttys007",
        paneSessionID: @escaping (HerdrPaneFocusTarget) -> String? = askedSessionID
    ) -> HerdrSessionPaneFocuser {
        HerdrSessionPaneFocuser(
            windowShows: { _, tty in tty == window },
            openSocket: { _ in HerdrFocusSocket(path: herdr.socketPath) },
            panes: client,
            focusedTTY: { _ in windowReadBack },
            paneSessionID: paneSessionID
        )
    }

    func testThePaneShowsTheSessionWhenHerdrTheWindowAndTheRegistryAgree() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let session = localSession(socket: herdr.socketPath)
        let shows = await focuser(herdr: herdr).focusedPaneShows(session, bundleID: ghostty)
        XCTAssertTrue(shows)
        XCTAssertEqual(
            herdr.requests.map(\.method), ["pane.current", "pane.process_info"],
            "the read-back asks and writes nothing")
    }

    /// A suspended agent (Ctrl-Z) keeps its pane, tty and registry entry
    /// while its shell owns the pane: a Return would run the dictated text
    /// as a command (#1249).
    func testAnAgentThatIsNotInThePanesForegroundIsNotShown() async throws {
        let herdr = try herdr(foreground: { [(777, "zsh")] })
        defer { herdr.stop() }
        let shows = await focuser(herdr: herdr).focusedPaneShows(localSession(socket: herdr.socketPath), bundleID: ghostty)
        XCTAssertFalse(shows)
    }

    /// A remote pid means nothing on this Mac, so a remote pane's agent is
    /// found by its hook parent or its name. The registry keeps a remote
    /// session live by TTL, so a suspended remote agent still reads back as
    /// the pane's session otherwise.
    func testARemoteAgentIsShownOnlyWhileItIsInThePanesForeground() async throws {
        let foreground = Box<[(pid: Int32, name: String)]>([(4711, "claude")])
        let herdr = try herdr(focused: "w2:p5", foreground: { foreground.get() })
        defer { herdr.stop() }
        let epoch = Self.epoch
        let registry = ClaudeSessionRegistry(now: { epoch }, isProcessAlive: { _ in true })
        let session = try XCTUnwrap(registry.ingest(
            ClaudeHookRecord(event: .sessionStart, sessionID: "s1", timestamp: 0, rawCwd: "/srv/app"),
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: "h1")),
            environment: ClaudeRemoteSessionEnvironment(
                herdrPaneID: "w2:p5", herdrSocketPath: remoteSocket, hookParentPID: "4711"
            )
        ))
        let subject = focuser(herdr: herdr, paneSessionID: { _ in session.sessionID })
        let inForeground = await subject.focusedPaneShows(session, bundleID: ghostty)
        XCTAssertTrue(inForeground)
        foreground.set([(900, "zsh")])
        let atShell = await subject.focusedPaneShows(session, bundleID: ghostty)
        XCTAssertFalse(atShell, "the pane is back at its shell")
    }

    func testAnotherPaneFocusedInHerdrIsNotShown() async throws {
        let herdr = try herdr(focused: "w1:p9")
        defer { herdr.stop() }
        let shows = await focuser(herdr: herdr).focusedPaneShows(localSession(socket: herdr.socketPath), bundleID: ghostty)
        XCTAssertFalse(shows)
    }

    /// One opencode TUI hosts sessions A and B in one herdr pane and shows B
    /// (#1601): the pane and the window read back, but a dictation would
    /// join B.
    func testAnotherOpencodeSessionShownInThePaneIsNotShown() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let shows = await focuser(herdr: herdr, paneSessionID: { _ in "s2" })
            .focusedPaneShows(localSession(socket: herdr.socketPath), bundleID: ghostty)
        XCTAssertFalse(shows)
    }

    func testATabSwitchOrAWindowWithNoReadBackIsNotShown() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let session = localSession(socket: herdr.socketPath)
        let switched = await focuser(herdr: herdr, windowReadBack: "/dev/ttys008")
            .focusedPaneShows(session, bundleID: ghostty)
        XCTAssertFalse(switched, "the terminal's front tab is another tty")
        let unread = await focuser(herdr: herdr, windowReadBack: nil).focusedPaneShows(session, bundleID: ghostty)
        XCTAssertFalse(unread)
        let noWindow = await focuser(herdr: herdr, window: nil).focusedPaneShows(session, bundleID: ghostty)
        XCTAssertFalse(noWindow, "the focused terminal window does not show that herdr")
    }

    // MARK: - Finding the window

    private let host = ClaudeRemoteHost(id: "h1", label: "builder", sshHostAlias: "builder", createdAt: epoch)
    private let otherHost = ClaudeRemoteHost(id: "h2", label: "gpu", sshHostAlias: "gpu", createdAt: epoch)
    private let remoteSocket = "/home/tom/.config/herdr/herdr.sock"

    private func connection(_ destination: String, _ herdr: HerdrInvocation, competing: Bool = false)
        -> SSHDestinationTTYProbeResult
    {
        .connection(SSHSurfaceConnection(destination: destination, hasCompetingHerdrClient: competing, herdr: herdr))
    }

    private func locator(
        herdrClients: [String]? = [],
        ssh: [String: SSHDestinationTTYProbeResult] = [:],
        federation: HerdrMachineFederation = .notFederated,
        localSockets: Set<String> = [],
        wholeViewClients: Set<String>? = nil
    ) -> HerdrWindowLocator {
        let hosts = [host, otherHost]
        return HerdrWindowLocator(
            herdrClientTTYs: { herdrClients },
            sshClientTTYs: { ssh.keys.sorted() },
            sshConnection: { ssh[$0] ?? .noSSHClient },
            federation: { federation },
            liveLocalHerdrSockets: { localSockets },
            isWholeViewClient: { wholeViewClients?.contains($0) ?? true },
            enrolledHosts: { destination in hosts.filter { $0.sshHostAlias == destination } },
            canonicalizedEnrolledHosts: { _ in [] }
        )
    }

    private var remoteTarget: HerdrPaneFocusTarget {
        .remote(hostID: "h1", paneID: "w2:p5", remoteSocketPath: remoteSocket)
    }

    func testARemotePaneRaisesTheOneTerminalWhoseSSHRunsHerdrOnThatHost() async {
        let ssh: [String: SSHDestinationTTYProbeResult] = [
            "/dev/ttys001": connection("builder", .plainClient(sessionSelector: nil)),
            "/dev/ttys002": connection("gpu", .plainClient(sessionSelector: nil)),
            "/dev/ttys003": connection("builder", .notHerdr),
            "/dev/ttys004": connection("builder", .plainClient(sessionSelector: "other")),
        ]
        let locator = locator(ssh: ssh)
        let shows = await locator.windowShows(remoteTarget, tty: "/dev/ttys001")
        XCTAssertTrue(shows)
        for other in ["/dev/ttys002", "/dev/ttys003", "/dev/ttys004"] {
            let alsoShows = await locator.windowShows(remoteTarget, tty: other)
            XCTAssertFalse(alsoShows, other)
        }
    }

    func testTwoCandidateWindowsRaiseNone() async {
        let ssh: [String: SSHDestinationTTYProbeResult] = [
            "/dev/ttys001": connection("builder", .plainClient(sessionSelector: nil)),
            "/dev/ttys005": connection("builder", .plainClient(sessionSelector: nil)),
        ]
        let shows = await locator(ssh: ssh).windowShows(remoteTarget, tty: "/dev/ttys001")
        XCTAssertFalse(shows)

        let competing = await locator(ssh: [
            "/dev/ttys001": connection("builder", .plainClient(sessionSelector: nil), competing: true),
        ]).windowShows(remoteTarget, tty: "/dev/ttys001")
        XCTAssertFalse(competing, "another terminal may show a different herdr view")
    }

    func testAFederatedClientShowingThatHostIsItsWindow() async {
        let builder = HerdrMachineProfile(id: "p", label: "b", target: "builder", session: "default", enabled: true)
        let gpu = HerdrMachineProfile(id: "q", label: "g", target: "gpu", session: "default", enabled: true)
        let shown = await locator(herdrClients: ["/dev/ttys009"], federation: .showingMachine(builder))
            .windowShows(remoteTarget, tty: "/dev/ttys009")
        XCTAssertTrue(shown)
        let other = await locator(herdrClients: ["/dev/ttys009"], federation: .showingMachine(gpu))
            .windowShows(remoteTarget, tty: "/dev/ttys009")
        XCTAssertFalse(other, "a client showing another machine cannot show the pane")
    }

    func testALocalPaneRaisesTheLocalHerdrClientShowingLocal() async {
        let target = HerdrPaneFocusTarget.local(paneID: "w1:p2", socketPath: "/tmp/h.sock")
        let shown = await locator(herdrClients: ["/dev/ttys006"], localSockets: ["/tmp/h.sock"])
            .windowShows(target, tty: "/dev/ttys006")
        XCTAssertTrue(shown)

        let builder = HerdrMachineProfile(id: "p", label: "b", target: "builder", session: "default", enabled: true)
        let federated = await locator(
            herdrClients: ["/dev/ttys006"], federation: .showingMachine(builder), localSockets: ["/tmp/h.sock"]
        ).windowShows(target, tty: "/dev/ttys006")
        XCTAssertFalse(federated, "the client shows a remote machine, not this herdr")

        let twoServers = await locator(herdrClients: ["/dev/ttys006"], localSockets: ["/tmp/h.sock", "/tmp/i.sock"])
            .windowShows(target, tty: "/dev/ttys006")
        XCTAssertFalse(twoServers, "no way to tell which herdr the client attaches")
    }

    /// LVX-99: two terminal windows on one local herdr with no machines
    /// saved. herdr keeps one focus per server, so the focused window shows
    /// the focused pane whichever of the two it is.
    func testEitherWindowOfOneLocalHerdrShowsItsFocusedPane() async {
        let target = HerdrPaneFocusTarget.local(paneID: "w1:p2", socketPath: "/tmp/h.sock")
        let clients = ["/dev/ttys006", "/dev/ttys007"]
        let locator = locator(herdrClients: clients, localSockets: ["/tmp/h.sock"])
        for tty in clients {
            let shows = await locator.windowShows(target, tty: tty)
            XCTAssertTrue(shows, tty)
        }
        let unrelated = await locator.windowShows(target, tty: "/dev/ttys008")
        XCTAssertFalse(unrelated, "a terminal running no herdr client shows no pane")
    }

    /// `herdr terminal attach <id>` and `herdr --remote` show something other
    /// than the server's focused pane, so their window never counts.
    func testAnAttachOrRemoteClientWindowDoesNotShowTheFocusedPane() async {
        let target = HerdrPaneFocusTarget.local(paneID: "w1:p2", socketPath: "/tmp/h.sock")
        let locator = locator(
            herdrClients: ["/dev/ttys006", "/dev/ttys007"], localSockets: ["/tmp/h.sock"],
            wholeViewClients: ["/dev/ttys006"]
        )
        let attach = await locator.windowShows(target, tty: "/dev/ttys007")
        XCTAssertFalse(attach)
        let lone = await self.locator(
            herdrClients: ["/dev/ttys007"], localSockets: ["/tmp/h.sock"], wholeViewClients: []
        ).windowShows(target, tty: "/dev/ttys007")
        XCTAssertFalse(lone, "a lone attach client is not a whole view either")
    }

    /// With machines saved, herdr keeps one selection per user, so a second
    /// client makes it unknowable which machine the focused one shows.
    func testTwoWindowsWithMachinesSavedShowNothing() async {
        let target = HerdrPaneFocusTarget.local(paneID: "w1:p2", socketPath: "/tmp/h.sock")
        let shows = await locator(
            herdrClients: ["/dev/ttys006", "/dev/ttys007"], federation: .showingLocal, localSockets: ["/tmp/h.sock"]
        ).windowShows(target, tty: "/dev/ttys006")
        XCTAssertFalse(shows)
    }

    /// End to end through the read-back: the second window of one local
    /// herdr lets the Return go.
    func testTheReadBackPassesInTheSecondWindowOfOneLocalHerdr() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let locator = locator(herdrClients: ["/dev/ttys006", "/dev/ttys007"], localSockets: [herdr.socketPath])
        let focuser = HerdrSessionPaneFocuser(
            windowShows: { await locator.windowShows($0, tty: $1) },
            openSocket: { _ in HerdrFocusSocket(path: herdr.socketPath) },
            panes: client,
            focusedTTY: { _ in "/dev/ttys007" },
            paneSessionID: Self.askedSessionID
        )
        let shows = await focuser.focusedPaneShows(localSession(socket: herdr.socketPath), bundleID: ghostty)
        XCTAssertTrue(shows)
    }
}
