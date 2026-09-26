import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
import localvoxtralCore

// The remote herdr join's fakes and fixed world, shared by RemoteHerdrJoinTests
// (core) and RemoteHerdrForwardOwnershipTests (app), whose view model the core
// cannot see.

/// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This
/// evaluates the value first and then unwraps it.
package func unwrapAsync<T>(
    _ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}

// MARK: - Fakes

/// Scripted herdr socket, recording every request so a test can prove which
/// socket path and which pane the client was pointed at.
package final class RemoteJoinHerdrPanes:
    HerdrPaneQuerying, HerdrPanelMetadataReporting, @unchecked Sendable
{
    package struct Request: Equatable {
        package var method: String
        package var socketPath: String
        package var paneID: String?

        package init(method: String, socketPath: String, paneID: String?) {
            self.method = method
            self.socketPath = socketPath
            self.paneID = paneID
        }
    }

    package let requests = Mutex<[Request]>([])
    private let focused: HerdrFocusedPane?
    private let foreground: HerdrPaneForegroundInfo?
    private let visibleTexts = Mutex<[String?]>([])
    package let panelReports = Mutex<[(socketPath: String, paneID: String, value: String?, ttl: Int?)]>([])
    private let panelReportSucceeds: Bool

    package init(
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

    package func focusedPane(socketPath: String) async -> HerdrFocusedPane? {
        requests.withLock {
            $0.append(Request(method: "pane.current", socketPath: socketPath, paneID: nil))
        }
        return focused
    }

    package func paneForegroundInfo(socketPath: String, paneID: String) async -> HerdrPaneForegroundInfo? {
        requests.withLock {
            $0.append(
                Request(method: "pane.process_info", socketPath: socketPath, paneID: paneID)
            )
        }
        return foreground
    }

    package func paneVisibleText(socketPath: String, paneID: String) async -> String? {
        requests.withLock {
            $0.append(Request(method: "pane.read", socketPath: socketPath, paneID: paneID))
        }
        return visibleTexts.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    package func reportPanelToken(
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

package final class FakeForwardProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    private struct State {
        var isRunning: Bool
        var waiters: [CheckedContinuation<ClaudeRemoteForwardExitStatus, Never>] = []
    }

    private let state: Mutex<State>
    private let stderrContinuation: AsyncStream<String>.Continuation
    package let standardErrorLines: AsyncStream<String>
    package let terminations = Mutex(0)

    package init(running: Bool = true) {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self)
        standardErrorLines = stream
        stderrContinuation = continuation
        state = Mutex(State(isRunning: running))
        if !running { stderrContinuation.finish() }
    }

    package var isRunning: Bool { state.withLock { $0.isRunning } }
    package var processIdentifier: pid_t { 4_242 }

    package func exit() {
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

    package func waitUntilExit() async -> ClaudeRemoteForwardExitStatus {
        await withCheckedContinuation { continuation in
            let alreadyExited = state.withLock { current -> Bool in
                guard current.isRunning else { return true }
                current.waiters.append(continuation)
                return false
            }
            if alreadyExited { continuation.resume(returning: .code(0)) }
        }
    }

    package func terminate() {
        terminations.withLock { $0 += 1 }
        exit()
    }

    package func forceTerminate() { terminate() }
}

package final class RecordingWorkspaces: ClaudeRemoteHerdrWorkspaceProviding, @unchecked Sendable {
    package struct Failure: Error {}

    package let made = Mutex<[ClaudeRemoteHerdrForwardWorkspace]>([])
    package let removed = Mutex<[ClaudeRemoteHerdrForwardWorkspace]>([])
    private let socketPath: String
    private let shouldFail: Bool

    package init(socketPath: String = "/tmp/lvx-herdr-fwd-test/h.sock", shouldFail: Bool = false) {
        self.socketPath = socketPath
        self.shouldFail = shouldFail
    }

    package func makeWorkspace() throws -> ClaudeRemoteHerdrForwardWorkspace {
        if shouldFail { throw Failure() }
        let workspace = ClaudeRemoteHerdrForwardWorkspace(
            directoryPath: (socketPath as NSString).deletingLastPathComponent,
            socketPath: socketPath
        )
        made.withLock { $0.append(workspace) }
        return workspace
    }

    package func remove(_ workspace: ClaudeRemoteHerdrForwardWorkspace) {
        removed.withLock { $0.append(workspace) }
    }
}

/// Stands in for the whole forward service in resolver tests, so the join arm
/// can be exercised without any notion of processes.
@MainActor
package final class RecordingForwards: ClaudeRemoteHerdrForwarding {
    package struct Opened: Equatable {
        package var alias: String
        package var remoteSocketPath: String

        package init(alias: String, remoteSocketPath: String) {
            self.alias = alias
            self.remoteSocketPath = remoteSocketPath
        }
    }

    package let opens = Mutex<[Opened]>([])
    package let localSocketPath: String
    private let succeeds: Bool
    /// Remote socket labels whose forward fails to open — a stale socket from
    /// a previous herdr boot, still inside the registry TTL.
    private let failingRemoteSocketPaths: Set<String>
    package let process = FakeForwardProcess()
    package let workspaces = RecordingWorkspaces()

    package init(
        succeeds: Bool = true,
        localSocketPath: String = "/tmp/lvx-herdr-fwd-test/h.sock",
        failingRemoteSocketPaths: Set<String> = []
    ) {
        self.succeeds = succeeds
        self.localSocketPath = localSocketPath
        self.failingRemoteSocketPaths = failingRemoteSocketPaths
    }

    package func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle? {
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

    package var openCount: Int { opens.withLock { $0.count } }
    package var closeCount: Int { workspaces.removed.withLock { $0.count } }
}

package final class RemoteJoinTestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    package init() {}
    package var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
    package func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

// MARK: - The fixed world

/// A Claude Code session inside a herdr on an ENROLLED REMOTE host, seen from
/// a local Ghostty surface: the constants and builders every remote herdr join
/// test resolves against.
@MainActor
package protocol RemoteHerdrJoinFixture {}

extension RemoteHerdrJoinFixture {
    package var epoch: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    package var ghostty: TerminalScreenTarget {
        TerminalScreenTarget(pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    }
    package var hostID: String { "h1a2b3c4" }
    package var surfaceTTY: String { "/dev/ttys-outer" }
    package var remotePaneID: String { "pane-remote-7" }
    package var remoteSocketPath: String { "/run/user/1000/herdr/default.sock" }

    package func makeRegistry(
        liveness: RemoteJoinTestLiveness = RemoteJoinTestLiveness()
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            now: { [epoch] in epoch },
            isProcessAlive: liveness.probe
        )
    }

    /// One live REMOTE session on `hostID`, reporting a herdr pane.
    @discardableResult
    package func ingestRemoteHerdrSession(
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

    package func enrolledHost(
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

    package func focusedPane(
        paneID: String? = nil,
        claim: String? = nil
    ) -> HerdrFocusedPane {
        HerdrFocusedPane(
            paneID: paneID ?? remotePaneID,
            claimedClaudeSessionID: claim
        )
    }

    package func resolver(
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
        indicatorSleepFor: @escaping HerdrPanelMicIndicator.SleepFor = { _ in },
        herdrClient: Bool = false,
        federation: HerdrMachineFederation = .notFederated,
        clientSurfaces: Int? = nil,
        // When set, the exact-alias seam returns these verbatim, unfiltered:
        // the arm itself must refuse revoked or alias-less hits.
        exactHosts: [ClaudeRemoteHost]? = nil
    ) -> ClaudeSessionJoinResolver {
        let hostList = hosts ?? [enrolledHost()]
        let fixedNow = epoch
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            // The surface is NOT a local herdr client: that arm has to have
            // declined before this one is even reached.
            herdrClientProbe: { _ in herdrClient },
            herdrFederation: { federation },
            herdrClientSurfaceCount: { clientSurfaces },
            herdrPanes: panes,
            sshDestinationProbe: { _ in sshResult },
            enrolledHosts: { destination in
                if let exactHosts { return exactHosts }
                return hostList.filter { host in
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
            indicatorSleepFor: indicatorSleepFor
        )
    }
}
