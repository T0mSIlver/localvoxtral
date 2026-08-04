import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Test clock — the registry never reads the wall clock itself, so TTL and
/// staleness move by hand (AGENTS: no wall-clock in tests).
private final class BrowserJoinTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// Counts live-seam calls. A class rather than a bare `Mutex` because `Mutex`
/// is noncopyable and cannot be passed as an optional parameter.
private final class BrowserJoinURLReadCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private final class BrowserJoinTestMarkers: Sendable {
    private let queue: Mutex<[String]>
    init(_ values: [String]) { queue = Mutex(values) }
    var allocate: @Sendable () -> String {
        { [self] in queue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() } }
    }
}

/// The browser tab join: the focused tab's `claude.ai/code/session_…` URL
/// against the `CLAUDE_CODE_BRIDGE_SESSION_ID` a live session's own hooks
/// published.
///
/// This arm exists because a Claude Code "Remote Control" session has no pane,
/// no TTY, and no window title to join on — the browser IS its UI. What it must
/// never become is a way for a browser to acquire terminal capabilities: a
/// browser join authorizes NO screen read of any kind, and that is asserted
/// here rather than left to the fact that no capture route happens to exist.
@MainActor
final class BrowserTabClaudeJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:host-a")
    private let chrome = TerminalScreenTarget(
        pid: 5150,
        bundleID: BrowserTabAllowlist.chromeBundleID
    )
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let sessionURL = "https://claude.ai/code/session_abc123"

    private func record(
        session: String = "s1",
        claudePID: Int32? = 9001,
        bridgeSessionID: String? = "session_abc123",
        cwd: String? = "/repo"
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: 0,
            rawCwd: cwd,
            prompt: nil,
            files: [],
            process: claudePID.map {
                ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: $0,
                    bridgeSessionID: bridgeSessionID
                )
            }
        )
    }

    private func makeRegistry(
        clock: BrowserJoinTestClock? = nil,
        markers: [String] = ["lvx-abcd", "lvx-efgh"]
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            now: (clock ?? BrowserJoinTestClock(epoch)).now,
            isProcessAlive: { _ in true },
            allocateMarkerValue: BrowserJoinTestMarkers(markers).allocate
        )
    }

    /// Every live seam injected. `focusedBrowserTabURL` counts its calls so the
    /// "never asked" assertions are about the Apple event, not its result.
    private func resolver(
        registry: ClaudeSessionRegistry,
        tabURL: String?,
        urlReads: BrowserJoinURLReadCounter? = nil
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in nil },
            focusedBrowserTabURL: { _ in
                urlReads?.increment()
                return tabURL
            },
            focusedWindowID: { _ in 101 }
        )
    }

    // MARK: - The joins

    // A LOCAL Remote Control session: the agent runs on this machine, the tab
    // is its UI. The join is exact equality between the URL's id and the id the
    // session's own hook environment carried.
    func testFocusedTabJoinsALocalRemoteControlSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(registry: registry, tabURL: sessionURL)
            .resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .browserTab)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.browserTab?.bridgeSessionID, "session_abc123")
        XCTAssertEqual(join.target, chrome)
        // A local session joined this way has a real workspace: repo collection
        // follows the existing local-join rules, unchanged.
        XCTAssertEqual(join.localWorkspacePath?.path, "/repo")
    }

    // A REMOTE session joins too, and this is the one arm where that is
    // correct: the bridge id is allocated by Anthropic's bridge and globally
    // unique, so a remote host reporting one is reporting its own. The workspace
    // stays remote — the type still refuses to hand a path to the collector.
    func testFocusedTabJoinsARemoteRemoteControlSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        let resolved = await resolver(registry: registry, tabURL: sessionURL)
            .resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .browserTab)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertNil(
            join.localWorkspacePath,
            "a remote session must never hand a filesystem path to the collector"
        )
    }

    func testEverySupportedBrowserResolves() async throws {
        for bundleID in BrowserTabAllowlist.supportedBundleIDs {
            let registry = makeRegistry()
            XCTAssertNotNil(registry.ingest(record(), origin: local))
            let target = TerminalScreenTarget(pid: 5150, bundleID: bundleID)
            let join = await resolver(registry: registry, tabURL: sessionURL)
                .resolve(target: target)
            XCTAssertEqual(join?.mechanism, .browserTab, "\(bundleID) must be joinable")
        }
    }

    // MARK: - Abstentions

    // The common case by far: the user is reading something else in the
    // frontmost tab. No id, no join — and no other arm may rescue it.
    func testNonClaudeTabDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = await resolver(registry: registry, tabURL: "https://example.com/docs")
            .resolve(target: chrome)
        XCTAssertNil(join)
    }

    // The Remote Control connection ended (or that session lives on a machine
    // whose hooks we never see): the tab still says `session_…`, nothing
    // reports it, and that must attach nothing rather than fall back.
    func testSessionURLWithNoReportingSessionDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(record(bridgeSessionID: "session_other"), origin: local)
        )
        let join = await resolver(registry: registry, tabURL: sessionURL).resolve(target: chrome)
        XCTAssertNil(join)
    }

    // Two sessions reporting one bridge id: we cannot tell which the tab is.
    // (Local + remote here, which is also the only way the two origins can
    // collide at all in this arm.)
    func testTwoSessionsReportingOneBridgeIDAbstain() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        let join = await resolver(registry: registry, tabURL: sessionURL).resolve(target: chrome)
        XCTAssertNil(join, "an ambiguous bridge id must attach nothing")
    }

    // The AppleScript read failed (Automation denied, no front window, a wedged
    // browser). Abstain, exactly like a failed tty read.
    func testProviderErrorAbstains() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = await resolver(registry: registry, tabURL: nil).resolve(target: chrome)
        XCTAssertNil(join)
    }

    // A browser that is not on the list is not asked at all: no Apple event, no
    // Automation prompt for an app the user never pointed us at. Firefox is the
    // concrete case (it exposes no focused-tab URL to AppleScript).
    func testUnlistedBrowserIsNeverAsked() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let reads = BrowserJoinURLReadCounter()
        let firefox = TerminalScreenTarget(pid: 6000, bundleID: "org.mozilla.firefox")
        let join = await resolver(registry: registry, tabURL: sessionURL, urlReads: reads)
            .resolve(target: firefox)
        XCTAssertNil(join)
        XCTAssertEqual(reads.count, 0)
    }

    // And the mirror: a terminal target never triggers a browser URL read.
    func testTerminalTargetIsNeverAskedForATabURL() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let reads = BrowserJoinURLReadCounter()
        let join = await resolver(registry: registry, tabURL: sessionURL, urlReads: reads)
            .resolve(target: ghostty)
        XCTAssertNil(join, "no title, no tty: the terminal arms must still abstain")
        XCTAssertEqual(reads.count, 0)
    }

    // A session past TTL is not a candidate, so the tab joins nothing.
    func testStaleSessionDoesNotJoin() async {
        let clock = BrowserJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        let join = await resolver(registry: registry, tabURL: sessionURL).resolve(target: chrome)
        XCTAssertNil(join)
    }

    // MARK: - What the join authorizes

    // The invariant: a browser join buys session/repo context and NOTHING on
    // screen. There is no verified capture route for a browser and the thing on
    // screen is an arbitrary web page, so the authorizer refuses the mechanism
    // outright — this is asserted, not inferred from "no route exists".
    func testBrowserJoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { join }
        )
        // Asked about its own target, and about a terminal — refused either way.
        XCTAssertFalse(authorizer.isAuthorized(target: chrome, windowID: 101))
        XCTAssertFalse(authorizer.isAuthorized(target: chrome, windowID: nil))
        XCTAssertFalse(authorizer.isAuthorized(target: ghostty, windowID: 101))
    }

    // The MECHANISM is what refuses, not the missing window identity. A browser
    // join resolved by the production arm carries no window id, so the window
    // check would refuse it anyway and hide a regression in the mechanism gate —
    // this hands the authorizer a browser join that satisfies every OTHER
    // condition (same target, matching established window, live session) and
    // still requires a refusal.
    func testTheMechanismItselfRefusesEvenWhenEveryOtherConditionHolds() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let arm = try XCTUnwrap(resolved)
        let joinWithWindow = ClaudeSessionJoin(
            target: arm.target,
            marker: arm.marker,
            snapshot: arm.snapshot,
            windowID: 101,
            mechanism: .browserTab,
            browserTab: arm.browserTab
        )
        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { joinWithWindow }
        )
        XCTAssertTrue(
            joinResolver.isStillLive(joinWithWindow),
            "precondition: only the mechanism can be what refuses below"
        )
        XCTAssertFalse(authorizer.isAuthorized(target: chrome, windowID: 101))
    }

    // A browser join carries no window identity on purpose: a window id exists
    // to pair a screen capture with the join that authorized it, and there is
    // no capture.
    func testBrowserJoinCarriesNoWindowIdentity() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(registry: registry, tabURL: sessionURL)
            .resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertNil(join.windowID)
    }

    // MARK: - Liveness

    func testJoinStaysLiveWhileTheSessionKeepsReportingTheSameBridge() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertNotNil(
            registry.ingest(
                ClaudeHookRecord(
                    event: .userPromptSubmit,
                    sessionID: "s1",
                    timestamp: 1,
                    rawCwd: "/repo",
                    prompt: "hello",
                    process: ClaudeHookProcessInfo(
                        hookPID: 778, claudePID: 9001, bridgeSessionID: "session_abc123"
                    )
                ),
                origin: local
            )
        )
        XCTAssertTrue(joinResolver.isStillLive(join))
    }

    // The regression this arm's liveness rule exists for: Claude Code REMOVES
    // `CLAUDE_CODE_BRIDGE_SESSION_ID` when the Remote Control connection ends,
    // and the reducer replaces the reported process block whole — so the very
    // next hook of a session the user disconnected carries no bridge id. The
    // session is still perfectly live (the marker resolves, the pid is alive),
    // which is exactly why a marker-only liveness check would keep attaching a
    // browser tab's context after the tab stopped driving that session.
    func testDisconnectedRemoteControlSessionAgesTheJoinOut() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertTrue(joinResolver.isStillLive(join))

        XCTAssertNotNil(
            registry.ingest(record(bridgeSessionID: nil), origin: local),
            "the session itself is still alive and reporting"
        )
        XCTAssertEqual(
            registry.resolve(marker: join.marker),
            .resolved(try XCTUnwrap(registry.snapshot(sessionID: "s1"))),
            "marker liveness alone still says yes — which is the point"
        )
        XCTAssertFalse(
            joinResolver.isStillLive(join),
            "a session that stopped reporting this bridge session must not stay joined"
        )
    }

    // Review finding (codex, PR #218): ambiguity that appears AFTER the join
    // was resolved must kill it too. The start-time arm abstains when two
    // sessions report one bridge id, but a second reporter can arrive between
    // start and commit — a hostile enrolled remote host can publish any label
    // it likes, and it wins nothing at start only because it was not yet
    // reporting. Commit-time liveness therefore re-ASKS the registry (like the
    // marker arm does) instead of re-checking only the session it already
    // picked: the joined session must still be the UNIQUE fresh reporter.
    func testABridgeIDCollisionAppearingAfterResolutionKillsTheJoin() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertTrue(joinResolver.isStillLive(join))

        // A second session starts claiming the same bridge id mid-dictation.
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        XCTAssertEqual(
            registry.resolve(bridgeSessionID: "session_abc123"), .ambiguous,
            "precondition: resolving now would abstain"
        )
        XCTAssertFalse(
            joinResolver.isStillLive(join),
            "a join whose key stopped being unique must not survive to commit"
        )
    }

    // The mirror of the above, in the direction that matters for a hostile
    // reporter: the JOINED session is the one that keeps reporting, and a rival
    // arriving late still kills the join rather than silently swapping it.
    func testALateCollisionNeverSwapsTheJoinedSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s1", claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertNotNil(registry.ingest(record(session: "s2"), origin: local))
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    // A session that is superseded by a NEW Remote Control connection (new
    // browser session id) likewise stops being the session this dictation
    // joined.
    func testSupersededBridgeSessionAgesTheJoinOut() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertNotNil(registry.ingest(record(bridgeSessionID: "session_zzz"), origin: local))
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    // The REMOTE mirror of the disconnect test above, and the half of review
    // finding 3 (codex, PR #218) that is actionable here. A remote session's
    // bridge id lives in `remoteEnvironment`, which the reducer replaces WHOLE
    // on the next non-focus report — so the first post-disconnect hook that
    // carries any env value at all (the bundled shim always sends `$PPID`,
    // `X-Lvx-Env-Hook-Parent-Pid`) drops the bridge id and kills the join.
    func testDisconnectedRemoteSessionAgesTheJoinOutOnItsNextReport() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        XCTAssertTrue(joinResolver.isStillLive(join))

        // Remote Control ended; the session keeps hooking, and the shim keeps
        // reporting what it CAN see — which no longer includes a bridge id.
        XCTAssertNotNil(
            registry.ingest(
                record(claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(hookParentPID: "4321")
            )
        )
        XCTAssertFalse(
            joinResolver.isStillLive(join),
            "a remote session that stopped reporting the bridge must not stay joined"
        )
    }

    // The residual of review finding 3, pinned rather than silently carried.
    //
    // A remote hook carrying NO allowlisted env header at all is not a
    // retraction: `ClaudeSessionReducer` deliberately keeps the last non-empty
    // report (#216, `testAnEnvironmentWithNothingUsableLeavesTheSnapshotUntouched`
    // — "an empty report is not a retraction"), so such a session keeps its
    // bridge binding until TTL. That rule is #216's to change, not this arm's;
    // this test exists so that if it ever DOES change, the consequence for the
    // browser join is visible here rather than discovered in the field.
    //
    // Why it is not a hole worth overturning that rule for: the bundled shim
    // always sends `$PPID`, so an honest disconnect takes the path above; and a
    // host dishonest enough to strip its headers can simply keep sending the
    // bridge id instead, which retention does not make easier. A CONTESTED id
    // still fails closed at commit — see the collision tests.
    func testRemoteSessionWithNoEnvHeadersAtAllRetainsItsBindingUntilTTL() async throws {
        let clock = BrowserJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(
            registry.ingest(
                record(claudePID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_abc123")
            )
        )
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)

        // A hook with no env headers whatsoever: the listener passes nil.
        XCTAssertNotNil(registry.ingest(record(claudePID: nil), origin: remote, environment: nil))
        XCTAssertTrue(
            joinResolver.isStillLive(join),
            "documented residual: an empty report is not a retraction (#216)"
        )
        // TTL is what ends it, and it does end it.
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    func testEndedSessionIsNotLive() async throws {
        let clock = BrowserJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, tabURL: sessionURL)
        let resolved = await joinResolver.resolve(target: chrome)
        let join = try XCTUnwrap(resolved)
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    // MARK: - Registry arm

    func testRegistryResolvesLocalAndRemoteBridgeIDs() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil, bridgeSessionID: nil),
                origin: remote,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_remote")
            )
        )
        guard case .resolved(let localSnapshot) =
            registry.resolve(bridgeSessionID: "session_abc123")
        else { return XCTFail("local bridge id must resolve") }
        XCTAssertEqual(localSnapshot.sessionID, "s1")
        guard case .resolved(let remoteSnapshot) =
            registry.resolve(bridgeSessionID: "session_remote")
        else { return XCTFail("remote bridge id must resolve") }
        XCTAssertEqual(remoteSnapshot.sessionID, "s2")
        XCTAssertEqual(registry.resolve(bridgeSessionID: "session_nobody"), .unknown)
    }

    // A remote session's env labels must not be readable as if they were a
    // local session's process metadata, and vice versa: the accessor routes by
    // origin, which is what keeps the two stores apart.
    func testBridgeSessionIDIsReadFromTheOriginsOwnStore() {
        let registry = makeRegistry()
        // A LOCAL record with a remote-style environment attached: the reducer
        // drops the environment for a local origin, so nothing resolves.
        XCTAssertNotNil(
            registry.ingest(
                record(bridgeSessionID: nil),
                origin: local,
                environment: ClaudeRemoteSessionEnvironment(bridgeSessionID: "session_smuggled")
            )
        )
        XCTAssertEqual(registry.resolve(bridgeSessionID: "session_smuggled"), .unknown)
    }

    func testRegistryReportsStaleRatherThanUnknownForAnExpiredSession() {
        let clock = BrowserJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertEqual(registry.resolve(bridgeSessionID: "session_abc123"), .stale)
    }

    // MARK: - Allowlists

    // The two lists grant different capabilities (screen text vs one URL
    // string), and the resolver's browser branch runs BEFORE the terminal
    // allowlist check — an overlap would silently reroute a terminal.
    func testBrowserAndTerminalAllowlistsAreDisjoint() {
        XCTAssertTrue(
            BrowserTabAllowlist.supportedBundleIDs
                .isDisjoint(with: TerminalScreenAllowlist.supportedBundleIDs)
        )
        for bundleID in BrowserTabAllowlist.supportedBundleIDs {
            XCTAssertFalse(
                TerminalScreenAllowlist.isSupported(bundleID),
                "\(bundleID) must never be screen-readable"
            )
            XCTAssertFalse(TerminalScreenAllowlist.isAXCaptureSupported(bundleID))
            XCTAssertFalse(TerminalScreenAllowlist.isAppleScriptCaptureSupported(bundleID))
        }
    }

    func testAllowlistIsExactMatch() {
        XCTAssertTrue(BrowserTabAllowlist.isSupported("com.google.Chrome"))
        XCTAssertTrue(BrowserTabAllowlist.isSupported("com.brave.Browser"))
        XCTAssertTrue(BrowserTabAllowlist.isSupported("com.apple.Safari"))
        for bundleID in [
            "com.google.Chrome.canary", "com.google.Chrom", "org.mozilla.firefox",
            "com.apple.SafariTechnologyPreview", "", "COM.GOOGLE.CHROME",
        ] {
            XCTAssertFalse(BrowserTabAllowlist.isSupported(bundleID), "\(bundleID) must not match")
        }
        XCTAssertFalse(BrowserTabAllowlist.isSupported(nil))
    }

    // MARK: - The AppleScript surface (source only — no Apple event is sent)

    func testEverySupportedBrowserHasAScriptSource() {
        for bundleID in BrowserTabAllowlist.supportedBundleIDs {
            XCTAssertNotNil(
                AppleScriptFocusedBrowserTabURLReader.scriptSource(forBundleID: bundleID),
                "\(bundleID) is allowlisted but has no script"
            )
            XCTAssertNotNil(
                AppleScriptFocusedBrowserTabURLReader.consentPrewarmScriptSource(
                    forBundleID: bundleID
                )
            )
        }
        XCTAssertNil(
            AppleScriptFocusedBrowserTabURLReader.scriptSource(forBundleID: "org.mozilla.firefox")
        )
    }

    // Chromium forks share Chrome's dictionary (`active tab`); Safari has its
    // own (`current tab`). Each script addresses its own bundle id.
    func testScriptSourcesUseThePerBrowserPropertyChain() throws {
        let chromeScript = try XCTUnwrap(
            AppleScriptFocusedBrowserTabURLReader.scriptSource(
                forBundleID: BrowserTabAllowlist.chromeBundleID
            )
        )
        XCTAssertTrue(chromeScript.contains("URL of active tab of front window"))
        XCTAssertTrue(chromeScript.contains("tell application id \"com.google.Chrome\""))
        let braveScript = try XCTUnwrap(
            AppleScriptFocusedBrowserTabURLReader.scriptSource(
                forBundleID: BrowserTabAllowlist.braveBundleID
            )
        )
        XCTAssertTrue(braveScript.contains("URL of active tab of front window"))
        XCTAssertTrue(braveScript.contains("tell application id \"com.brave.Browser\""))
        let safariScript = try XCTUnwrap(
            AppleScriptFocusedBrowserTabURLReader.scriptSource(
                forBundleID: BrowserTabAllowlist.safariBundleID
            )
        )
        XCTAssertTrue(safariScript.contains("URL of current tab of front window"))
        XCTAssertTrue(safariScript.contains("tell application id \"com.apple.Safari\""))
    }

    // The dictation read is bounded at 1 s so a wedged browser cannot hold
    // session start hostage; the consent probe must outlive a human answering
    // the sheet (macOS tears the sheet down with the event — field bug
    // 2026-07-22).
    func testTimeoutsMatchTheTerminalReadersDiscipline() throws {
        let read = try XCTUnwrap(
            AppleScriptFocusedBrowserTabURLReader.scriptSource(
                forBundleID: BrowserTabAllowlist.safariBundleID
            )
        )
        XCTAssertTrue(read.contains("with timeout of 1 second"))
        let probe = try XCTUnwrap(
            AppleScriptFocusedBrowserTabURLReader.consentPrewarmScriptSource(
                forBundleID: BrowserTabAllowlist.safariBundleID
            )
        )
        XCTAssertTrue(probe.contains("with timeout of 600 seconds"))
    }

    // The consent pre-warm must find a probe for a BROWSER too, or the sheet
    // could never be answered and the join would never become usable.
    //
    // The terminal half is `appleEventBundleIDs`, NOT every supported bundle:
    // a supported terminal need not be an automated one. cmux is joined and
    // read entirely over its own control socket and ships no scripting
    // dictionary, so an Apple event to it could only raise a consent prompt
    // for a capability that does not exist — and a probe would be the thing
    // raising it. That cmux is never sent one is asserted separately
    // (`CmuxSurfaceJoinTests.testCmuxIsNeverSentAnAppleEvent`), so this test
    // keeps its own meaning: everything we DO automate can be consented to.
    func testConsentPrewarmHasAProbeForEveryAutomatedApp() {
        for bundleID in BrowserTabAllowlist.supportedBundleIDs
            .union(TerminalScreenAllowlist.appleEventBundleIDs) {
            let source = AppleScriptTerminalTTYReader.consentPrewarmScriptSource(
                forBundleID: bundleID
            ) ?? AppleScriptFocusedBrowserTabURLReader.consentPrewarmScriptSource(
                forBundleID: bundleID
            )
            XCTAssertNotNil(source, "\(bundleID) is automated but has no consent probe")
        }
    }

    // Shape-only validation of the reply. A URL is content: the reader neither
    // logs it nor interprets it, it only rejects things that cannot be one.
    func testReplyValidationRejectsNonURLShapes() {
        XCTAssertEqual(
            AppleScriptFocusedBrowserTabURLReader.validatedURL("https://claude.ai/code/session_a"),
            "https://claude.ai/code/session_a"
        )
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL(nil))
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL(""))
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL("https://a b.com/"))
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL("https://x.com/\nGET /"))
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL("https://x.com/\u{0000}"))
        XCTAssertNil(AppleScriptFocusedBrowserTabURLReader.validatedURL("https://exämple.com/"))
        XCTAssertNil(
            AppleScriptFocusedBrowserTabURLReader.validatedURL(
                "https://claude.ai/code/" + String(repeating: "a", count: 3000)
            )
        )
    }
}
