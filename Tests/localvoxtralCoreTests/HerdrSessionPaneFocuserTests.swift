import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// Bringing a herdr pane forward (#1012): herdr's one write, `pane.focus`,
/// sent over a real `HerdrSocketClient` to a fake herdr, and the window found
/// by the join's process-table evidence. `.focused`, the only outcome that
/// lets a dictation start, needs both read-backs.
@MainActor
final class HerdrSessionPaneFocuserTests: XCTestCase {
    private nonisolated static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let client = HerdrSocketClient(timeout: 2)
    private let ghostty = TerminalScreenAllowlist.ghosttyBundleID

    /// A herdr that focuses what `pane.focus` names, as herdr 0.9 does,
    /// unless `focusAnswer` overrides the answer.
    private func herdr(
        focused initial: String = "w1:p1",
        focusAnswer: (@Sendable (String) -> FakeHerdrSocket.Answer)? = nil,
        focusTakes: Bool = true
    ) throws -> FakeHerdrSocket {
        let focused = Box(initial)
        return try FakeHerdrSocket { request in
            switch request.method {
            case "pane.focus":
                let pane = request.paneID ?? ""
                if let focusAnswer { return focusAnswer(pane) }
                if focusTakes { focused.set(pane) }
                return .result(#"{"type":"pane_info","pane":{"pane_id":"\#(pane)","focused":true}}"#)
            case "pane.current":
                let pane = focused.get()
                return .result(#"{"type":"pane_current","pane":{"pane_id":"\#(pane)","focused":true}}"#)
            default:
                return .error("unexpected")
            }
        }
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

    private func remoteSession(hostID: String = "h1") -> ClaudeSessionSnapshot {
        var session = ClaudeSessionSnapshot(
            sessionID: "remote:\(hostID):s1",
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID)),
            firstSeen: Self.epoch
        )
        session.remoteEnvironment = ClaudeRemoteSessionEnvironment(
            herdrPaneID: "w2:p5", herdrSocketPath: "/home/tom/.config/herdr/herdr.sock"
        )
        return session
    }

    private final class Box<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        func get() -> Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    /// What the focuser did outside herdr.
    private final class Raises: Sendable {
        let ttys = Mutex<[String]>([])
        let releases = Mutex(0)
        let opened = Mutex<[HerdrPaneFocusTarget]>([])
    }

    private func focuser(
        herdr: FakeHerdrSocket,
        window: String? = "/dev/ttys007",
        raised: SessionPaneFocusOutcome? = nil,
        raises: Raises = Raises()
    ) -> HerdrSessionPaneFocuser {
        let bundleID = ghostty
        return HerdrSessionPaneFocuser(
            windowTTY: { _ in window },
            openSocket: { target in
                raises.opened.withLock { $0.append(target) }
                return HerdrFocusSocket(path: herdr.socketPath, release: { raises.releases.withLock { $0 += 1 } })
            },
            focuser: client,
            panes: client,
            raiseTTY: { tty, _ in
                raises.ttys.withLock { $0.append(tty) }
                return raised ?? .focused(bundleID: bundleID)
            },
            focusedTTY: { _ in window }
        )
    }

    func testAConfirmedFocusIsFocusedAndSendsOnlyTheFocusAndItsReadBack() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let raises = Raises()
        let session = localSession(socket: herdr.socketPath)
        let focuser = focuser(herdr: herdr, raises: raises)

        let outcome = await focuser.focusPane(of: session)

        XCTAssertEqual(outcome, .focused(bundleID: ghostty))
        XCTAssertEqual(herdr.requests.map(\.method), ["pane.focus", "pane.current"])
        XCTAssertEqual(herdr.requests.first?.paneID, "w1:p2")
        XCTAssertEqual(raises.ttys.withLock { $0 }, ["/dev/ttys007"], "the window the locator found")
        let shows = await focuser.focusedPaneShows(session, bundleID: ghostty)
        XCTAssertTrue(shows)
    }

    /// herdr answered the focus, but its focused pane is still another one:
    /// no dictation may start there.
    func testAFocusHerdrDoesNotReadBackIsUnverified() async throws {
        let herdr = try herdr(focusTakes: false)
        defer { herdr.stop() }

        let outcome = await focuser(herdr: herdr).focusPane(of: localSession(socket: herdr.socketPath))

        XCTAssertEqual(outcome, .unverified(bundleID: ghostty))
    }

    func testAWindowTheTerminalDoesNotReadBackIsUnverified() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }

        let outcome = await focuser(herdr: herdr, raised: .unverified(bundleID: ghostty))
            .focusPane(of: localSession(socket: herdr.socketPath))

        XCTAssertEqual(outcome, .unverified(bundleID: ghostty))
    }

    /// The window came forward but herdr refused: the window is in front
    /// showing another pane, so callers must treat it as moved and not
    /// confirmed.
    func testARefusedFocusAfterTheRaiseIsUnverified() async throws {
        let herdr = try herdr(focusAnswer: { _ in .error("pane_not_found") })
        defer { herdr.stop() }
        let raises = Raises()

        let outcome = await focuser(herdr: herdr, raises: raises).focusPane(of: localSession(socket: herdr.socketPath))

        XCTAssertEqual(outcome, .unverified(bundleID: ghostty))
        XCTAssertEqual(raises.ttys.withLock { $0 }, ["/dev/ttys007"])
        XCTAssertEqual(raises.releases.withLock { $0 }, 1, "the socket lease is released")
    }

    /// A window the terminal cannot raise (#1033): herdr must not have moved,
    /// or the stop types into the pane it switched to while the caller
    /// believes nothing changed.
    func testAWindowThatDoesNotComeUpLeavesHerdrsPaneAlone() async throws {
        for failed: SessionPaneFocusOutcome in [.paneNotFound, .unsupported(.herdr)] {
            let herdr = try herdr(focused: "w1:p1")
            defer { herdr.stop() }

            let outcome = await focuser(herdr: herdr, raised: failed).focusPane(of: localSession(socket: herdr.socketPath))

            XCTAssertEqual(outcome, failed)
            XCTAssertEqual(herdr.requests.map(\.method), [], "herdr gets no pane.focus")
        }
    }

    /// No single window shows that herdr: herdr is not asked at all, and the
    /// user keeps today's sentence.
    func testWithNoWindowHerdrIsNotAsked() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }

        let outcome = await focuser(herdr: herdr, window: nil).focusPane(of: localSession(socket: herdr.socketPath))

        XCTAssertEqual(outcome, .unsupported(.herdr))
        XCTAssertEqual(herdr.requests, [])
    }

    func testARemotePaneIsFocusedOverTheForwardForItsOwnHost() async throws {
        let herdr = try herdr()
        defer { herdr.stop() }
        let raises = Raises()

        let outcome = await focuser(herdr: herdr, raises: raises).focusPane(of: remoteSession())

        XCTAssertEqual(outcome, .focused(bundleID: ghostty))
        XCTAssertEqual(
            raises.opened.withLock { $0 },
            [.remote(hostID: "h1", paneID: "w2:p5", remoteSocketPath: "/home/tom/.config/herdr/herdr.sock")]
        )
        XCTAssertEqual(herdr.requests.first?.paneID, "w2:p5")
        XCTAssertEqual(raises.ttys.withLock { $0 }, ["/dev/ttys007"])
        XCTAssertEqual(raises.releases.withLock { $0 }, 1)
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
