import ClaudeContextWire
import CoreGraphics
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

/// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This
/// evaluates the value first and then unwraps it.
private func unwrapAsync<T>(
    _ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}

// MARK: - Fakes

/// Scripted herdr socket, recording every request so a test can prove which
/// socket path and which pane the client was pointed at.
private final class RemoteJoinHerdrPanes:
    HerdrPaneQuerying, HerdrPanelMetadataReporting, @unchecked Sendable
{
    struct Request: Equatable {
        var method: String
        var socketPath: String
        var paneID: String?
    }

    let requests = Mutex<[Request]>([])
    private let focused: HerdrFocusedPane?
    private let foreground: HerdrPaneForegroundInfo?
    private let visibleTexts = Mutex<[String?]>([])
    let panelReports = Mutex<[(socketPath: String, paneID: String, value: String?, ttl: Int?)]>([])
    private let panelReportSucceeds: Bool

    init(
        focused: HerdrFocusedPane?,
        foreground: HerdrPaneForegroundInfo? = HerdrPaneForegroundInfo(
            shellPID: 8000, foregroundProcesses: [HerdrForegroundProcess(pid: 9001, name: "claude")]
        ),
        texts: [String?] = [],
        panelReportSucceeds: Bool = true
    ) {
        self.focused = focused
        self.foreground = foreground
        self.panelReportSucceeds = panelReportSucceeds
        visibleTexts.withLock { $0 = texts }
    }

    func focusedPane(socketPath: String) async -> HerdrFocusedPane? {
        requests.withLock {
            $0.append(Request(method: "pane.current", socketPath: socketPath, paneID: nil))
        }
        return focused
    }

    func paneForegroundInfo(socketPath: String, paneID: String) async -> HerdrPaneForegroundInfo? {
        requests.withLock {
            $0.append(
                Request(method: "pane.process_info", socketPath: socketPath, paneID: paneID)
            )
        }
        return foreground
    }

    func paneVisibleText(socketPath: String, paneID: String) async -> String? {
        requests.withLock {
            $0.append(Request(method: "pane.read", socketPath: socketPath, paneID: paneID))
        }
        return visibleTexts.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    func reportPanelToken(
        socketPath: String,
        paneID: String,
        value: String?,
        ttlMilliseconds: Int?
    ) async -> Bool {
        panelReports.withLock {
            $0.append((socketPath, paneID, value, ttlMilliseconds))
        }
        return panelReportSucceeds
    }
}

private final class FakeForwardProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    private struct State {
        var isRunning: Bool
        var waiters: [CheckedContinuation<ClaudeRemoteForwardExitStatus, Never>] = []
    }

    private let state: Mutex<State>
    private let stderrContinuation: AsyncStream<String>.Continuation
    let standardErrorLines: AsyncStream<String>
    let terminations = Mutex(0)

    init(running: Bool = true) {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self)
        standardErrorLines = stream
        stderrContinuation = continuation
        state = Mutex(State(isRunning: running))
        if !running { stderrContinuation.finish() }
    }

    var isRunning: Bool { state.withLock { $0.isRunning } }
    var processIdentifier: pid_t { 4_242 }

    func exit() {
        let pending = state.withLock {
            current -> [CheckedContinuation<ClaudeRemoteForwardExitStatus, Never>]? in
            guard current.isRunning else { return nil }
            current.isRunning = false
            defer { current.waiters = [] }
            return current.waiters
        }
        guard let pending else { return }
        stderrContinuation.finish()
        for waiter in pending { waiter.resume(returning: .code(0)) }
    }

    func waitUntilExit() async -> ClaudeRemoteForwardExitStatus {
        await withCheckedContinuation { continuation in
            let alreadyExited = state.withLock { current -> Bool in
                guard current.isRunning else { return true }
                current.waiters.append(continuation)
                return false
            }
            if alreadyExited { continuation.resume(returning: .code(0)) }
        }
    }

    func terminate() {
        terminations.withLock { $0 += 1 }
        exit()
    }

    func forceTerminate() { terminate() }
}

private final class RecordingSpawner: ClaudeRemoteHerdrForwardSpawning, @unchecked Sendable {
    struct Failure: Error {}

    let spawnedArgv = Mutex<[[String]]>([])
    let process: FakeForwardProcess
    private let shouldFail: Bool

    init(process: FakeForwardProcess = FakeForwardProcess(), shouldFail: Bool = false) {
        self.process = process
        self.shouldFail = shouldFail
    }

    func spawn(argv: [String]) throws -> any ClaudeRemoteHerdrForwardProcess {
        spawnedArgv.withLock { $0.append(argv) }
        if shouldFail { throw Failure() }
        return process
    }
}

private final class RecordingWorkspaces: ClaudeRemoteHerdrWorkspaceProviding, @unchecked Sendable {
    struct Failure: Error {}

    let made = Mutex<[ClaudeRemoteHerdrForwardWorkspace]>([])
    let removed = Mutex<[ClaudeRemoteHerdrForwardWorkspace]>([])
    private let socketPath: String
    private let shouldFail: Bool

    init(socketPath: String = "/tmp/lvx-herdr-fwd-test/h.sock", shouldFail: Bool = false) {
        self.socketPath = socketPath
        self.shouldFail = shouldFail
    }

    func makeWorkspace() throws -> ClaudeRemoteHerdrForwardWorkspace {
        if shouldFail { throw Failure() }
        let workspace = ClaudeRemoteHerdrForwardWorkspace(
            directoryPath: (socketPath as NSString).deletingLastPathComponent,
            socketPath: socketPath
        )
        made.withLock { $0.append(workspace) }
        return workspace
    }

    func remove(_ workspace: ClaudeRemoteHerdrForwardWorkspace) {
        removed.withLock { $0.append(workspace) }
    }
}

/// Stands in for the whole forward service in resolver tests, so the join arm
/// can be exercised without any notion of processes.
@MainActor
private final class RecordingForwards: ClaudeRemoteHerdrForwarding {
    struct Opened: Equatable {
        var alias: String
        var remoteSocketPath: String
    }

    let opens = Mutex<[Opened]>([])
    let localSocketPath: String
    private let succeeds: Bool
    /// Remote socket labels whose forward fails to open — a stale socket from
    /// a previous herdr boot, still inside the registry TTL.
    private let failingRemoteSocketPaths: Set<String>
    let process = FakeForwardProcess()
    let workspaces = RecordingWorkspaces()

    init(
        succeeds: Bool = true,
        localSocketPath: String = "/tmp/lvx-herdr-fwd-test/h.sock",
        failingRemoteSocketPaths: Set<String> = []
    ) {
        self.succeeds = succeeds
        self.localSocketPath = localSocketPath
        self.failingRemoteSocketPaths = failingRemoteSocketPaths
    }

    func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle? {
        opens.withLock { $0.append(Opened(alias: alias, remoteSocketPath: remoteSocketPath)) }
        guard succeeds, !failingRemoteSocketPaths.contains(remoteSocketPath) else { return nil }
        return ClaudeRemoteHerdrForwardHandle(
            workspace: ClaudeRemoteHerdrForwardWorkspace(
                directoryPath: (localSocketPath as NSString).deletingLastPathComponent,
                socketPath: localSocketPath
            ),
            process: process,
            removeWorkspace: { [workspaces] in workspaces.remove($0) }
        )
    }

    var openCount: Int { opens.withLock { $0.count } }
    var closeCount: Int { workspaces.removed.withLock { $0.count } }
}

private final class RemoteJoinTestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

private final class PanelStatusRecorder: @unchecked Sendable {
    private let values = Mutex<[HerdrPanelConfigurationStatus]>([])
    func append(_ value: HerdrPanelConfigurationStatus) { values.withLock { $0.append(value) } }
    var recorded: [HerdrPanelConfigurationStatus] { values.withLock { $0 } }
}

private final class RemoteJoinSSHConfigRunner: @unchecked Sendable {
    struct Invocation: Equatable {
        let executableURL: URL
        let value: ClaudeRemoteEnrollmentService.Invocation
    }

    enum Failure: Error { case scripted }

    let invocations = Mutex<[Invocation]>([])
    private let outputs: [String: String]
    private let shouldFail: Bool

    init(outputs: [String: String] = [:], shouldFail: Bool = false) {
        self.outputs = outputs
        self.shouldFail = shouldFail
    }

    var run: SSHDestinationCanonicalizer.ProcessRunner {
        { [self] executableURL, invocation in
            invocations.withLock { $0.append(Invocation(executableURL: executableURL, value: invocation)) }
            if shouldFail { throw Failure.scripted }
            guard let operand = invocation.argv.last, let output = outputs[operand] else {
                return ClaudeRemoteEnrollmentService.RunResult(exitCode: 1, message: "")
            }
            return ClaudeRemoteEnrollmentService.RunResult(exitCode: 0, message: output)
        }
    }
}

// MARK: - Resolver: the remote herdr arm

/// A Claude Code session inside a herdr on an ENROLLED REMOTE host.
///
/// The arm's whole safety argument is that four independent bindings all have
/// to agree, and that anything less abstains — so most of this file is the
/// abstention matrix.
@MainActor
final class RemoteHerdrJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let ghostty = TerminalScreenTarget(
        pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let hostID = "h1a2b3c4"
    private let surfaceTTY = "/dev/ttys-outer"
    private let remotePaneID = "pane-remote-7"
    private let remoteSocketPath = "/run/user/1000/herdr/default.sock"

    private var origin: ClaudeTransportOrigin {
        .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
    }

    private func makeRegistry(
        liveness: RemoteJoinTestLiveness = RemoteJoinTestLiveness()
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            now: { [epoch] in epoch },
            isProcessAlive: liveness.probe
        )
    }

    /// One live REMOTE session on `hostID`, reporting a herdr pane.
    @discardableResult
    private func ingestRemoteHerdrSession(
        into registry: ClaudeSessionRegistry,
        sessionID: String = "s-remote-1",
        paneID: String? = nil,
        socketPath: String? = nil,
        hookParentPID: String? = "4711",
        host: String? = nil
    ) -> ClaudeSessionSnapshot? {
        let hostID = host ?? self.hostID
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                hostID: hostID, sessionID: sessionID
            ),
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            process: ClaudeHookProcessInfo(hookPID: 11, claudePID: 12, tty: "/dev/pts/3")
        )
        return registry.ingest(
            record,
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID)),
            environment: ClaudeRemoteSessionEnvironment(
                herdrPaneID: paneID ?? remotePaneID,
                herdrSocketPath: socketPath ?? remoteSocketPath,
                hookParentPID: hookParentPID
            )
        )
    }

    private func enrolledHost(
        id: String? = nil,
        alias: String? = "Builder",
        revoked: Bool = false
    ) -> ClaudeRemoteHost {
        ClaudeRemoteHost(
            id: id ?? hostID,
            label: "builder",
            sshHostAlias: alias,
            createdAt: epoch,
            lastSeenAt: nil,
            revokedAt: revoked ? epoch : nil
        )
    }

    private func focusedPane(
        paneID: String? = nil,
        claim: String? = nil
    ) -> HerdrFocusedPane {
        HerdrFocusedPane(
            paneID: paneID ?? remotePaneID,
            claimedClaudeSessionID: claim
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        panes: HerdrPaneQuerying?,
        forwards: (any ClaudeRemoteHerdrForwarding)?,
        sshResult: SSHDestinationTTYProbeResult = .connection(
            SSHSurfaceConnection(
                destination: "builder",
                hasCompetingHerdrClient: false,
                herdr: .plainClient(sessionSelector: nil)
            )
        ),
        hosts: [ClaudeRemoteHost]? = nil,
        canonicalizer: SSHDestinationCanonicalizer? = nil,
        panelMetadata: (any HerdrPanelMetadataReporting)? = nil,
        panelGrid: String? = nil,
        panelRandomBits: UInt64 = 1,
        panelRandomBitsProvider: HerdrPanelBindingProbe.RandomBits? = nil,
        panelStatuses: PanelStatusRecorder? = nil,
        indicatorSleepFor: @escaping HerdrPanelMicIndicator.SleepFor = { _ in }
    ) -> ClaudeSessionJoinResolver {
        let hostList = hosts ?? [enrolledHost()]
        let fixedNow = epoch
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            // The surface is NOT a local herdr client: that arm has to have
            // declined before this one is even reached.
            herdrClientProbe: { _ in false },
            herdrPanes: panes,
            sshDestinationProbe: { _ in sshResult },
            enrolledHosts: { destination in
                hostList.filter { host in
                    guard !host.isRevoked, let alias = host.sshHostAlias else { return false }
                    return alias.lowercased() == destination.lowercased()
                }
            },
            canonicalizedEnrolledHosts: { destination in
                guard let canonicalizer else { return [] }
                return await canonicalizer.matchingHosts(
                    destination: destination,
                    enrolledHosts: hostList
                )
            },
            speculativeHosts: { hostList },
            remoteHerdrForwards: forwards,
            herdrPanelMetadata: panelMetadata,
            readFocusedGrid: { _ in panelGrid },
            panelNow: { fixedNow },
            panelSleepFor: { _ in },
            panelRandomBits: panelRandomBitsProvider ?? { panelRandomBits },
            indicatorSleepFor: indicatorSleepFor,
            reportPanelStatus: { status in
                panelStatuses?.append(status)
            }
        )
    }

    // MARK: Happy path

    func testPanelBindingIsPrimaryWhenSSHArgvSaysPlainShell() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 7)

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .connection(SSHSurfaceConnection(
                destination: "builder",
                hasCompetingHerdrClient: false,
                herdr: .notHerdr
            )),
            panelMetadata: panes,
            panelGrid: "agents  \(token)",
            panelRandomBits: 7
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertNotNil(join.remoteHerdrIndicator)
        XCTAssertEqual(forwards.openCount, 1, "argv fallback must not open a second forward")
        XCTAssertEqual(panes.panelReports.withLock { $0.first?.value }, token)
    }

    func testUnreadableSSHUsesASpeculativePanelCandidate() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let token = HerdrPanelBindingProbe.token(randomBits: 8)

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: RecordingForwards(),
            sshResult: .undeterminable(.unreadableArguments),
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 8
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
    }

    func testMissingPanelRowFallsBackToTheExistingArgvJoinAndOffersConfiguration() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let statuses = PanelStatusRecorder()

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: "agents panel without the configured row",
            panelStatuses: statuses
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertNil(join.remoteHerdrIndicator, "the argv fallback has no panel lease")
        XCTAssertEqual(forwards.openCount, 2, "the failed primary probe closes before argv fallback")
        XCTAssertEqual(statuses.recorded, [.likelyNotConfigured])
        XCTAssertTrue(
            panes.panelReports.withLock { $0 }.contains { $0.value == nil },
            "a failed stamp/read attempt must clear its short-lived token"
        )
    }

    func testUnavailableGridFallsBackWithoutClaimingThePanelRowIsMissing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let statuses = PanelStatusRecorder()

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: RecordingForwards(),
            panelMetadata: panes,
            panelGrid: nil,
            panelStatuses: statuses
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertTrue(statuses.recorded.isEmpty)
    }

    func testTwoLiveSocketsResolveToTheOneWhoseNonceRenders() async throws {
        // Two herdr servers (or one live plus one stale registration) on one
        // host used to abstain outright. The nonce disambiguates: each socket
        // is stamped with its own fresh token, and only the displayed server
        // can render its token in the focused grid.
        let registry = makeRegistry()
        _ = ingestRemoteHerdrSession(
            into: registry, sessionID: "s-remote-1", socketPath: "/run/a.sock"
        )
        _ = ingestRemoteHerdrSession(
            into: registry, sessionID: "s-remote-2", socketPath: "/run/b.sock"
        )
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        var bits: [UInt64] = [5, 6]
        let secondToken = HerdrPanelBindingProbe.token(randomBits: 6)

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: "agents  \(secondToken)",
            panelRandomBitsProvider: { bits.removeFirst() }
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(
            forwards.opens.withLock { $0.map(\.remoteSocketPath) },
            ["/run/a.sock", "/run/b.sock"],
            "sockets are probed in sorted order until one's nonce renders"
        )
        XCTAssertEqual(
            join.snapshot.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-remote-2"),
            "the join must bind the session of the socket whose nonce rendered"
        )
    }

    func testAStaleSocketWhoseForwardFailsIsSkipped() async throws {
        // The exact field shape (2026-08-09): a session registered under a
        // previous herdr boot lingers inside the registry TTL with a socket
        // that no longer exists. Its forward fails; the live socket wins.
        let registry = makeRegistry()
        _ = ingestRemoteHerdrSession(
            into: registry, sessionID: "s-remote-1", socketPath: "/run/a.sock"
        )
        _ = ingestRemoteHerdrSession(
            into: registry, sessionID: "s-remote-2", socketPath: "/run/b.sock"
        )
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards(failingRemoteSocketPaths: ["/run/a.sock"])
        let token = HerdrPanelBindingProbe.token(randomBits: 6)

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: "agents  \(token)",
            panelRandomBits: 6
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(forwards.openCount, 2)
        XCTAssertEqual(
            panes.panelReports.withLock { $0.count }, 1,
            "the stale socket must never be stamped — its forward already failed"
        )
    }

    func testASpeculativeSettleTimeoutDoesNotClaimTheRowIsMissing() async {
        // A speculative candidate's token not rendering usually means the user
        // is not looking at THAT server. Diagnosing "row likely not
        // configured" from it would nag a correctly configured host.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let statuses = PanelStatusRecorder()

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: RecordingForwards(),
            sshResult: .undeterminable(.refusedArguments),
            panelMetadata: panes,
            panelGrid: "agents panel showing some other server",
            panelStatuses: statuses
        ).resolve(target: ghostty)

        XCTAssertNil(join, "unreadable ssh with no panel match suppresses every fallback")
        XCTAssertTrue(statuses.recorded.isEmpty)
    }

    func testUnreadableSSHSpeculationIsHardBoundedToThreeHosts() async {
        let registry = makeRegistry()
        let hosts = (1...4).map { index in
            let id = "hpanel\(index)"
            ingestRemoteHerdrSession(
                into: registry,
                sessionID: "s-\(index)",
                paneID: remotePaneID,
                host: id
            )
            return enrolledHost(id: id, alias: "builder\(index)")
        }
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .undeterminable(.unreadableArguments),
            hosts: hosts,
            panelMetadata: panes,
            panelGrid: "no rendered token"
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 3)
        XCTAssertEqual(Set(forwards.opens.withLock { $0.map(\.alias) }).count, 3)
    }

    func testTwoSpeculativeHostsWhoseDistinctTokensBothRenderAbstain() async {
        let registry = makeRegistry()
        let hosts = [
            enrolledHost(id: "hpanel1", alias: "builder1"),
            enrolledHost(id: "hpanel2", alias: "builder2"),
        ]
        ingestRemoteHerdrSession(into: registry, sessionID: "s-1", host: hosts[0].id)
        ingestRemoteHerdrSession(into: registry, sessionID: "s-2", host: hosts[1].id)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let bits = Mutex<[UInt64]>([21, 22])
        let grid = [21, 22]
            .map { HerdrPanelBindingProbe.token(randomBits: UInt64($0)) }
            .joined(separator: " ")

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .undeterminable(.unreadableArguments),
            hosts: hosts,
            panelMetadata: panes,
            panelGrid: grid,
            panelRandomBitsProvider: { bits.withLock { $0.removeFirst() } }
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 2)
        XCTAssertEqual(forwards.closeCount, 2)
        XCTAssertFalse(
            panes.requests.withLock { $0 }.contains { $0.method == "pane.process_info" },
            "no downstream session confirmation may run after surface ambiguity"
        )
    }

    // MARK: The panel path's pane-level confirmation set
    //
    // The panel nonce authorizes the SURFACE — it proves the focused local
    // window is displaying that herdr server. It never authorizes a SESSION.
    // Three things do that, and every one of them can only CONFIRM:
    //   1. exactly one live candidate of that socket claims the focused pane id
    //      (`paneMatches.count == 1`, asserted by the ambiguity test above),
    //   2. herdr's own `agent_session` claim for the pane does not disagree,
    //   3. the pane is running that session's agent (a published `$PPID`, or a
    //      process named for the agent).
    // Until 2026-09-05 there was a fourth: the pane's captured `terminal_title`
    // had to carry that session's broker-allocated marker. These three tests are
    // what the marker-free set is held to.

    func testPanelAuthorizedJoinConfirmsWithNoTitleAtAll() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        // No `terminal_title` anywhere: `HerdrFocusedPane` has no such field to
        // decode any more, so this is the production shape.
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 23)

        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .connection(.init(
                destination: "builder",
                hasCompetingHerdrClient: false,
                herdr: .notHerdr
            )),
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 23
        ).resolve(target: ghostty))

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(join.herdrPane?.paneID, remotePaneID)
        XCTAssertNotNil(join.remoteHerdrIndicator, "the matched token stays lit as the mic indicator")
        // The argv classification says `.notHerdr`, which the argv FALLBACK
        // would refuse outright — so this join can only have come from the
        // panel binding.
        XCTAssertEqual(forwards.openCount, 1)
        XCTAssertEqual(forwards.closeCount, 0, "a joined forward stays open for the dictation")
    }

    func testPanelAuthorizedJoinRefusesWhenHerdrsOwnSessionClaimDisagrees() async {
        // The reused-pane case: a session died without a SessionEnd, leaving a
        // live registry entry and its pane id behind, and another session now
        // runs in that pane. herdr watches the pane and says so. The marker
        // used to be the second binding that caught this; the claim is now the
        // one that must.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane(claim: "s-somebody-else"))
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 23)

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 23
        ).resolve(target: ghostty)

        XCTAssertNil(join, "a disagreeing agent_session claim resolves to NEITHER session")
        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(
            panes.panelReports.withLock { $0.last?.value }, nil,
            "the nonce is cleared before the forward closes"
        )
    }

    func testPanelAuthorizedJoinRefusesWhenTheAgentIsNotForeground() async {
        // A suspended agent with the user back at the shell. The pane id still
        // names the session and herdr claims nothing, so the foreground list is
        // the only thing left that can refuse.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, hookParentPID: "4711")
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            foreground: HerdrPaneForegroundInfo(
                shellPID: 8000,
                foregroundProcesses: [HerdrForegroundProcess(pid: 8000, name: "zsh")]
            )
        )
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 23)

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 23
        ).resolve(target: ghostty)

        XCTAssertNil(join, "a pane whose agent is not foreground is not this session's pane")
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testEveryBindingAgreeingResolvesARemoteHerdrJoin() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(registry: registry, panes: panes, forwards: forwards)
                .resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(join.herdrPane?.paneID, remotePaneID)
        // The binding names the LOCAL end of the tunnel; the remote path never
        // becomes something this machine dials.
        XCTAssertEqual(join.herdrPane?.socketPath, forwards.localSocketPath)
        // The forward was asked for with the STORED alias (the vetted string),
        // not the lowercased destination the process table reported.
        XCTAssertEqual(
            forwards.opens.withLock { $0 },
            [RecordingForwards.Opened(alias: "Builder", remoteSocketPath: remoteSocketPath)]
        )
        // Every herdr request went to the forwarded socket, and pane queries
        // named only the joined pane.
        let requests = panes.requests.withLock { $0 }
        XCTAssertEqual(requests.map(\.method), ["pane.current", "pane.process_info"])
        XCTAssertTrue(requests.allSatisfy { $0.socketPath == forwards.localSocketPath })
        XCTAssertEqual(requests.compactMap(\.paneID), [remotePaneID])
    }

    func testIPDestinationJoinsHostViaCanonicalSSHConfig() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let config = """
            host 192.168.1.167
            user dev
            hostname 192.168.1.167
            port 22
            """
        let runner = RemoteJoinSSHConfigRunner(
            outputs: ["192.168.1.167": config, "Builder": config]
        )
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: panes,
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "192.168.1.167",
                        hasCompetingHerdrClient: false,
                        herdr: .plainClient(sessionSelector: nil)
                    )
                ),
                canonicalizer: canonicalizer
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(Set(runner.invocations.withLock { $0.map(\.value.argv) }), [
            ["ssh", "-G", "--", "192.168.1.167"],
            ["ssh", "-G", "--", "Builder"],
        ])
        XCTAssertTrue(
            runner.invocations.withLock { invocations in
                invocations.allSatisfy {
                    $0.executableURL.path == "/usr/bin/ssh"
                        && $0.value.standardInput.isEmpty
                        && $0.value.timeout == SSHDestinationCanonicalizer.defaultTimeout
                }
            }
        )
    }

    func testCanonicalizationFailureKeepsExactMatchFallthroughBehavior() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let runner = RemoteJoinSSHConfigRunner(shouldFail: true)
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "192.168.1.167",
                    hasCompetingHerdrClient: false,
                    herdr: .plainClient(sessionSelector: nil)
                )
            ),
            canonicalizer: canonicalizer).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertEqual(runner.invocations.withLock { $0.count }, 1)
    }

    func testCanonicalMatchToTwoEnrolledHostsKeepsAmbiguityFatal() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let config = "user dev\nhostname 192.168.1.167\nport 22\n"
        let runner = RemoteJoinSSHConfigRunner(outputs: [
            "192.168.1.167": config,
            "sandbox-vpn": config,
            "sandbox-lan": config,
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "192.168.1.167",
                    hasCompetingHerdrClient: false,
                    herdr: .plainClient(sessionSelector: nil)
                )
            ),
            hosts: [
                enrolledHost(alias: "sandbox-vpn"),
                enrolledHost(id: "h9z9z9z9", alias: "sandbox-lan"),
            ],
            canonicalizer: canonicalizer).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertEqual(runner.invocations.withLock { $0.count }, 3)
    }

    func testExactMatchNeverInvokesCanonicalizer() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let runner = RemoteJoinSSHConfigRunner(shouldFail: true)
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: RecordingForwards(),
                canonicalizer: canonicalizer
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertTrue(runner.invocations.withLock { $0.isEmpty })
    }

    func testAJoinedRemoteSessionStaysLiveAtCommit() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let resolver = resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: RecordingForwards()
        )
        let join = try unwrapAsync(await resolver.resolve(target: ghostty))
        XCTAssertTrue(resolver.isStillLive(join))
    }

    // MARK: Fallthrough — the arm does not apply

    func testNoSSHClientOnTheSurfaceMeansTheArmNeverApplies() async throws {
        // The strong version of this pin: the panel machinery is fully wired
        // and a grid that WOULD match is on screen — a local shell must still
        // never stamp, never open a forward, and never pay remote latency.
        // (A weaker version passed with panel metadata absent, which proved
        // only that a disabled panel does not probe.)
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let token = HerdrPanelBindingProbe.token(randomBits: 7)

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .noSSHClient,
            panelMetadata: panes,
            panelGrid: "agents  \(token)",
            panelRandomBits: 7
        ).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertNil(panes.panelReports.withLock { $0.first })
    }

    func testUnreadableSSHOnTheSurfaceJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .undeterminable(.multipleForegroundClients)
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testEveryPresentButUnreadableSSHCategoryJoinsNothing() async {
        let causes: [SSHProbeIndeterminacy] = [
            .multipleForegroundClients,
            .untrustedExecutable,
            .unreadableArguments,
            .refusedArguments,
        ]
        for cause in causes {
            let registry = makeRegistry()
            ingestRemoteHerdrSession(into: registry)
            let join = await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: RecordingForwards(),
                sshResult: .undeterminable(cause)).resolve(target: ghostty)
            XCTAssertNil(join, "\(cause.rawValue) leaves nothing that can identify this surface")
        }
    }

    func testProbeWideIndeterminacyStillLetsALocalTTYJoinAnswer() async throws {
        let causes: [SSHProbeIndeterminacy] = [
            .deviceUnreadable,
            .tableUnreadable,
            .probeUnavailable,
        ]
        for cause in causes {
            let registry = makeRegistry()
            ingestRemoteHerdrSession(into: registry)
            let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: RecordingForwards(),
            sshResult: .undeterminable(cause)).resolve(target: ghostty)
            XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        }
    }

    func testSSHToAnUnenrolledHostJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "someone-elses-box",
                    hasCompetingHerdrClient: false,
                    herdr: .plainClient(sessionSelector: nil)
                )
            )).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testARevokedHostIsNotAnEnrolledHost() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            hosts: [enrolledHost(revoked: true)]).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testEnrolledHostWithNoHerdrSessionsJoinsNothing() async throws {
        // A plain remote Claude session on an enrolled host. Nothing about
        // this surface says which session it displays, and the arm must not
        // invent one — the host being enrolled is not a binding.
        let registry = makeRegistry()
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-plain"),
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            process: ClaudeHookProcessInfo(hookPID: 11, claudePID: 12)
        )
        registry.ingest(record, origin: origin)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testALocalSessionOnTheSamePaneIDIsNeverARemoteCandidate() async throws {
        // The local and remote pane identities live in different snapshot
        // fields precisely so this cannot happen (PR #216).
        let registry = makeRegistry()
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "s-local",
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            process: ClaudeHookProcessInfo(
                hookPID: 11,
                claudePID: 9001,
                tty: "/dev/ttys-inner",
                herdrPaneID: remotePaneID,
                herdrSocketPath: remoteSocketPath
            )
        )
        registry.ingest(record, origin: .localAuthenticated(peerUID: 501))
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards
        ).resolve(target: ghostty)

        // No remote candidates ⇒ the arm never applies ⇒ no join.
        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 0)
    }

    // MARK: Abstention — bound to a remote herdr, and still no join

    func testTwoEnrolledHostsSharingTheDestinationJoinNothing() async throws {
        // Ambiguous enrollment says nothing about THIS terminal being a herdr
        // surface. The arm declines rather than picking one of the matching
        // hosts (review blocker 1c).
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            hosts: [enrolledHost(), enrolledHost(id: "h9z9z9z9")]).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testTwoLiveHerdrSocketsOnTheHostJoinNothingOnTheArgvPath() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-a")
        ingestRemoteHerdrSession(
            into: registry, sessionID: "s-b", paneID: "pane-other",
            socketPath: "/run/user/1000/herdr/second.sock"
        )
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testForwardSpawnFailureIssuesNoHerdrQueryAndJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards(succeeds: false)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())

        let join = await resolver(
            registry: registry, panes: panes, forwards: forwards
        ).resolve(target: ghostty)

        // Nothing about this connection was ever confirmed (review round 3,
        // blocker 1b) — and there is nothing weaker left to try.
        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 1)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testMissingForwardCapabilityJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: nil).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
    }

    func testMissingPaneQueryCapabilityOpensNoForwardAndJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry, panes: nil, forwards: forwards
        ).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testTwoSessionsClaimingTheFocusedPaneNeverJoinThatPane() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-a")
        ingestRemoteHerdrSession(into: registry, sessionID: "s-b")
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards).resolve(target: ghostty)

        // The pane could name either session, so it names neither.
        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testForegroundQueryUnavailableAbstains() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(), foreground: nil),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testForegroundDetectionUnavailableAbstains() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(
                focused: focusedPane(),
                foreground: HerdrPaneForegroundInfo(shellPID: 8000, foregroundProcesses: nil)
            ),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(join)
    }

    func testAgentNotInTheForegroundAbstains() async throws {
        // The user suspended Claude Code and is back at the shell: the pane is
        // still "theirs", and its context is still not what they are dictating
        // into.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(
                focused: focusedPane(),
                foreground: HerdrPaneForegroundInfo(
                    shellPID: 8000,
                    foregroundProcesses: [HerdrForegroundProcess(pid: 8000, name: "zsh")]
                )
            ),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: The connection-level bind (review blocker 1)

    func testACompetingHerdrViewStopsTheArm() async throws {
        // THE blocker: terminal A is a plain shell to `builder`, terminal B is
        // attached to herdr on `builder`. Dictating in A must not query B's
        // herdr and must not join B's session.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "builder",
                    hasCompetingHerdrClient: true,
                    herdr: .plainClient(sessionSelector: nil)
                )
            )).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0, "no tunnel may be opened for an unbound connection")
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty }, "no herdr query may be issued")
    }

    func testTheHerdrArgvSignalNeverOverridesACompetingHerdrView() async throws {
        // The surface naming herdr does not settle WHICH herdr view it
        // displays: with a possible client of a different herdr server on
        // another tty (different --session selector, a single-pane attach, or
        // an unreadable argv), the probe reports competition and the arm must
        // stand down (review round 3, blocker 1a, narrowed 2026-08-06).
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "builder",
                    hasCompetingHerdrClient: true,
                    herdr: .plainClient(sessionSelector: nil)
                )
            )).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testAPlainSSHSessionNeverReachesTheArmEvenAsTheSoleConnection() async throws {
        // Review round 5b, major 1. Being the only connection says nothing
        // about what this terminal DISPLAYS: a herdr whose client detached —
        // or whose pane still runs an agent inside the registry TTL — keeps
        // answering `pane.current` with that pane, so a later plain
        // `ssh builder` would join a session the user cannot see.
        //
        // herdr exposes no read-only attachment signal (verified against the
        // 0.7.5 socket schema and the 0.8.0 docs: the only `client.*` methods
        // are `window_title.set`/`clear`, both mutations), so the evidence has
        // to be the invocation itself.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "builder",
                    hasCompetingHerdrClient: false,
                    herdr: .notHerdr
                )
            )).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        // And it costs NOTHING: no tunnel spawned, no herdr dialled. This is
        // also the answer to the round-5b UX finding — a plain sole ssh to an
        // enrolled host no longer pays a forward before falling through.
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testTheManualHerdrFlowGetsNoHerdrJoin() async throws {
        // The documented, accepted limitation: `ssh host`, then typing `herdr`,
        // leaves no trace in argv, so the arm cannot bind and no join happens
        // — unless the agents-panel nonce renders, which is the primary path
        // and is not exercised here. Since the title arm was removed
        // (2026-09-05) this residual is total: no context at all for that
        // surface, which the owner accepted.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "builder",
                    hasCompetingHerdrClient: false,
                    herdr: .notHerdr
                )
            )
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testAUniqueConnectionThatNamesHerdrJoins() async throws {
        // The positive case for the pair of requirements: BOTH the herdr
        // invocation and uniqueness, which is what a join takes since round 5b.
        // (This comment used to say the signal was "not required" — it is.)
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "builder",
                        hasCompetingHerdrClient: false,
                        herdr: .plainClient(sessionSelector: nil)
                    )
                )
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(forwards.openCount, 1)
    }

    // MARK: herdr-or-nothing starts at CONFIRMATION (review round 3, blocker 1b)

    func testASolePlainSSHJoinsNothingWhenThePaneIsNotOurs() async throws {
        // The rule this pins: registry candidates EXISTING on the host is not
        // a binding for THIS connection. A lone ssh session to an enrolled host
        // that happens to run a detached herdr — or whose herdr sessions are
        // merely still inside their TTL — must not be joined to a pane it is
        // not displaying.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            // The herdr's focused pane belongs to something else entirely.
            panes: RemoteJoinHerdrPanes(focused: focusedPane(paneID: "pane-someone-else")),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        // The tunnel was opened to ask, and closed once the answer was "not
        // this connection".
        XCTAssertEqual(forwards.openCount, 1)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAnUnreachableHerdrJoinsNothing() async throws {
        // Same rule, earlier failure: a detached herdr that answers nothing.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: nil),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAFailedForwardJoinsNothing() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards(succeeds: false)

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(
            join,
            "the remote-herdr arm declines; no weaker arm remains to answer for this surface"
        )
    }

    func testAPaneWhoseAgentIsNotForegroundJoinsNOTHING() async throws {
        // The pane id matched, so this IS the pane the connection displays —
        // and a fail-closed check then refused it. There is nothing weaker to
        // fall back to, and there never should have been: a surface bound to a
        // remote herdr shows an inner pane, which no other arm can describe.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(
                focused: focusedPane(),
                foreground: HerdrPaneForegroundInfo(
                    shellPID: 8000,
                    foregroundProcesses: [HerdrForegroundProcess(pid: 8000, name: "zsh")]
                )
            ),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: herdr's own session claim (review finding 3)

    func testAContradictoryPaneSessionClaimAbstains() async throws {
        // Stale-session scenario: session A died without a SessionEnd, leaving
        // a live registry entry and its pane id; session B now runs in that
        // reused pane. herdr — which watches the pane — says B, and the pane id
        // still says A. That resolves to NEITHER.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-stale-a")
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(claim: "s-live-b")),
            forwards: forwards).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAnAgreeingPaneSessionClaimJoins() async throws {
        // The same check must CONFIRM when herdr agrees. The claim is herdr's
        // RAW session id; the registry speaks host- and agent-scoped ids.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-remote-1")

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane(claim: "s-remote-1")),
                forwards: RecordingForwards()
            ).resolve(target: ghostty)
        )
        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
    }

    func testARemoteSessionClaimIsScopedByHostBeforeComparison() {
        // A raw id from herdr can only match once it is put in the registry's
        // namespace — a bare "s-1" must never equal the stored scoped id by
        // accident, and a claim scoped to ANOTHER host must never match.
        XCTAssertEqual(
            ClaudeSessionJoinResolver.scopedRemoteSessionID(
                claimed: "s-1", hostID: hostID, agent: .claude
            ),
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-1")
        )
        XCTAssertNotEqual(
            ClaudeSessionJoinResolver.scopedRemoteSessionID(
                claimed: "s-1", hostID: "h00000000", agent: .claude
            ),
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-1")
        )
    }

    // MARK: Two labelled sessions on one socket

    func testTwoSessionsInDIFFERENTPanesJoinTheFocusedOne() async throws {
        // Two Claude sessions in two herdr panes is the normal multiplexer
        // workflow. The focused pane id selects exactly one candidate, and the
        // fail-closed cross-checks then have to agree with THAT candidate —
        // nothing here is a "pick" that could land on the other session.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-other", paneID: "pane-other")
        ingestRemoteHerdrSession(into: registry, sessionID: "s-remote-1")

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: RecordingForwards()
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(
            join.snapshot.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-remote-1")
        )
    }

    /// The residual the marker removal makes explicit, stated as behaviour.
    ///
    /// A pane id is a label the enrolled host chose, so a compromised host CAN
    /// publish another session's. The broker-allocated marker in the pane's
    /// captured title used to be the second, unforgeable binding that caught
    /// exactly this; it is gone (owner decision 2026-09-05). What still catches
    /// a forger is herdr itself — the party that watches the pane — through its
    /// `agent_session` claim and the pane's foreground process list. Both are
    /// asserted here, and the second half of this test is the honest statement
    /// of what is NOT caught: a forger on a pane herdr claims nothing about,
    /// running a process named for the agent, is indistinguishable from the
    /// real occupant and does join.
    func testASessionForgingAnotherPaneIDIsRefusedByHerdrsOwnClaim() async {
        let registry = makeRegistry()
        // The forger reports the focused pane's id...
        ingestRemoteHerdrSession(into: registry, sessionID: "s-forger")
        // ...and herdr says that pane belongs to somebody else.
        let panes = RemoteJoinHerdrPanes(focused: focusedPane(claim: "s-real-occupant"))
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry, panes: panes, forwards: forwards
        ).resolve(target: ghostty)

        XCTAssertNil(join, "herdr's own claim disagrees, so the join resolves to NEITHER")
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testASessionForgingAnotherPaneIDIsRefusedByTheForegroundCheck() async {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-forger", hookParentPID: "4711")
        // herdr claims nothing about the pane (the common field shape — see
        // docs/agent/remote-herdr-panel-binding.md, "Pinned against a live
        // server"), so the foreground list carries the weight: the pane is at a
        // shell, not running the forger's agent.
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            foreground: HerdrPaneForegroundInfo(
                shellPID: 8000,
                foregroundProcesses: [HerdrForegroundProcess(pid: 8000, name: "zsh")]
            )
        )
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry, panes: panes, forwards: forwards
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: The foreground cross-check's two signals

    func testHookParentPIDMatchJoinsEvenWhenTheProcessIsNamedNode() async throws {
        // An npm-installed Claude Code is `node` in the process table. The
        // published `$PPID` is the other half of the same question.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, hookParentPID: "4711")
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            foreground: HerdrPaneForegroundInfo(
                shellPID: 8000,
                foregroundProcesses: [HerdrForegroundProcess(pid: 4711, name: "node")]
            )
        )

        let join = try unwrapAsync(
            await resolver(registry: registry, panes: panes, forwards: RecordingForwards())
                .resolve(target: ghostty)
        )
        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
    }

    func testAgentNameMatchJoinsWhenNoHookParentPIDWasPublished() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, hookParentPID: nil)
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            foreground: HerdrPaneForegroundInfo(
                shellPID: 8000,
                foregroundProcesses: [HerdrForegroundProcess(pid: 1234, name: "/usr/local/bin/claude")]
            )
        )

        let join = try unwrapAsync(
            await resolver(registry: registry, panes: panes, forwards: RecordingForwards())
                .resolve(target: ghostty)
        )
        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
    }

    func testAHookParentPIDIsComparedAsAStringNotANumber() throws {
        // A remote pid is a number in another machine's namespace: a snapshot
        // reporting "0x1247" must not match pid 4711 by some numeric coercion.
        let registry = makeRegistry()
        let snapshot = try unwrapAsync(
            ingestRemoteHerdrSession(into: registry, hookParentPID: "0x1247")
        )
        XCTAssertFalse(
            ClaudeSessionJoinResolver.remoteAgentIsForeground(
                snapshot: snapshot,
                foregroundProcesses: [HerdrForegroundProcess(pid: 4711, name: "node")]
            )
        )
    }

    // MARK: Defaults

    func testADefaultResolverNeverProbesTheProcessTableOrForwardsAnything() async throws {
        // The un-injected seams must leave the arm entirely inert, exactly like
        // the local herdr probe's default.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            herdrPanes: RemoteJoinHerdrPanes(focused: focusedPane())
        )
        let join = await resolver.resolve(target: ghostty)
        XCTAssertNil(join)
    }

    // MARK: Downstream consequences of the mechanism

    func testARemoteHerdrJoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let resolver = resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: RecordingForwards()
        )
        let join = try unwrapAsync(await resolver.resolve(target: ghostty))
        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: resolver, currentJoin: { join }
        )
        // Same window, same target, live session — and still refused, because
        // the AX grid is the composite herdr TUI (here, of another machine).
        XCTAssertFalse(authorizer.isAuthorized(target: ghostty, windowID: 101))
    }

    func testARemoteHerdrJoinHasNoLocalWorkspaceToCollectARepoFrom() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: RecordingForwards()
            ).resolve(target: ghostty)
        )
        // The remote cwd is a label; there is no type that could carry it to
        // the filesystem, and the repo collector takes only the type that can.
        XCTAssertNil(join.localWorkspacePath)
        XCTAssertNil(join.snapshot.localWorkspacePath)
    }

    func testTheJoinValueExposesNoWayToReleaseItsForward() async throws {
        // Ownership lives in the view model, not in the value that travels
        // (review finding 4). This test is the compile-time half of that: the
        // handle is reachable for INSPECTION only, and closing it is not part
        // of the join's API.
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards
            ).resolve(target: ghostty)
        )
        XCTAssertNotNil(join.remoteHerdrForward)
        XCTAssertEqual(forwards.closeCount, 0)
    }

    // MARK: Forward ownership (review finding 4)

    /// A resolved remote herdr join, with the fake forwards that produced it.
    private func makeJoinWithForward() async throws -> (ClaudeSessionJoin, RecordingForwards) {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards
            ).resolve(target: ghostty)
        )
        return (join, forwards)
    }

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.RemoteHerdrJoinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    /// DictationViewModel owns app-lifetime services; retaining test instances
    /// for the process duration keeps teardown from racing service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    func testAnAbortedConnectClosesTheTunnel() async throws {
        // The abort path never reaches stopped-session cleanup, so before this
        // the ssh child stayed up for the rest of the app's life.
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.claudeSessionJoin = join
        viewModel.retainRemoteHerdrForward(of: join)
        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 1)

        viewModel.abortConnectingSession()

        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 0)
    }

    func testDiscardingTheStartCaptureClosesTheTunnel() async throws {
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.claudeSessionJoin = join
        viewModel.retainRemoteHerdrForward(of: join)

        viewModel.discardTerminalScreenCapture()

        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testTheTunnelIsStillOwnedAfterTheCommitPathConsumesTheJoin() async throws {
        // The quit-during-polish hole: the commit path takes the join, so an
        // owner that reached the child through `claudeSessionJoin` found nil
        // and the ssh survived app exit.
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.claudeSessionJoin = join
        viewModel.retainRemoteHerdrForward(of: join)

        let consumed = viewModel.consumeClaudeSessionJoin()
        XCTAssertNotNil(consumed)
        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(forwards.closeCount, 0, "the stop-side pane read still needs it")

        // What `applicationWillTerminate` now does.
        viewModel.closeRemoteHerdrForwards()

        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testClosingTunnelsIsIdempotentAndSurvivesHavingNone() async throws {
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.retainRemoteHerdrForward(of: join)

        viewModel.closeRemoteHerdrForwards()
        viewModel.closeRemoteHerdrForwards()
        viewModel.discardTerminalScreenCapture()

        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
    }

    func testClosingAPanelAuthorizedJoinClearsItsTokenAndClosesItsForward() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 31)
        let (ticks, tickContinuation) = AsyncStream.makeStream(of: Void.self)
        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 31,
            indicatorSleepFor: { _ in
                var iterator = ticks.makeAsyncIterator()
                _ = await iterator.next()
            }
        ).resolve(target: ghostty))
        let indicator = try XCTUnwrap(join.remoteHerdrIndicator)
        let viewModel = makeViewModel()

        viewModel.retainRemoteHerdrForward(of: join)
        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 1)
        XCTAssertEqual(
            viewModel.liveRemoteHerdrIndicators,
            [indicator],
            "the view model must retain the indicator owner, not only its raw forward"
        )
        viewModel.closeRemoteHerdrForwards()
        await indicator.stopAndWait()
        tickContinuation.finish()

        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 0)
        XCTAssertTrue(
            panes.panelReports.withLock { $0 }.contains {
                $0.socketPath == forwards.localSocketPath
                    && $0.paneID == remotePaneID
                    && $0.value == nil
                    && $0.ttl == nil
            },
            "view-model teardown must explicitly clear the retained panel token"
        )
        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
    }

    func testAJoinWithNoTunnelIsNotRetained() {
        let viewModel = makeViewModel()
        viewModel.retainRemoteHerdrForward(of: nil)
        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 0)
    }

    // MARK: Pane screen context over the forward

    func testRemoteHerdrPaneTextIsCapturedAtStartAndReconciledAtStop() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            texts: ["cargo test\nerror[E0432]: unresolved import", nil]
        )
        let forwards = RecordingForwards()
        let resolver = resolver(registry: registry, panes: panes, forwards: forwards)
        let join = try unwrapAsync(await resolver.resolve(target: ghostty))

        let start = await SocketPaneScreenContext.captureAtStart(
            join: join,
            resolver: resolver,
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
        let capture = try unwrapAsync(start)
        XCTAssertEqual(capture.paneKey, remotePaneID)
        XCTAssertTrue(capture.text.contains("E0432"))
        // The read went over the tunnel, for the joined pane only.
        let read = try unwrapAsync(panes.requests.withLock { $0.last })
        XCTAssertEqual(read.method, "pane.read")
        XCTAssertEqual(read.socketPath, forwards.localSocketPath)
        XCTAssertEqual(read.paneID, remotePaneID)

        // A failed stop re-read falls back to the composite-AX decision, which
        // for any herdr join is vocabulary-only at best.
        let fallback = TerminalScreenContextDecision.vocabularyOnly(
            startText: "composite AX text", cause: .rawUnauthorized
        )
        let decision = await SocketPaneScreenContext.reconcileAtStop(
            start: capture,
            join: join,
            resolver: resolver,
            fallback: fallback,
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
        XCTAssertEqual(decision, fallback)
    }

    func testRemoteHerdrPaneTextIsNotCapturedWhenTheScreenSettingIsOff() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(
            focused: focusedPane(), texts: ["secret pane text"]
        )
        let resolver = resolver(registry: registry, panes: panes, forwards: RecordingForwards())
        let join = try unwrapAsync(await resolver.resolve(target: ghostty))
        let requestsBefore = panes.requests.withLock { $0.count }

        let start = await SocketPaneScreenContext.captureAtStart(
            join: join,
            resolver: resolver,
            settingEnabled: false,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )

        XCTAssertNil(start)
        // Gated BEFORE the socket, not after: a withheld consent must not
        // produce a request at all.
        XCTAssertEqual(panes.requests.withLock { $0.count }, requestsBefore)
    }

    // MARK: Registry filters

    func testLiveRemoteHerdrSessionsFiltersByHostOriginAndEnvironment() throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry, sessionID: "s-a")
        // Another host entirely.
        ingestRemoteHerdrSession(into: registry, sessionID: "s-b", host: "h99999999")
        // Same host, no herdr environment.
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                    hostID: hostID, sessionID: "s-plain"
                ),
                timestamp: epoch.timeIntervalSince1970
            ),
            origin: origin
        )
        // A local session naming the same pane.
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s-local",
                timestamp: epoch.timeIntervalSince1970,
                process: ClaudeHookProcessInfo(
                    hookPID: 1,
                    claudePID: 2,
                    herdrPaneID: remotePaneID,
                    herdrSocketPath: remoteSocketPath
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        )

        let candidates = registry.liveRemoteHerdrSessions(hostID: hostID)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(
            candidates.first?.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-a")
        )
        XCTAssertTrue(registry.liveRemoteHerdrSessions(hostID: "h00000000").isEmpty)
    }

    func testAHerdrEnvironmentWithNoSocketPathIsNotACandidate() throws {
        let registry = makeRegistry()
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                    hostID: hostID, sessionID: "s-half"
                ),
                timestamp: epoch.timeIntervalSince1970
            ),
            origin: origin,
            environment: ClaudeRemoteSessionEnvironment(herdrPaneID: remotePaneID)
        )
        XCTAssertTrue(registry.liveRemoteHerdrSessions(hostID: hostID).isEmpty)
    }
}
#endif
