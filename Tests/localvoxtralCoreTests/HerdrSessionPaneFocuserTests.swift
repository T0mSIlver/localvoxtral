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
            windowTTY: { _ in window },
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
        var session = ClaudeSessionSnapshot(
            sessionID: "remote:h1:s1",
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: "h1")),
            firstSeen: Self.epoch
        )
        session.remoteSessionEnvironment = ClaudeRemoteSessionEnvironment(
            herdrPaneID: "w2:p5", herdrSocketPath: remoteSocket, hookParentPID: "4711"
        )
        let subject = focuser(herdr: herdr, paneSessionID: { _ in "remote:h1:s1" })
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
        XCTAssertFalse(noWindow, "no single terminal window shows that herdr")
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
        localSockets: Set<String> = []
    ) -> HerdrWindowLocator {
        let hosts = [host, otherHost]
        return HerdrWindowLocator(
            herdrClientTTYs: { herdrClients },
            sshClientTTYs: { ssh.keys.sorted() },
            sshConnection: { ssh[$0] ?? .noSSHClient },
            federation: { federation },
            liveLocalHerdrSockets: { localSockets },
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
        let tty = await locator(ssh: ssh).windowTTY(for: remoteTarget)
        XCTAssertEqual(tty, "/dev/ttys001")
    }

    func testTwoCandidateWindowsRaiseNone() async {
        let ssh: [String: SSHDestinationTTYProbeResult] = [
            "/dev/ttys001": connection("builder", .plainClient(sessionSelector: nil)),
            "/dev/ttys005": connection("builder", .plainClient(sessionSelector: nil)),
        ]
        let tty = await locator(ssh: ssh).windowTTY(for: remoteTarget)
        XCTAssertNil(tty)

        let competing = await locator(ssh: [
            "/dev/ttys001": connection("builder", .plainClient(sessionSelector: nil), competing: true),
        ]).windowTTY(for: remoteTarget)
        XCTAssertNil(competing, "another terminal may show a different herdr view")
    }

    func testAFederatedClientShowingThatHostIsItsWindow() async {
        let builder = HerdrMachineProfile(id: "p", label: "b", target: "builder", session: "default", enabled: true)
        let gpu = HerdrMachineProfile(id: "q", label: "g", target: "gpu", session: "default", enabled: true)
        let shown = await locator(herdrClients: ["/dev/ttys009"], federation: .showingMachine(builder))
            .windowTTY(for: remoteTarget)
        XCTAssertEqual(shown, "/dev/ttys009")
        let other = await locator(herdrClients: ["/dev/ttys009"], federation: .showingMachine(gpu))
            .windowTTY(for: remoteTarget)
        XCTAssertNil(other, "a client showing another machine cannot show the pane")
    }

    func testALocalPaneRaisesTheLocalHerdrClientShowingLocal() async {
        let target = HerdrPaneFocusTarget.local(paneID: "w1:p2", socketPath: "/tmp/h.sock")
        let shown = await locator(herdrClients: ["/dev/ttys006"], localSockets: ["/tmp/h.sock"])
            .windowTTY(for: target)
        XCTAssertEqual(shown, "/dev/ttys006")

        let builder = HerdrMachineProfile(id: "p", label: "b", target: "builder", session: "default", enabled: true)
        let federated = await locator(
            herdrClients: ["/dev/ttys006"], federation: .showingMachine(builder), localSockets: ["/tmp/h.sock"]
        ).windowTTY(for: target)
        XCTAssertNil(federated, "the client shows a remote machine, not this herdr")

        let twoServers = await locator(herdrClients: ["/dev/ttys006"], localSockets: ["/tmp/h.sock", "/tmp/i.sock"])
            .windowTTY(for: target)
        XCTAssertNil(twoServers, "no way to tell which herdr the client attaches")
    }
}
