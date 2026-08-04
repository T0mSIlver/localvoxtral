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

/// Counts live-seam calls; a class because `Mutex` is noncopyable and cannot
/// be an optional parameter.
private final class GateTabURLReadCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
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
    private let chrome = TerminalScreenTarget(
        pid: 5150,
        bundleID: BrowserTabAllowlist.chromeBundleID
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
    ) async -> (DictationViewModel, GateSpyCollector, ClaudeSessionJoin?) {
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
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = await resolver.resolve(target: ghostty)
        viewModel.claudeSessionJoin = join
        return (viewModel, collector, join)
    }

    // MARK: - The positive control

    // Without this, every gate test below would pass just as well if the
    // collector were never reachable at all.
    func testEnabledLoopbackLiveLocalJoinReachesTheCollector() async {
        let (viewModel, collector, join) = await wired()
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
        let (viewModel, collector, join) = await wired()
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
        let (viewModel, collector, join) = await wired()
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
        let (viewModel, collector, join) = await wired()
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

    // The trusted-endpoint opt-in is the ONE way a non-loopback endpoint may
    // receive repository content — explicit, default off, and it does not
    // bypass any other gate (the setting itself still gates below).
    func testTrustedEndpointOptInAdmitsRemoteEndpoint() async {
        let (viewModel, collector, join) = await wired()
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.settings.polishContextTrustedEndpointEnabled = true
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: remote, transcript: "hello"
        )
        XCTAssertNotNil(snapshot)
        XCTAssertFalse(
            collector.collectedPaths.isEmpty,
            "the explicit opt-in is consent for this exact ride"
        )
    }

    func testTrustedEndpointOptInDoesNotBypassTheFeatureToggle() async {
        let (viewModel, collector, join) = await wired()
        viewModel.settings.claudeRepoContextEnabled = false
        viewModel.settings.polishContextTrustedEndpointEnabled = true
        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: remote, transcript: "hello"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "trusting an endpoint is not consent to collect anything"
        )
    }

    // MARK: - Join gate

    // The common case: a plain terminal with no marker. No join, no read.
    func testNoJoinMakesNoFilesystemCall() async {
        let (viewModel, collector, _) = await wired()
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
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = await resolver.resolve(target: ghostty)
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
        let (viewModel, collector, join) = await wired()
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
        let (viewModel, collector, join) = await wired(
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
        let (viewModel, collector, join) = await wired(cwd: nil)
        viewModel.settings.claudeRepoContextEnabled = true
        _ = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )
        XCTAssertTrue(collector.collectedPaths.isEmpty)
    }

    // MARK: - The session block's gates

    // The session block carries the PRIOR PROMPT the user typed, the workspace
    // name, and the files the agent touched. That is the session's content, so
    // it answers to the same three gates as the repository block — it used to
    // check only the setting, which meant a dead session's prompt still rode to
    // whatever endpoint was configured.
    //
    // Each test asserts THREE things, because suppressing only the last would be
    // a leak wearing a gate's clothes: no text, no rendered block, and no
    // grounding entries. Grounding is the one that matters most — it is
    // input-side and costs no budget, so a check that only emptied the excerpt
    // would still hand the model the prompt's words as replacement entries.
    private func sessionBlockOutcome(
        _ viewModel: DictationViewModel,
        join: ClaudeSessionJoin?,
        endpointURL: URL
    ) async -> (text: String, block: PolishContextBlock?, groundingCount: Int) {
        let text = viewModel.claudeSessionTextIfEnabled(join: join, endpointURL: endpointURL)
        let preparation = await PolishContextPreparation.prepared(
            text: text,
            transcript: "check the migration script",
            renderBudget: 4_000
        )
        let block = join?.snapshot.claudeContextBlock(
            excerpt: preparation.excerpt,
            renderBudget: 4_000
        )
        return (text, block, preparation.grounding.entries.count)
    }

    /// A live join whose session has already submitted a prompt, so the block
    /// has something to leak if a gate fails open.
    private func wiredWithPriorPrompt() async -> (DictationViewModel, ClaudeSessionJoin?) {
        let viewModel = makeViewModel()
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        for record in [
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/repo",
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            ClaudeHookRecord(
                event: .userPromptSubmit,
                sessionID: "s1",
                timestamp: 1,
                rawCwd: "/repo",
                prompt: "rewrite the migration script to be idempotent",
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
        ] {
            registry.ingest(record, origin: .localAuthenticated(peerUID: 501))
        }
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = await resolver.resolve(target: ghostty)
        viewModel.claudeSessionJoin = join
        return (viewModel, join)
    }

    // The positive control. Without it every gate test below would pass just as
    // well if the block were unreachable entirely.
    func testEnabledLoopbackLiveJoinAttachesTheSessionBlock() async {
        let (viewModel, join) = await wiredWithPriorPrompt()
        viewModel.settings.claudeRepoContextEnabled = true
        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: loopback)
        XCTAssertTrue(outcome.text.contains("rewrite the migration script"))
        XCTAssertNotNil(outcome.block)
    }

    // Consent withdrawn while they were speaking. It must land on this block
    // too, not just on the repository read.
    func testSettingToggledOffMidSessionAttachesNoSessionBlock() async {
        let (viewModel, join) = await wiredWithPriorPrompt()
        viewModel.settings.claudeRepoContextEnabled = true
        XCTAssertNotNil(join, "precondition: the join resolved while the setting was on")
        viewModel.settings.claudeRepoContextEnabled = false

        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: loopback)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.block)
        XCTAssertEqual(outcome.groundingCount, 0, "an opted-out session must not ground either")
    }

    // Settings changed the endpoint to a remote one after the join resolved. The
    // user's typed prompt must not ride to it.
    func testRemoteEndpointAttachesNoSessionBlock() async {
        let (viewModel, join) = await wiredWithPriorPrompt()
        viewModel.settings.claudeRepoContextEnabled = true

        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: remote)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.block)
        XCTAssertEqual(
            outcome.groundingCount, 0,
            "a remote endpoint must never receive the session's prompt, as text OR as grounding"
        )
    }

    // The trusted-endpoint opt-in admits the session block to a remote
    // endpoint — the same remote URL that just attached nothing now carries
    // the prior prompt, because the user explicitly consented to this exact
    // ride (mirror of `testTrustedEndpointOptInAdmitsRemoteEndpoint`).
    func testTrustedEndpointOptInAttachesTheSessionBlockToRemoteEndpoint() async {
        let (viewModel, join) = await wiredWithPriorPrompt()
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.settings.polishContextTrustedEndpointEnabled = true

        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: remote)
        XCTAssertTrue(outcome.text.contains("rewrite the migration script"))
        XCTAssertNotNil(outcome.block)
    }

    // The session died between start and commit. Its prior prompt is no longer
    // what the user is continuing.
    func testSessionThatEndedSinceStartAttachesNoSessionBlock() async {
        let viewModel = makeViewModel()
        viewModel.settings.claudeRepoContextEnabled = true

        let dead = Mutex(false)
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in !dead.withLock { $0 } },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .userPromptSubmit,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/repo",
                prompt: "rewrite the migration script to be idempotent",
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        viewModel.claudeSessionJoinResolver = resolver
        let join = await resolver.resolve(target: ghostty)
        XCTAssertNotNil(join, "precondition: live at join time")

        dead.withLock { $0 = true }
        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: loopback)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.block)
        XCTAssertEqual(outcome.groundingCount, 0)
    }

    // No resolver means nothing vouches for the join — the same abstention the
    // repository read makes.
    func testNoResolverAttachesNoSessionBlock() async {
        let (viewModel, join) = await wiredWithPriorPrompt()
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.claudeSessionJoinResolver = nil

        let outcome = await sessionBlockOutcome(viewModel, join: join, endpointURL: loopback)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.block)
    }

    // MARK: - Join lifecycle

    // The join names a session and a pane belonging to the session being
    // abandoned. A stale one surviving is how the wrong repo's context would get
    // attached to an unrelated sentence.
    func testDiscardingTheScreenCaptureAlsoDropsTheJoin() async {
        let (viewModel, _, join) = await wired()
        viewModel.claudeSessionJoin = join
        viewModel.discardTerminalScreenCapture()
        XCTAssertNil(viewModel.claudeSessionJoin)
    }

    // Consuming hands the join over exactly once, so a later session cannot
    // inherit it.
    func testConsumingTheJoinClearsIt() async {
        let (viewModel, _, join) = await wired()
        viewModel.claudeSessionJoin = join
        XCTAssertEqual(viewModel.consumeClaudeSessionJoin()?.marker, join?.marker)
        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertNil(viewModel.consumeClaudeSessionJoin())
    }

    // MARK: - Start-time resolution gating

    // Resolving is not passive: it makes a live AX round trip for the window
    // title. Every gate must sit in front of it, exactly as they do for the
    // screen read.
    func testStartResolutionNeverReadsTheTitleWhenBothFeaturesAreOff() async {
        let viewModel = makeViewModel()
        let reads = Mutex(0)
        viewModel.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry(),
            markerInWindowTitle: { _ in
                reads.withLock { $0 += 1 }
                return TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        viewModel.settings.terminalScreenContextEnabled = false
        viewModel.settings.claudeRepoContextEnabled = false
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.ghostty }

        await viewModel.captureTerminalScreenContextForSession()

        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(reads.withLock { $0 }, 0, "an opted-out user's title must never be read")
    }

    // The trusted-endpoint opt-in also admits the START-TIME join resolution:
    // with a remote polishing endpoint, the resolver is consulted only under
    // the opt-in — same gate, same order, as every commit-time surface. Both
    // halves in one test so the opt-in is provably what flips the answer.
    func testStartResolutionOverRemoteEndpointRequiresTheTrustedOptIn() async {
        let viewModel = makeViewModel()
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEndpointURL = remote.absoluteString
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { viewModel.textInsertion.debugSetAccessibilityTrusted(nil) }
        let reads = Mutex(0)
        viewModel.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry(),
            markerInWindowTitle: { _ in
                reads.withLock { $0 += 1 }
                return TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.ghostty }

        viewModel.settings.polishContextTrustedEndpointEnabled = false
        await viewModel.captureTerminalScreenContextForSession()
        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(
            reads.withLock { $0 }, 0,
            "a remote endpoint without the opt-in must not even read the title"
        )

        viewModel.settings.polishContextTrustedEndpointEnabled = true
        await viewModel.captureTerminalScreenContextForSession()
        XCTAssertNotNil(viewModel.claudeSessionJoin, "the opt-in admits the join")
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }

    // MARK: - Browser tab entry path

    /// A view model whose resolver can only answer through the browser arm, over
    /// a session that reports a Remote Control bridge id.
    private func wiredBrowserTab(
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501),
        cwd: String? = "/repo",
        urlReads: GateTabURLReadCounter? = nil
    ) -> (DictationViewModel, GateSpyCollector) {
        let viewModel = makeViewModel()
        let collector = GateSpyCollector()
        viewModel.claudeRepoCollector = collector
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: GateTestMarkers(["lvx-abcd"]).allocate
        )
        let isLocal = origin.isLocalAuthenticated
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: cwd,
                prompt: "the prior prompt",
                process: ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: 9001,
                    bridgeSessionID: isLocal ? "session_abc123" : nil
                )
            ),
            origin: origin,
            environment: isLocal
                ? nil : ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
        )
        viewModel.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in nil },
            focusedBrowserTabURL: { _ in
                urlReads?.increment()
                return "https://claude.ai/code/session_abc123"
            },
            focusedWindowID: { _ in nil }
        )
        return (viewModel, collector)
    }

    // A browser join can only ever produce the session/repo blocks — the
    // authorizer refuses raw attachment for it — so the SCREEN setting alone
    // must not send an Apple event to the user's browser (which is also what
    // raises its Automation consent sheet).
    func testBrowserTargetIsNeverAskedWithoutTheSessionContextSetting() async {
        let reads = GateTabURLReadCounter()
        let (viewModel, _) = wiredBrowserTab(urlReads: reads)
        viewModel.settings.llmPolishingEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { viewModel.textInsertion.debugSetAccessibilityTrusted(nil) }
        viewModel.settings.terminalScreenContextEnabled = true
        viewModel.settings.claudeRepoContextEnabled = false
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.chrome }

        await viewModel.captureTerminalScreenContextForSession()

        XCTAssertNil(viewModel.claudeSessionJoin)
        XCTAssertEqual(reads.count, 0, "the browser must not be automated for this")

        // The setting the browser arm actually serves admits it.
        viewModel.settings.claudeRepoContextEnabled = true
        await viewModel.captureTerminalScreenContextForSession()
        XCTAssertEqual(viewModel.claudeSessionJoin?.mechanism, .browserTab)
        XCTAssertEqual(reads.count, 1)
    }

    // The end-to-end entry path: frontmost Chrome, session context on, and the
    // dictation's ONE join is the browser arm's.
    func testFrontmostBrowserResolvesTheJoinAtStart() async throws {
        let (viewModel, _) = wiredBrowserTab()
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { viewModel.textInsertion.debugSetAccessibilityTrusted(nil) }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.chrome }

        await viewModel.captureTerminalScreenContextForSession()

        let join = try XCTUnwrap(viewModel.claudeSessionJoin)
        XCTAssertEqual(join.mechanism, .browserTab)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertNil(
            viewModel.terminalScreenStartCapture,
            "a browser is not screen-readable: nothing may be captured for it"
        )
    }

    // A LOCAL session joined through the browser has a real workspace, so repo
    // collection proceeds under exactly the existing local-join rules.
    func testBrowserJoinToALocalSessionReachesTheCollector() async throws {
        let (viewModel, collector) = wiredBrowserTab()
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { viewModel.textInsertion.debugSetAccessibilityTrusted(nil) }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.chrome }
        await viewModel.captureTerminalScreenContextForSession()
        let join = try XCTUnwrap(viewModel.claudeSessionJoin)

        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(collector.collectedPaths, ["/repo"])
    }

    // A REMOTE Remote Control session joins (the bridge id is globally unique,
    // so this is the one arm where a remote session legitimately matches) but
    // still cannot reach the filesystem — while its off-screen session block,
    // which opens nothing, does attach.
    func testBrowserJoinToARemoteSessionNeverReachesTheCollector() async throws {
        let (viewModel, collector) = wiredBrowserTab(origin: .remote(channel: "ssh:host-a"))
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { viewModel.textInsertion.debugSetAccessibilityTrusted(nil) }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.chrome }
        await viewModel.captureTerminalScreenContextForSession()
        let join = try XCTUnwrap(viewModel.claudeSessionJoin)

        let snapshot = await viewModel.claudeRepoSnapshotIfEnabled(
            join: join, endpointURL: loopback, transcript: "hello"
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(collector.collectedPaths, [], "no file of a remote host may be opened")
        XCTAssertFalse(
            viewModel.claudeSessionTextIfEnabled(join: join, endpointURL: loopback).isEmpty,
            "the session's own off-screen facts are exactly what the block is for"
        )
    }

    override func tearDown() async throws {
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        TerminalScreenContextSource.debugTargetForPIDOverride = nil
        TerminalScreenAXReader.debugScreenReadOverride = nil
        TerminalScreenAXReader.debugWindowTitleOverride = nil
        try await super.tearDown()
    }
}
