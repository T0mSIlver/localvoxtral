import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Records every collection attempt. The question these tests ask is not "did
/// the snapshot come back empty" but "was the filesystem touched at all" —
/// a gate that reads first and discards afterwards is not a gate.
private final class GateSpyCollector: ClaudeRepoCollecting, @unchecked Sendable {
    private let calls = Mutex<[String]>([])
    var collectedPaths: [String] { calls.withLock { $0 } }

    func collect(
        workspace: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        transcript: String
    ) async -> ClaudeRepoSnapshot? {
        calls.withLock { $0.append(workspace.path) }
        var snapshot = ClaudeRepoSnapshot.empty
        snapshot.workspaceName = "repo"
        snapshot.branch = "main"
        return snapshot
    }
}

private final class GateTestMarkers: Sendable {
    private let queue: Mutex<[String]>
    init(_ values: [String]) { queue = Mutex(values) }
    var allocate: @Sendable () -> String {
        { [self] in queue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() } }
    }
}

/// The gates in front of repository collection, in the order they must fire:
/// setting, loopback endpoint, live join, LOCAL workspace. Each one is asserted
/// to prevent the filesystem call, not merely to discard its result.
@MainActor
final class ClaudeRepoContextGateTests: XCTestCase {
    private static var retainedViewModels: [DictationViewModel] = []

    private let loopback = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!
    private let remote = URL(string: "https://api.example.com/v1/chat/completions")!
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.ClaudeRepoContextGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func registry(cwd: String? = "/repo") -> ClaudeSessionRegistry {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: cwd,
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        return registry
    }

    /// A view model wired to a live join, with a spy collector.
    private func wired(
        cwd: String? = "/repo",
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501)
    ) -> (DictationViewModel, GateSpyCollector, ClaudeSessionJoin?) {
        let viewModel = makeViewModel()
        let collector = GateSpyCollector()
        viewModel.claudeRepoCollector = collector

        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: cwd,
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            origin: origin
        )
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in ClaudeSessionMarker(value: "lvx-abcd") }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = resolver.resolve(target: ghostty)
        viewModel.claudeSessionJoin = join
        return (viewModel, collector, join)
    }

    // MARK: - The positive control

    // Without this, every gate test below would pass just as well if the
    // collector were never reachable at all.
    func testEnabledLoopbackLiveLocalJoinReachesTheCollector() async {
        let (viewModel, collector, join) = wired()
        viewModel.settings.claudeRepoContextEnabled = true
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(collector.collectedPaths, ["/repo"])
    }

    // MARK: - Setting gate

    func testSettingDefaultsOff() {
        let viewModel = makeViewModel()
        XCTAssertFalse(
            viewModel.settings.claudeRepoContextEnabled,
            "sending the contents of the user's source files must be opt-in"
        )
    }

    func testSettingOffMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired()
        viewModel.settings.claudeRepoContextEnabled = false
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "an opted-out user's repository must never be read"
        )
    }

    // The setting is re-checked at commit, not trusted from start: the user can
    // toggle it off while they are speaking, and that is a withdrawal of consent
    // that must land before a single file is read.
    func testSettingToggledOffMidSessionMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired()
        viewModel.settings.claudeRepoContextEnabled = true
        XCTAssertNotNil(join, "precondition: the join resolved while the setting was on")
        viewModel.settings.claudeRepoContextEnabled = false
        _ = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertTrue(collector.collectedPaths.isEmpty)
    }

    // MARK: - Loopback gate

    // Repository contents must never ride to a remote endpoint, and the gate is
    // what guarantees no filesystem read even STARTS for one.
    func testRemoteEndpointMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired()
        viewModel.settings.claudeRepoContextEnabled = true
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: remote, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "a remote polishing endpoint must never see repository contents"
        )
    }

    // MARK: - Join gate

    // The common case: a plain terminal with no marker. No join, no read.
    func testNoJoinMakesNoFilesystemCall() async {
        let (viewModel, collector, _) = wired()
        viewModel.settings.claudeRepoContextEnabled = true
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: nil, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "no marker means no session, and no session means no repository"
        )
    }

    // The session died between start and commit. Its repo is no longer what the
    // user is looking at.
    func testSessionThatEndedSinceStartMakesNoFilesystemCall() async {
        let viewModel = makeViewModel()
        let collector = GateSpyCollector()
        viewModel.claudeRepoCollector = collector
        viewModel.settings.claudeRepoContextEnabled = true

        let dead = Mutex(false)
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in !dead.withLock { $0 } },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/repo",
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in ClaudeSessionMarker(value: "lvx-abcd") }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = resolver.resolve(target: ghostty)
        XCTAssertNotNil(join, "precondition: live at join time")

        dead.withLock { $0 = true }
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(collector.collectedPaths.isEmpty)
    }

    // Without a resolver (broker startup failed) there is nothing vouching for
    // the join, so it must not be acted on.
    func testNoResolverMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired()
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.claudeSessionJoinResolver = nil
        _ = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertTrue(collector.collectedPaths.isEmpty)
    }

    // MARK: - The type gate

    // A remote session joins, but has no `localWorkspacePath` to hand the
    // collector — enforced by `ClaudeWorkspaceReference.make` never building one
    // for a remote origin, not by a check here.
    func testRemoteSessionMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired(
            cwd: "/srv/repo", origin: .remote(channel: "ssh")
        )
        viewModel.settings.claudeRepoContextEnabled = true
        XCTAssertNotNil(join, "precondition: a remote session still joins")
        XCTAssertNil(join?.localWorkspacePath)
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "a remote cwd must never reach the local filesystem"
        )
    }

    // A session with no cwd at all has no workspace to collect.
    func testSessionWithNoWorkspaceMakesNoFilesystemCall() async {
        let (viewModel, collector, join) = wired(cwd: nil)
        viewModel.settings.claudeRepoContextEnabled = true
        _ = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertTrue(collector.collectedPaths.isEmpty)
    }

    // MARK: - Join lifecycle

    // The join names a session and a pane belonging to the session being
    // abandoned. A stale one surviving is how the wrong repo's context would get
    // attached to an unrelated sentence.
    func testDiscardingTheScreenCaptureAlsoDropsTheJoin() {
        let (viewModel, _, join) = wired()
        viewModel.claudeSessionJoin = join
        viewModel.discardTerminalScreenCapture()
        XCTAssertNil(viewModel.claudeSessionJoin)
    }

    // Consuming hands the join over exactly once, so a later session cannot
    // inherit it.
    func testConsumingTheJoinClearsIt() {
        let (viewModel, _, join) = wired()
        viewModel.claudeSessionJoin = join
        XCTAssertEqual(viewModel.consumeClaudeSessionJoin()?.marker, join?.marker)
        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertNil(viewModel.consumeClaudeSessionJoin())
    }

    // MARK: - Start-time resolution gating

    // Resolving is not passive: it makes a live AX round trip for the window
    // title. Every gate must sit in front of it, exactly as they do for the
    // screen read.
    func testStartResolutionNeverReadsTheTitleWhenBothFeaturesAreOff() {
        let viewModel = makeViewModel()
        let reads = Mutex(0)
        viewModel.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry(),
            markerInWindowTitle: { _ in
                reads.withLock { $0 += 1 }
                return ClaudeSessionMarker(value: "lvx-abcd")
            }
        )
        viewModel.settings.terminalScreenContextEnabled = false
        viewModel.settings.claudeRepoContextEnabled = false
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.ghostty }

        viewModel.captureTerminalScreenContextForSession()

        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(reads.withLock { $0 }, 0, "an opted-out user's title must never be read")
    }

    override func tearDown() async throws {
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        TerminalScreenContextSource.debugTargetForPIDOverride = nil
        TerminalScreenAXReader.debugScreenReadOverride = nil
        TerminalScreenAXReader.debugWindowTitleOverride = nil
        try await super.tearDown()
    }
}
