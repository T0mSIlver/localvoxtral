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
private final class RemoteJoinHerdrPanes: HerdrPaneQuerying, @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var socketPath: String
        var paneID: String?
    }

    let requests = Mutex<[Request]>([])
    private let focused: HerdrFocusedPane?
    private let foreground: HerdrPaneForegroundInfo?
    private let visibleTexts = Mutex<[String?]>([])

    init(
        focused: HerdrFocusedPane?,
        foreground: HerdrPaneForegroundInfo? = HerdrPaneForegroundInfo(
            shellPID: 8000, foregroundProcesses: [HerdrForegroundProcess(pid: 9001, name: "claude")]
        ),
        texts: [String?] = []
    ) {
        self.focused = focused
        self.foreground = foreground
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
}

private final class FakeForwardProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    private let state = Mutex(true)
    let terminations = Mutex(0)

    init(running: Bool = true) {
        state.withLock { $0 = running }
    }

    var isRunning: Bool { state.withLock { $0 } }

    func exit() { state.withLock { $0 = false } }

    func terminate() {
        terminations.withLock { $0 += 1 }
        state.withLock { $0 = false }
    }
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
private final class RecordingForwards: ClaudeRemoteHerdrForwarding, @unchecked Sendable {
    struct Opened: Equatable {
        var alias: String
        var remoteSocketPath: String
    }

    let opens = Mutex<[Opened]>([])
    let localSocketPath: String
    private let succeeds: Bool
    let process = FakeForwardProcess()
    let workspaces = RecordingWorkspaces()

    init(succeeds: Bool = true, localSocketPath: String = "/tmp/lvx-herdr-fwd-test/h.sock") {
        self.succeeds = succeeds
        self.localSocketPath = localSocketPath
    }

    func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle? {
        opens.withLock { $0.append(Opened(alias: alias, remoteSocketPath: remoteSocketPath)) }
        guard succeeds else { return nil }
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
    private let markerValue = "lvx-abc123"

    private var origin: ClaudeTransportOrigin {
        .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
    }

    private func makeRegistry(
        markers: [String] = [],
        liveness: RemoteJoinTestLiveness = RemoteJoinTestLiveness()
    ) -> ClaudeSessionRegistry {
        let queue = Mutex(markers)
        return ClaudeSessionRegistry(
            now: { [epoch] in epoch },
            isProcessAlive: liveness.probe,
            allocateMarkerValue: {
                queue.withLock { queue in
                    queue.isEmpty ? ClaudeSessionRegistry.defaultMarkerValue() : queue.removeFirst()
                }
            }
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
        title: String? = nil,
        claim: String? = nil
    ) -> HerdrFocusedPane {
        HerdrFocusedPane(
            paneID: paneID ?? remotePaneID,
            claimedClaudeSessionID: claim,
            terminalTitle: title ?? markerValue
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        panes: HerdrPaneQuerying?,
        forwards: (any ClaudeRemoteHerdrForwarding)?,
        sshResult: SSHDestinationTTYProbeResult = .connection(
            SSHSurfaceConnection(
                destination: "builder", isOnlyConnectionToDestination: true, indicatesHerdr: true
            )
        ),
        hosts: [ClaudeRemoteHost]? = nil,
        title: String? = nil
    ) -> ClaudeSessionJoinResolver {
        let hostList = hosts ?? [enrolledHost()]
        return ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                guard let title, let marker = ClaudeMarkerTitleParser.marker(inTitle: title) else {
                    return nil
                }
                return TerminalScreenAXReader.FocusedWindowMarkerRead(marker: marker, windowID: 101)
            },
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
            remoteHerdrForwards: forwards
        )
    }

    // MARK: Happy path

    func testEveryBindingAgreeingResolvesARemoteHerdrJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
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
        XCTAssertEqual(join.marker.value, markerValue)
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

    func testAJoinedRemoteSessionStaysJoinableByItsMarkerAtCommit() async throws {
        let registry = makeRegistry(markers: [markerValue])
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

    func testNoSSHClientOnTheSurfaceFallsThroughToTheTitleMarker() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                sshResult: .noSSHClient,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testUndeterminableSSHDestinationFallsThroughToTheTitleMarker() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                sshResult: .undeterminable,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testSSHToAnUnenrolledHostFallsThroughToTheTitleMarker() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "someone-elses-box",
                        isOnlyConnectionToDestination: true,
                        indicatesHerdr: true
                    )
                ),
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testARevokedHostIsNotAnEnrolledHost() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                hosts: [enrolledHost(revoked: true)],
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testEnrolledHostWithNoHerdrSessionsFallsThroughToTheTitleMarker() async throws {
        // A plain remote Claude session on an enrolled host: it joined by
        // marker before this feature existed and must keep doing so.
        let registry = makeRegistry(markers: [markerValue])
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-plain"),
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            process: ClaudeHookProcessInfo(hookPID: 11, claudePID: 12)
        )
        registry.ingest(record, origin: origin)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testALocalSessionOnTheSamePaneIDIsNeverARemoteCandidate() async throws {
        // The local and remote pane identities live in different snapshot
        // fields precisely so this cannot happen (PR #216).
        let registry = makeRegistry(markers: [markerValue])
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

        // No remote candidates ⇒ the arm never applies ⇒ marker arm, which has
        // no title to read here.
        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 0)
    }

    // MARK: Abstention — bound to a remote herdr, and still no join

    func testTwoEnrolledHostsSharingTheDestinationFallThroughToTheTitleMarker() async throws {
        // Ambiguous enrollment says nothing about THIS terminal being a herdr
        // surface, so it must not cost a plain remote session the marker join
        // it has always had (review blocker 1c).
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                hosts: [enrolledHost(), enrolledHost(id: "h9z9z9z9")],
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testTwoLiveHerdrSocketsOnTheHostFallThroughToTheTitleMarker() async throws {
        let registry = makeRegistry(markers: [markerValue, "lvx-def456"])
        ingestRemoteHerdrSession(into: registry, sessionID: "s-a")
        ingestRemoteHerdrSession(
            into: registry, sessionID: "s-b", paneID: "pane-other",
            socketPath: "/run/user/1000/herdr/second.sock"
        )
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testForwardSpawnFailureIssuesNoHerdrQueryAndKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards(succeeds: false)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())

        let join = try unwrapAsync(
            await resolver(
                registry: registry, panes: panes, forwards: forwards, title: markerValue
            ).resolve(target: ghostty)
        )

        // Nothing about this connection was ever confirmed, so the outer marker
        // keeps its chance (review round 3, blocker 1b).
        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 1)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testMissingForwardCapabilityKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: nil,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
    }

    func testMissingPaneQueryCapabilityOpensNoForwardAndKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry, panes: nil, forwards: forwards, title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testTwoSessionsClaimingTheFocusedPaneNeverJoinThatPane() async throws {
        let registry = makeRegistry(markers: [markerValue, "lvx-def456"])
        ingestRemoteHerdrSession(into: registry, sessionID: "s-a")
        ingestRemoteHerdrSession(into: registry, sessionID: "s-b")
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        // The pane could name either session, so it names neither — and since
        // nothing was confirmed, the outer marker still answers.
        XCTAssertNotEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testPaneWithNoTitleKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(
                focused: HerdrFocusedPane(
                    paneID: remotePaneID, claimedClaudeSessionID: nil, terminalTitle: nil
                )
            ),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertEqual(join?.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testPaneTitleWithoutAMarkerKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(title: "~/work/service — zsh")),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertEqual(join?.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testPaneTitleWithTwoMarkersKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(title: "\(markerValue) lvx-def456")),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertEqual(join?.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testForegroundQueryUnavailableAbstains() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(), foreground: nil),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testForegroundDetectionUnavailableAbstains() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(
                focused: focusedPane(),
                foreground: HerdrPaneForegroundInfo(shellPID: 8000, foregroundProcesses: nil)
            ),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertNil(join)
    }

    func testAgentNotInTheForegroundAbstains() async throws {
        // The user suspended Claude Code and is back at the shell: the pane is
        // still "theirs", and its context is still not what they are dictating
        // into.
        let registry = makeRegistry(markers: [markerValue])
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
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: The connection-level bind (review blocker 1)

    func testASecondTerminalToTheSameHostStopsTheArmAndKeepsTheMarkerJoin() async throws {
        // THE blocker: terminal A is a plain shell to `builder`, terminal B is
        // attached to herdr on `builder`. Dictating in A must not query B's
        // herdr, must not join B's session — and must not lose A's own
        // title-marker join either.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: panes,
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "builder",
                        isOnlyConnectionToDestination: false,
                        indicatesHerdr: true
                    )
                ),
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0, "no tunnel may be opened for an unbound connection")
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty }, "no herdr query may be issued")
    }

    func testTheHerdrArgvSignalNeverSubstitutesForUniqueness() async throws {
        // argv is written by whoever launched the process, so a remote command
        // that claims to be herdr must not stand in for the one fact that is
        // not forgeable — how many connections to that host exist (review
        // round 3, blocker 1a).
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: panes,
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "builder",
                        isOnlyConnectionToDestination: false,
                        indicatesHerdr: true
                    )
                ),
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testAPlainSSHSessionNeverReachesTheArmEvenAsTheSoleConnection() async throws {
        // Review round 5b, major 1. Being the only connection says nothing
        // about what this terminal DISPLAYS: a herdr whose client detached —
        // or whose pane still carries a marker and a running agent inside the
        // registry TTL — keeps answering `pane.current` with that pane, so a
        // later plain `ssh builder` would join a session the user cannot see.
        //
        // herdr exposes no read-only attachment signal (verified against the
        // 0.7.5 socket schema and the 0.8.0 docs: the only `client.*` methods
        // are `window_title.set`/`clear`, both mutations), so the evidence has
        // to be the invocation itself.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: panes,
                forwards: forwards,
                sshResult: .connection(
                    SSHSurfaceConnection(
                        destination: "builder",
                        isOnlyConnectionToDestination: true,
                        indicatesHerdr: false
                    )
                ),
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        // And it costs NOTHING: no tunnel spawned, no herdr dialled. This is
        // also the answer to the round-5b UX finding — a plain sole ssh to an
        // enrolled host no longer pays a forward before falling through.
        XCTAssertEqual(forwards.openCount, 0)
        XCTAssertTrue(panes.requests.withLock { $0.isEmpty })
    }

    func testTheManualHerdrFlowGetsNoHerdrJoin() async throws {
        // The documented, accepted limitation: `ssh host`, then typing `herdr`,
        // leaves no trace in argv, so the arm cannot bind and no HERDR join
        // happens. What this does NOT claim is "no context at all" (review
        // round 7 corrected that): the arm returns `.notApplicable`, so the
        // title-marker arm still runs — see
        // `testAPlainSSHSessionNeverReachesTheArmEvenAsTheSoleConnection`,
        // where a marker in the outer title still wins. Here there is no such
        // marker, so nothing joins.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane()),
            forwards: forwards,
            sshResult: .connection(
                SSHSurfaceConnection(
                    destination: "builder",
                    isOnlyConnectionToDestination: true,
                    indicatesHerdr: false
                )
            )
            // No outer title marker: herdr swallowed it.
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.openCount, 0)
    }

    func testAUniqueConnectionThatNamesHerdrJoins() async throws {
        // The positive case for the pair of requirements: BOTH the herdr
        // invocation and uniqueness, which is what a join takes since round 5b.
        // (This comment used to say the signal was "not required" — it is.)
        let registry = makeRegistry(markers: [markerValue])
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
                        isOnlyConnectionToDestination: true,
                        indicatesHerdr: true
                    )
                )
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .remoteHerdrPane)
        XCTAssertEqual(forwards.openCount, 1)
    }

    // MARK: herdr-or-nothing starts at CONFIRMATION (review round 3, blocker 1b)

    func testASolePlainSSHKeepsItsMarkerJoinWhenThePaneIsNotOurs() async throws {
        // The regression this arm must never cause: a lone ssh session to an
        // enrolled host that happens to run a detached herdr — or whose herdr
        // sessions are merely still inside their TTL — must keep the outer
        // title-marker join it has always had. Registry candidates existing is
        // not a binding for THIS connection.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                // The herdr's focused pane belongs to something else entirely.
                panes: RemoteJoinHerdrPanes(focused: focusedPane(paneID: "pane-someone-else")),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        // The tunnel was opened to ask, and closed once the answer was "not
        // this connection".
        XCTAssertEqual(forwards.openCount, 1)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAnUnreachableHerdrKeepsTheMarkerJoin() async throws {
        // Same rule, earlier failure: a detached herdr that answers nothing.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: nil),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAFailedForwardKeepsTheMarkerJoin() async throws {
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards(succeeds: false)

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
    }

    func testATitleMarkerNamingAnotherSessionKeepsTheMarkerJoin() async throws {
        // The pane confirmed nothing about US, so the outer marker still gets
        // its chance.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()

        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane(title: "lvx-999999")),
                forwards: forwards,
                title: markerValue
            ).resolve(target: ghostty)
        )

        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAConfirmedPaneThatFailsALaterCheckJoinsNOTHING() async throws {
        // Past confirmation — pane id AND our own marker both matched — the
        // outer title can only describe something else, so a later fail-closed
        // check refuses the whole dictation rather than falling back.
        let registry = makeRegistry(markers: [markerValue])
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
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: herdr's own session claim (review finding 3)

    func testAContradictoryPaneSessionClaimAbstains() async throws {
        // Stale-session scenario: session A died without a SessionEnd, leaving
        // a live registry entry, its marker, and its pane id; session B now
        // runs in that reused pane. herdr — which watches the pane — says B.
        // Pane id and a stale title still say A. That resolves to NEITHER.
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry, sessionID: "s-stale-a")
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry,
            panes: RemoteJoinHerdrPanes(focused: focusedPane(claim: "s-live-b")),
            forwards: forwards,
            title: markerValue
        ).resolve(target: ghostty)

        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testAnAgreeingPaneSessionClaimJoins() async throws {
        // The same check must CONFIRM when herdr agrees. The claim is herdr's
        // RAW session id; the registry speaks host- and agent-scoped ids.
        let registry = makeRegistry(markers: [markerValue])
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
        // workflow. The focused pane id picks exactly one candidate and the
        // marker then has to agree with THAT candidate — nothing here is a
        // "pick" that could land on the other session.
        let registry = makeRegistry(markers: ["lvx-aaa111", markerValue])
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
        XCTAssertEqual(join.marker.value, markerValue)
    }

    func testASessionForgingAnotherPaneIDCannotJoinWithoutThatPanesMarker() async throws {
        // The pane id is a label the host chose, so a session CAN claim
        // another's. What it cannot do is make the pane's title carry its
        // marker: markers are broker-allocated, and the one in the pane
        // belongs to the session actually living there.
        let registry = makeRegistry(markers: ["lvx-forger", markerValue])
        // The forger reports the focused pane's id...
        ingestRemoteHerdrSession(into: registry, sessionID: "s-forger")
        // ...and the pane's real occupant is evicted, so the forger is the only
        // candidate matching the pane id.
        let panes = RemoteJoinHerdrPanes(focused: focusedPane(title: markerValue))
        let forwards = RecordingForwards()

        let join = await resolver(
            registry: registry, panes: panes, forwards: forwards, title: markerValue
        ).resolve(target: ghostty)

        // The forger's marker is lvx-forger; the pane's title carries the other
        // session's. No join.
        XCTAssertNil(join)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    // MARK: The foreground cross-check's two signals

    func testHookParentPIDMatchJoinsEvenWhenTheProcessIsNamedNode() async throws {
        // An npm-installed Claude Code is `node` in the process table. The
        // published `$PPID` is the other half of the same question.
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
        ingestRemoteHerdrSession(into: registry)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            herdrPanes: RemoteJoinHerdrPanes(focused: focusedPane())
        )
        let join = await resolver.resolve(target: ghostty)
        XCTAssertNil(join)
    }

    // MARK: Downstream consequences of the mechanism

    func testARemoteHerdrJoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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

    func testAJoinWithNoTunnelIsNotRetained() {
        let viewModel = makeViewModel()
        viewModel.retainRemoteHerdrForward(of: nil)
        XCTAssertEqual(viewModel.openRemoteHerdrForwardCount, 0)
    }

    // MARK: Pane screen context over the forward

    func testRemoteHerdrPaneTextIsCapturedAtStartAndReconciledAtStop() async throws {
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: [markerValue])
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
        let registry = makeRegistry(markers: ["lvx-a", "lvx-b", "lvx-c", "lvx-d"])
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
        let registry = makeRegistry(markers: ["lvx-a"])
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
