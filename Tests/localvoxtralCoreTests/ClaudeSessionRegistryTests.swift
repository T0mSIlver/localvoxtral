import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

// Each helper's closure captures `[self]`, not the `Mutex` itself: `Mutex` is
// ~Copyable, so a capture-list entry naming it cannot compile (it would have to
// copy or consume a stored property). Capturing self also keeps the helper
// alive — `makeRegistry` builds these as temporaries that nothing else retains,
// so a borrow-style capture would leave the closure pointing at freed memory.

/// Test clock. The registry never reads the wall clock itself, so TTL and
/// staleness are exercised by moving this — no sleeps, no timing tolerance
/// (AGENTS: no wall-clock in tests).
private final class TestClock: Sendable {
    private let value: Mutex<Date>

    init(_ start: Date) { value = Mutex(start) }

    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }

    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// Controllable liveness probe.
private final class TestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])

    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }

    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

final class ClaudeSessionRegistryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    private func record(
        _ event: ClaudeHookEvent,
        session: String = "s1",
        cwd: String? = "/repo",
        prompt: String? = nil,
        files: [ClaudeFileTouch] = [],
        claudePID: Int32? = nil,
        hookPID: Int32 = 777,
        tty: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: session,
            timestamp: 0,
            rawCwd: cwd,
            prompt: prompt,
            files: files,
            process: claudePID.map {
                ClaudeHookProcessInfo(
                    hookPID: hookPID,
                    claudePID: $0,
                    tty: tty,
                    herdrPaneID: herdrPaneID,
                    herdrSocketPath: herdrSocketPath
                )
            }
        )
    }

    private func makeRegistry(
        limits: ClaudeRegistryLimits = .default,
        clock: TestClock? = nil,
        liveness: TestLiveness? = nil
    ) -> ClaudeSessionRegistry {
        return ClaudeSessionRegistry(
            limits: limits,
            now: (clock ?? TestClock(epoch)).now,
            isProcessAlive: (liveness ?? TestLiveness()).probe
        )
    }

    // MARK: Ingest and origin

    func testIngestCreatesSessionKeyedByItsOwnID() throws {
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(record(.sessionStart), origin: local))
        XCTAssertEqual(snapshot.sessionID, "s1")
        XCTAssertEqual(snapshot.origin, local)
        XCTAssertNotNil(
            registry.snapshot(sessionID: "s1"),
            "the session id IS the handle — there is no second identifier to allocate"
        )
    }

    func testBrokerSuppliedOriginIsAuthoritative() throws {
        let registry = makeRegistry()
        let remote = ClaudeTransportOrigin.remote(channel: "ssh")
        let snapshot = try XCTUnwrap(registry.ingest(record(.sessionStart), origin: remote))
        XCTAssertEqual(snapshot.origin, remote)
        XCTAssertNil(snapshot.localWorkspacePath, "remote sessions expose no local path")
        XCTAssertEqual(snapshot.workspace, .remoteOpaque(label: "repo"))
    }

    func testRemoteRecordCannotHijackAnExistingLocalSession() throws {
        // A remote peer replaying a local session id must not be able to move
        // that session's cwd (which local collectors may act on).
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, cwd: "/local/repo"), origin: local)

        let hijack = registry.ingest(
            record(.cwdChanged, cwd: "/attacker/repo"), origin: .remote(channel: "ssh")
        )
        XCTAssertNil(hijack, "a remote record for a local session id is dropped whole")

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "s1"))
        XCTAssertEqual(snapshot.origin, local)
        XCTAssertEqual(snapshot.localWorkspacePath?.path, "/local/repo", "unchanged")
    }

    func testSessionEndForUnknownSessionCreatesNothing() {
        let registry = makeRegistry()
        XCTAssertNil(registry.ingest(record(.sessionEnd), origin: local))
        XCTAssertTrue(registry.liveSessions().isEmpty)
    }

    func testStatusQueryIsRefusedByIngestAndNeitherCreatesNorRefreshes() throws {
        // The broker answers StatusQuery BEFORE ingest; this is the backstop
        // behind it. An ingested probe would create a session for an id
        // nobody ever hooked — or refresh the activity of a dying one, keeping
        // alive the very state it exists to report on.
        let registry = makeRegistry()
        XCTAssertNil(registry.ingest(record(.statusQuery), origin: local))
        XCTAssertNil(registry.snapshot(sessionID: "s1"), "a probe must not create a session")
        XCTAssertTrue(registry.liveSessions().isEmpty)

        let clock = TestClock(epoch)
        let refreshable = makeRegistry(clock: clock)
        refreshable.ingest(record(.sessionStart), origin: local)
        let before = try XCTUnwrap(refreshable.snapshot(sessionID: "s1")).lastActivity
        clock.advance(60)
        XCTAssertNil(refreshable.ingest(record(.statusQuery), origin: local))
        XCTAssertEqual(
            try XCTUnwrap(refreshable.snapshot(sessionID: "s1")).lastActivity, before,
            "a probe must not count as session activity"
        )
    }

    func testIngestAccumulatesAcrossEvents() throws {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart), origin: local)
        registry.ingest(record(.userPromptSubmit, prompt: "add the broker"), origin: local)
        registry.ingest(
            record(.postToolUse, files: [ClaudeFileTouch(path: "/repo/a.swift", kind: .edited)]),
            origin: local
        )
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "s1"))
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "add the broker")
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["/repo/a.swift"])
    }

    // MARK: SessionEnd eviction

    func testSessionEndEvictsImmediatelyButReturnsFinalSnapshot() throws {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart), origin: local)
        let final = try XCTUnwrap(registry.ingest(record(.sessionEnd), origin: local))
        XCTAssertEqual(final.activity, .ended)
        XCTAssertNil(registry.snapshot(sessionID: "s1"))
        XCTAssertTrue(registry.liveSessions().isEmpty)
    }

    func testSessionEndMakesTheSessionUnresolvableByID() {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        XCTAssertNotNil(registry.snapshot(sessionID: "s1"))
        registry.ingest(record(.sessionEnd, session: "s1"), origin: local)
        XCTAssertNil(registry.snapshot(sessionID: "s1"))

        // And the id is free again: a NEW session that spells the same id is a
        // new entry, not a resurrection of the evicted one.
        registry.ingest(
            record(.sessionStart, session: "s1", cwd: "/other"), origin: local
        )
        let reused = registry.snapshot(sessionID: "s1")
        XCTAssertEqual(reused?.localWorkspacePath?.path, "/other")
    }

    // MARK: Session lookup — abstention
    //
    // `snapshot(sessionID:)` is the lookup commit-time liveness runs through
    // (`ClaudeSessionJoinResolver.isStillLive`), and it applies the SAME
    // freshness rule — TTL plus, locally, pid liveness — that every join arm's
    // `resolve(...)` applies. These pin that rule; the arm-specific lookups
    // below pin the matching.

    func testUnknownSessionIDResolvesToNothing() {
        let registry = makeRegistry()
        XCTAssertNil(registry.snapshot(sessionID: "nope"))
    }

    func testASessionGoesStaleAfterTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 100),
            clock: clock
        )
        registry.ingest(record(.sessionStart), origin: local)

        clock.advance(99)
        XCTAssertNotNil(registry.snapshot(sessionID: "s1"), "still inside TTL")

        clock.advance(2) // now 101 > TTL
        XCTAssertNil(registry.snapshot(sessionID: "s1"))
    }

    func testActivityRefreshesTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 100),
            clock: clock
        )
        registry.ingest(record(.sessionStart), origin: local)
        clock.advance(90)
        registry.ingest(record(.stop), origin: local)
        clock.advance(90) // 180 since start, but only 90 since last activity
        XCTAssertNotNil(
            registry.snapshot(sessionID: "s1"),
            "activity should have refreshed the TTL"
        )
    }

    func testDeadClaudeProcessMakesASessionStaleBeforeTTLExpires() {
        // Claude Code can die without firing SessionEnd (SIGKILL, closed
        // terminal), so TTL alone would keep a ghost session resolvable.
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(record(.sessionStart, claudePID: 4242), origin: local)
        XCTAssertNotNil(registry.snapshot(sessionID: "s1"), "alive session should resolve")

        liveness.kill(4242)
        XCTAssertNil(registry.snapshot(sessionID: "s1"))
    }

    func testPIDLessLocalSessionUsesTheShortExposureTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 4 * 60 * 60),
            clock: clock
        )
        registry.ingest(record(.sessionStart), origin: local)

        clock.advance(5 * 60 + 1)

        XCTAssertNil(
            registry.snapshot(sessionID: "s1"),
            "without a Claude pid to probe, a dead local session must not remain joinable for four hours"
        )
    }

    /// Regression, production-shaped: the publisher is a one-shot process, so
    /// by the time the app looks at a record the `hookPID` is ALWAYS dead. If
    /// liveness probes it, every local session is stale the instant it is
    /// created and the whole feature silently returns nothing.
    ///
    /// This reproduces the real arrangement — dead hook pid, live Claude pid —
    /// rather than asserting on the field name.
    func testLivenessProbesClaudePIDNotTheShortLivedHookPID() throws {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)

        // Exactly what production looks like a millisecond after the hook ran.
        liveness.kill(31_337) // the publisher: exited the moment it wrote its line
        registry.ingest(
            record(.sessionStart, claudePID: 4242, hookPID: 31_337), origin: local
        )

        let snapshot = try XCTUnwrap(
            registry.snapshot(sessionID: "s1"),
            "a live Claude session must resolve even though the hook process is gone"
        )
        XCTAssertEqual(snapshot.process?.claudePID, 4242)
        XCTAssertEqual(snapshot.process?.hookPID, 31_337)

        // And the session does go stale when CLAUDE dies — proving liveness is
        // wired to the right pid rather than simply disabled.
        liveness.kill(4242)
        XCTAssertNil(registry.snapshot(sessionID: "s1"))
    }

    func testRemoteSessionPidIsNotProbedForLiveness() {
        // A remote pid names a process on another machine; probing it locally
        // would be meaningless (and could match an unrelated local process).
        let liveness = TestLiveness()
        liveness.kill(4242)
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(record(.sessionStart, claudePID: 4242), origin: .remote(channel: "ssh"))
        XCTAssertNotNil(
            registry.snapshot(sessionID: "s1"),
            "remote sessions rely on TTL, not local pid liveness"
        )
    }


    // MARK: TTY lookup — the focus join

    func testTTYLookupResolvesTheLocalSessionOnThatDevice() throws {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, tty: "/dev/ttys003"), origin: local
        )
        guard case .resolved(let snapshot) = registry.resolve(tty: "/dev/ttys003") else {
            return XCTFail("expected the session on that device")
        }
        XCTAssertEqual(snapshot.sessionID, "s1")
    }

    func testTTYLookupNeverMatchesARemoteSession() {
        // The spoof this closes: a remote session's TTY names a device on
        // ANOTHER machine. If an SSH host could publish "/dev/ttys003" and
        // match a local pane, it would claim that pane's dictations — so
        // remote candidates are refused outright, even on exact match.
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, tty: "/dev/ttys003"),
            origin: .remote(channel: "ssh")
        )
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys003"), .unknown)
    }

    func testTwoLocalSessionsOnOneTTYAbstainAsAmbiguous() {
        // A suspended Claude beneath a new one in the same pane. Guessing
        // would attribute one session's repo to the other's dictation.
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, session: "s1", claudePID: 9001, tty: "/dev/ttys003"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "s2", claudePID: 9002, tty: "/dev/ttys003"),
            origin: local
        )
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys003"), .ambiguous)
    }

    func testTTYLookupReportsStaleWhenTheOnlyMatchIsDead() {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(
            record(.sessionStart, claudePID: 9001, tty: "/dev/ttys003"), origin: local
        )
        liveness.kill(9001)
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys003"), .stale)
    }

    func testTTYLookupIsUnknownForAnUnseenDevice() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, tty: "/dev/ttys003"), origin: local
        )
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys007"), .unknown)
    }

    // MARK: herdr pane lookup — the inner-pane focus join

    func testHerdrPaneLookupResolvesTheLocalSessionInThatPane() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, herdrPaneID: "pane-7"),
            origin: local
        )
        guard case .resolved(let snapshot) = registry.resolve(herdrPaneID: "pane-7") else {
            return XCTFail("expected the session in that herdr pane")
        }
        XCTAssertEqual(snapshot.sessionID, "s1")
    }

    func testHerdrPaneLookupIsUnknownForAnUnseenPane() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, herdrPaneID: "pane-7"),
            origin: local
        )
        XCTAssertEqual(registry.resolve(herdrPaneID: "pane-other"), .unknown)
    }

    func testHerdrPaneLookupReportsStaleWhenTheOnlyMatchIsDead() {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(
            record(.sessionStart, claudePID: 9001, herdrPaneID: "pane-7"),
            origin: local
        )
        liveness.kill(9001)
        XCTAssertEqual(registry.resolve(herdrPaneID: "pane-7"), .stale)
    }

    func testTwoLocalSessionsInOneHerdrPaneAbstainAsAmbiguous() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, session: "s1", claudePID: 9001, herdrPaneID: "pane-7"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "s2", claudePID: 9002, herdrPaneID: "pane-7"),
            origin: local
        )
        XCTAssertEqual(registry.resolve(herdrPaneID: "pane-7"), .ambiguous)
    }

    func testHerdrPaneLookupNeverMatchesARemoteSession() {
        // Pane ids belong to one machine's herdr. A remote host echoing a local
        // id must not be able to claim dictation focused in that local pane.
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, claudePID: 9001, herdrPaneID: "pane-7"),
            origin: .remote(channel: "ssh")
        )
        XCTAssertEqual(registry.resolve(herdrPaneID: "pane-7"), .unknown)
    }

    func testLiveLocalHerdrSocketPathsAreDistinct() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, session: "s1", claudePID: 9001, herdrSocketPath: "/tmp/a.sock"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "s2", claudePID: 9002, herdrSocketPath: "/tmp/a.sock"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "s3", claudePID: 9003, herdrSocketPath: "/tmp/b.sock"),
            origin: local
        )
        XCTAssertEqual(registry.liveLocalHerdrSocketPaths(), ["/tmp/a.sock", "/tmp/b.sock"])
    }

    func testLiveLocalHerdrSocketPathsExcludeStaleSessions() {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(
            record(.sessionStart, session: "live", claudePID: 9001, herdrSocketPath: "/tmp/live.sock"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "dead", claudePID: 9002, herdrSocketPath: "/tmp/dead.sock"),
            origin: local
        )
        liveness.kill(9002)
        XCTAssertEqual(registry.liveLocalHerdrSocketPaths(), ["/tmp/live.sock"])
    }

    func testLiveLocalHerdrSocketPathsExcludeRemoteSessions() {
        let registry = makeRegistry()
        registry.ingest(
            record(.sessionStart, session: "local", claudePID: 9001, herdrSocketPath: "/tmp/local.sock"),
            origin: local
        )
        registry.ingest(
            record(.sessionStart, session: "remote", claudePID: 9002, herdrSocketPath: "/tmp/remote.sock"),
            origin: .remote(channel: "ssh")
        )
        XCTAssertEqual(registry.liveLocalHerdrSocketPaths(), ["/tmp/local.sock"])
    }

    // MARK: Workspace lookup — ambiguity

    func testWorkspaceLookupResolvesSingleMatch() throws {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, cwd: "/repo"), origin: local)
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/repo", origin: local)?.localPath
        )
        guard case .resolved(let snapshot) = registry.resolve(workspace: workspace) else {
            return XCTFail("expected a single match")
        }
        XCTAssertEqual(snapshot.sessionID, "s1")
    }

    func testTwoSessionsInOneWorkspaceAbstainAsAmbiguous() throws {
        // Two terminal tabs in one repo is the COMMON case, not an edge case.
        // Guessing here would silently attribute the wrong session's context.
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, session: "s1", cwd: "/repo"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2", cwd: "/repo"), origin: local)
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/repo", origin: local)?.localPath
        )
        XCTAssertEqual(registry.resolve(workspace: workspace), .ambiguous)
    }

    func testWorkspaceLookupUnknownWhenNothingMatches() throws {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, cwd: "/repo"), origin: local)
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/elsewhere", origin: local)?.localPath
        )
        XCTAssertEqual(registry.resolve(workspace: workspace), .unknown)
    }

    func testWorkspaceLookupReportsStaleRatherThanUnknown() throws {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 10),
            clock: clock
        )
        registry.ingest(record(.sessionStart, cwd: "/repo"), origin: local)
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/repo", origin: local)?.localPath
        )
        clock.advance(11)
        XCTAssertEqual(registry.resolve(workspace: workspace), .stale)
    }

    func testRemoteSessionIsNeverFoundByWorkspaceLookup() throws {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, cwd: "/repo"), origin: .remote(channel: "ssh"))
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/repo", origin: local)?.localPath
        )
        XCTAssertEqual(registry.resolve(workspace: workspace), .unknown)
    }

    // MARK: Cap and pruning

    func testRegistryCapEvictsLeastRecentlyActive() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 2, sessionTTL: 10_000),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "oldest"), origin: local)
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "middle"), origin: local)
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "newest"), origin: local)

        XCTAssertNil(registry.snapshot(sessionID: "oldest"))
        XCTAssertNotNil(registry.snapshot(sessionID: "middle"))
        XCTAssertNotNil(registry.snapshot(sessionID: "newest"))
        XCTAssertEqual(registry.liveSessions().count, 2)
    }

    func testCapEvictedSessionIsGoneFromEveryLookup() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 1, sessionTTL: 10_000),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        XCTAssertNil(
            registry.snapshot(sessionID: "s1"),
            "an evicted session must not linger anywhere a join could reach it"
        )
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["s2"])
    }

    func testOneOriginsBurstCannotEvictAnotherOriginsLiveSession() {
        let clock = TestClock(epoch)
        let quietOrigin = ClaudeTransportOrigin.remote(channel: "ssh:quiet")
        let burstingOrigin = ClaudeTransportOrigin.remote(channel: "ssh:burst")
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 4, sessionTTL: 10_000),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "quiet"), origin: quietOrigin)
        for index in 1...4 {
            clock.advance(1)
            registry.ingest(
                record(.sessionStart, session: "burst-\(index)"),
                origin: burstingOrigin
            )
        }

        XCTAssertNotNil(
            registry.snapshot(sessionID: "quiet"),
            "one origin's churn must consume its own quota before evicting another origin"
        )
        XCTAssertEqual(
            registry.liveSessions().filter { $0.origin == burstingOrigin }.count,
            3
        )
    }

    /// A lastActivity tie plus a lexically-small sessionID must not make quota
    /// eviction select the record that triggered it: the just-upserted session
    /// is pinned and the oldest tied sibling goes instead.
    func testQuotaEvictionNeverSelectsTheJustUpsertedSession() {
        let clock = TestClock(epoch)
        let quietOrigin = ClaudeTransportOrigin.remote(channel: "ssh:quiet")
        let burstingOrigin = ClaudeTransportOrigin.remote(channel: "ssh:burst")
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 4, sessionTTL: 10_000),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "quiet"), origin: quietOrigin)
        for index in 1...3 {
            registry.ingest(
                record(.sessionStart, session: "z-\(index)"),
                origin: burstingOrigin
            )
        }
        // Frozen clock: every bursting session shares one lastActivity, and
        // "a-new" sorts lexically FIRST — the exact shape that made the
        // sessionID tiebreak evict the newest data.
        registry.ingest(record(.sessionStart, session: "a-new"), origin: burstingOrigin)

        XCTAssertNotNil(
            registry.snapshot(sessionID: "a-new"),
            "the session that triggered quota enforcement must never be its victim"
        )
        XCTAssertNil(registry.snapshot(sessionID: "z-1"))
        XCTAssertEqual(
            registry.liveSessions().filter { $0.origin == burstingOrigin }.count,
            3
        )
    }

    // MARK: Claude Desktop sessions (#657)

    private let desktopHost = ClaudeTransportOrigin.remote(channel: "ssh:desktop-host")

    private func ingestDesktopSession(
        _ registry: ClaudeSessionRegistry, session: String, desktopID: String
    ) {
        XCTAssertNotNil(registry.ingest(
            record(.sessionStart, session: session, cwd: "/srv/repo"),
            origin: desktopHost,
            environment: ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)
        ))
    }

    /// The next hook of a Desktop session left idle is the UserPromptSubmit
    /// of the prompt being dictated, so the first dictation back used to find
    /// the record pruned.
    func testADesktopSessionIdleLongerThanTheSessionTTLStillJoins() throws {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        ingestDesktopSession(registry, session: "desktop", desktopID: "local_a")
        registry.ingest(record(.sessionStart, session: "terminal"), origin: desktopHost)

        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)

        guard case .resolved(let snapshot) = registry.resolve(desktopSessionID: "local_a") else {
            return XCTFail("an idle Desktop session must still join the view that shows it")
        }
        XCTAssertEqual(snapshot.sessionID, "desktop")
        XCTAssertNil(
            registry.snapshot(sessionID: "terminal"),
            "a session reporting no Desktop id keeps the ordinary TTL"
        )
    }

    func testADesktopSessionStillExpiresAfterAWeek() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        ingestDesktopSession(registry, session: "desktop", desktopID: "local_a")

        clock.advance(8 * 24 * 60 * 60)

        XCTAssertEqual(registry.resolve(desktopSessionID: "local_a"), .stale)
    }

    /// The owner's host ran 18 Desktop sessions at once. When a host must
    /// lose a record, the least recently active used to go first whatever it
    /// was.
    func testTheCapEvictsSessionsWithoutADesktopIDFirst() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 3),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "mac-local"), origin: local)
        ingestDesktopSession(registry, session: "desktop", desktopID: "local_a")
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "terminal-1"), origin: desktopHost)
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "terminal-2"), origin: desktopHost)

        guard case .resolved = registry.resolve(desktopSessionID: "local_a") else {
            return XCTFail("the idle Desktop session must outlast a newer terminal session")
        }
        XCTAssertNotNil(registry.snapshot(sessionID: "mac-local"))
        XCTAssertNil(registry.snapshot(sessionID: "terminal-1"))
        XCTAssertNotNil(registry.snapshot(sessionID: "terminal-2"))
    }

    func testANewSessionStillRegistersWhenTheCapIsFullOfDesktopSessions() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 2),
            clock: clock
        )
        ingestDesktopSession(registry, session: "desktop-1", desktopID: "local_a")
        clock.advance(1)
        ingestDesktopSession(registry, session: "desktop-2", desktopID: "local_b")
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "terminal"), origin: desktopHost)

        XCTAssertNotNil(
            registry.snapshot(sessionID: "terminal"),
            "the record that triggered the cap must never be its victim"
        )
        XCTAssertNil(registry.snapshot(sessionID: "desktop-1"))
        XCTAssertNotNil(registry.snapshot(sessionID: "desktop-2"))
    }

    // MARK: More Desktop sessions than the per-origin quota (#672)

    /// The owner's ssh host ran 18 Desktop sessions at once, next to local
    /// sessions, and the per-origin quota of 8 evicted ten of them.
    func testEighteenDesktopSessionsOnOneHostStayResolvableBesideALocalSession() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        registry.ingest(record(.sessionStart, session: "mac-local"), origin: local)
        for index in 1...18 {
            clock.advance(1)
            ingestDesktopSession(registry, session: "desktop-\(index)", desktopID: "local_\(index)")
        }

        XCTAssertNotNil(registry.snapshot(sessionID: "mac-local"))
        for index in 1...18 {
            guard case .resolved = registry.resolve(desktopSessionID: "local_\(index)") else {
                return XCTFail("Desktop session \(index) of 18 must still join")
            }
        }
    }

    /// An enrolled host can send any desktop id it likes, so a desktop id
    /// buys room only inside its own origin's Desktop quota.
    func testAFloodOfDesktopIDsEvictsOnlyTheFloodingHostsRecords() {
        let clock = TestClock(epoch)
        let floodingHost = ClaudeTransportOrigin.remote(channel: "ssh:flood")
        let otherHost = ClaudeTransportOrigin.remote(channel: "ssh:other")
        let registry = makeRegistry(clock: clock)
        registry.ingest(record(.sessionStart, session: "mac-local"), origin: local)
        registry.ingest(record(.sessionStart, session: "other-host"), origin: otherHost)
        for index in 1...100 {
            clock.advance(1)
            registry.ingest(
                record(.sessionStart, session: "flood-\(index)"),
                origin: floodingHost,
                environment: ClaudeRemoteSessionEnvironment(desktopSessionID: "local_\(index)")
            )
        }

        XCTAssertNotNil(registry.snapshot(sessionID: "mac-local"))
        XCTAssertNotNil(registry.snapshot(sessionID: "other-host"))
        XCTAssertEqual(
            registry.liveSessions().filter { $0.origin == floodingHost }.count,
            ClaudeRegistryLimits.defaultMaxDesktopSessionsPerOrigin
        )
        XCTAssertNotNil(registry.snapshot(sessionID: "flood-100"))
    }

    /// Over the global cap, the victim comes from the origin holding the most
    /// records, however old another origin's records are.
    func testTheGlobalCapEvictsFromTheLargestOrigin() {
        let clock = TestClock(epoch)
        let busyHost = ClaudeTransportOrigin.remote(channel: "ssh:busy")
        let newHost = ClaudeTransportOrigin.remote(channel: "ssh:new")
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 6, sessionTTL: 10_000),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "local-1"), origin: local)
        registry.ingest(record(.sessionStart, session: "local-2"), origin: local)
        for index in 1...4 {
            clock.advance(1)
            registry.ingest(record(.sessionStart, session: "busy-\(index)"), origin: busyHost)
        }
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "new"), origin: newHost)

        XCTAssertNotNil(registry.snapshot(sessionID: "local-1"))
        XCTAssertNotNil(registry.snapshot(sessionID: "local-2"))
        XCTAssertNotNil(registry.snapshot(sessionID: "new"))
        XCTAssertNil(registry.snapshot(sessionID: "busy-1"))
        XCTAssertEqual(registry.liveSessions().count, 6)
    }

    func testStaleSessionsArePrunedOnIngest() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 10),
            clock: clock
        )
        registry.ingest(record(.sessionStart, session: "old"), origin: local)
        clock.advance(50)
        registry.ingest(record(.sessionStart, session: "new"), origin: local)
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["new"])
        XCTAssertNil(registry.snapshot(sessionID: "old"))
    }

    func testLiveSessionsAreOrderedMostRecentlyActiveFirst() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        registry.ingest(record(.sessionStart, session: "first"), origin: local)
        clock.advance(5)
        registry.ingest(record(.sessionStart, session: "second"), origin: local)
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["second", "first"])
    }

    // `hasLiveSessions` exists so the overlay's join badge can ask about
    // emptiness without materializing every session's files and snippets. It
    // must answer exactly what `liveSessions().isEmpty` would — including
    // across the TTL, or the badge would report "no Claude session" for a live
    // one, or complain about sessions that have already aged out.
    func testHasLiveSessionsTracksLiveSessionsExactly() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertFalse(registry.hasLiveSessions())
        XCTAssertEqual(registry.hasLiveSessions(), !registry.liveSessions().isEmpty)

        registry.ingest(record(.sessionStart), origin: local)
        XCTAssertTrue(registry.hasLiveSessions())
        XCTAssertEqual(registry.hasLiveSessions(), !registry.liveSessions().isEmpty)

        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertFalse(registry.hasLiveSessions(), "a session past its TTL is not live")
        XCTAssertEqual(registry.hasLiveSessions(), !registry.liveSessions().isEmpty)
    }

    func testExplicitEvictAndRemoveAll() {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        registry.evict(sessionID: "s1")
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["s2"])
        registry.removeAll()
        XCTAssertTrue(registry.liveSessions().isEmpty)
        XCTAssertNil(registry.snapshot(sessionID: "s2"))
    }

    // MARK: Remote host eviction

    /// Sessions for four origins: two SSH hosts, another remote transport, and
    /// a local peer-authenticated process.
    private func makeMixedOriginRegistry() -> ClaudeSessionRegistry {
        let registry = makeRegistry()
        registry.ingest(record(.sessionStart, session: "remote:hgone:s1"), origin: .remote(channel: "ssh:hgone"))
        registry.ingest(record(.sessionStart, session: "remote:hkeep:s1"), origin: .remote(channel: "ssh:hkeep"))
        registry.ingest(record(.sessionStart, session: "relay:s1"), origin: .remote(channel: "relay"))
        registry.ingest(record(.sessionStart, session: "local-1"), origin: local)
        return registry
    }

    func testEvictingARemoteHostTakesItsSessions() {
        let registry = makeMixedOriginRegistry()

        let evicted = registry.evictRemoteSessions(notIn: ["ssh:hkeep"])

        XCTAssertEqual(evicted, 1)
        // Revocation means "that machine's context is no longer mine to use",
        // so the entry must be gone from every lookup a join could reach it
        // through — not merely absent from `liveSessions()`.
        XCTAssertNil(registry.snapshot(sessionID: "remote:hgone:s1"))
        XCTAssertFalse(
            registry.liveSessions().contains { $0.sessionID == "remote:hgone:s1" }
        )
    }

    func testEvictingOneRemoteHostLeavesSiblingsAndLocalSessionsAlone() throws {
        let registry = makeMixedOriginRegistry()

        registry.evictRemoteSessions(notIn: ["ssh:hkeep"])

        let sibling = try XCTUnwrap(
            registry.snapshot(sessionID: "remote:hkeep:s1"),
            "a sibling host's session is not collateral"
        )
        XCTAssertEqual(sibling.sessionID, "remote:hkeep:s1")
        XCTAssertEqual(
            Set(registry.liveSessions().map(\.sessionID)),
            ["remote:hkeep:s1", "relay:s1", "local-1"]
        )
    }

    func testEvictingEveryRemoteHostNeverTouchesLocalSessions() throws {
        // The 1→0 case: the last host is revoked, so no channel is active. Local
        // sessions are authenticated by peer credentials on our own socket and
        // have nothing to do with host enrollment — they must survive an empty
        // host registry.
        let registry = makeMixedOriginRegistry()

        XCTAssertEqual(registry.evictRemoteSessions(notIn: []), 2)

        XCTAssertEqual(Set(registry.liveSessions().map(\.sessionID)), ["relay:s1", "local-1"])
        let survivor = try XCTUnwrap(registry.snapshot(sessionID: "local-1"))
        XCTAssertEqual(survivor.origin, local)
        XCTAssertNotNil(
            registry.snapshot(sessionID: "relay:s1"),
            "another remote transport is not governed by SSH host enrollment"
        )
    }

    func testEvictingRemoteSessionsIsIdempotent() {
        // reconcile() calls this on every enrollment change, so it runs far more
        // often than it has work to do.
        let registry = makeMixedOriginRegistry()
        XCTAssertEqual(registry.evictRemoteSessions(notIn: ["ssh:hkeep"]), 1)
        XCTAssertEqual(registry.evictRemoteSessions(notIn: ["ssh:hkeep"]), 0, "nothing left to evict")
        XCTAssertNotNil(registry.snapshot(sessionID: "remote:hkeep:s1"))
    }

    // MARK: Submitted prompts

    /// Correction learning hears each submitted prompt once, under the scoped
    /// id the join carries, and hears nothing for any other event or an empty
    /// prompt.
    func testSubmittedPromptObserverHearsEachPromptOnce() {
        let registry = makeRegistry()
        let heard = Mutex<[String]>([])
        registry.setSubmittedPromptObserver { sessionID, prompt in
            heard.withLock { $0.append("\(sessionID)|\(prompt)") }
        }

        registry.ingest(record(.sessionStart), origin: local)
        registry.ingest(record(.userPromptSubmit, prompt: "fix the Qwen tokenizer"), origin: local)
        registry.ingest(record(.userPromptSubmit, prompt: ""), origin: local)
        registry.ingest(record(.postToolUse), origin: local)
        registry.ingest(record(.stop), origin: local)
        registry.ingest(
            record(.userPromptSubmit, session: "o1", prompt: "run it"),
            origin: local
        )

        XCTAssertEqual(heard.withLock { $0 }, ["s1|fix the Qwen tokenizer", "o1|run it"])
    }

    /// A prompt the registry refuses is not heard either: a record from the
    /// wrong origin must not teach a spelling to the session it names.
    func testRefusedPromptIsNotHeard() {
        let registry = makeRegistry()
        let heard = Mutex<Int>(0)
        registry.setSubmittedPromptObserver { _, _ in heard.withLock { $0 += 1 } }

        registry.ingest(record(.sessionStart), origin: local)
        registry.ingest(
            record(.userPromptSubmit, prompt: "fix the Qwen tokenizer"),
            origin: .remote(channel: "ssh")
        )

        XCTAssertEqual(heard.withLock { $0 }, 0)
    }
}

private final class MemoryClaudeSessionStore: ClaudeSessionStore, @unchecked Sendable {
    private let bytes = Mutex<Data?>(nil)
    private let clearCount = Mutex(0)

    init(_ data: Data? = nil) {
        bytes.withLock { $0 = data }
    }

    func load() throws -> Data? { bytes.withLock { $0 } }
    func save(_ data: Data) throws { bytes.withLock { $0 = data } }
    func clear() throws {
        bytes.withLock { $0 = nil }
        clearCount.withLock { $0 += 1 }
    }

    var data: Data? { bytes.withLock { $0 } }
    var clears: Int { clearCount.withLock { $0 } }
}

final class ClaudeSessionPersistenceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let hostID = "h12345678"
    private var channel: String { ClaudeRemoteSessionScope.channel(hostID: hostID) }
    private var remoteOrigin: ClaudeTransportOrigin { .remote(channel: channel) }

    private func registry(
        store: MemoryClaudeSessionStore,
        now: Date? = nil,
        alive: @escaping @Sendable (Int32) -> Bool = { _ in true },
        boot: String? = "boot-a",
        activeChannels: Set<String>? = nil,
        limits: ClaudeRegistryLimits = .default
    ) -> ClaudeSessionRegistry {
        let timestamp = now ?? epoch
        return ClaudeSessionRegistry(
            limits: limits,
            store: store,
            allowedRemoteChannels: activeChannels ?? [channel],
            now: { timestamp },
            isProcessAlive: alive,
            bootIdentity: { boot },
            localPeerUID: { 501 }
        )
    }

    private func localRecord(
        _ event: ClaudeHookEvent,
        prompt: String? = nil,
        claudePID: Int32 = 42
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: "local-session",
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/work/local",
            prompt: prompt,
            process: ClaudeHookProcessInfo(
                hookPID: 7,
                claudePID: claudePID,
                tty: "/dev/ttys007"
            )
        )
    }

    private func remoteRecord(_ event: ClaudeHookEvent) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                hostID: hostID,
                sessionID: "remote-session"
            ),
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/srv/secret-project"
        )
    }

    func testLocalAndRemoteSessionsSurviveRestartWithoutPersistingContent() throws {
        let store = MemoryClaudeSessionStore()
        let first = registry(store: store)
        first.ingest(
            localRecord(.userPromptSubmit, prompt: "private prompt must stay in memory"),
            origin: .localAuthenticated(peerUID: 501)
        )
        first.ingest(
            remoteRecord(.postToolUse),
            origin: remoteOrigin,
            snippets: [
                ClaudeContentSnippet(
                    label: "Edit new_string",
                    kind: .toolInput,
                    text: "private snippet must stay in memory"
                )
            ],
            environment: ClaudeRemoteSessionEnvironment(
                herdrPaneID: "pane-7",
                herdrSocketPath: "/run/user/501/herdr.sock"
            )
        )
        first.flushPersistence()

        let persisted = try XCTUnwrap(store.data)
        let text = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(text.contains("private prompt"))
        XCTAssertFalse(text.contains("private snippet"))
        XCTAssertFalse(text.contains("Edit new_string"))

        let restored = registry(store: store)
        guard case .resolved(let local) = restored.resolve(tty: "/dev/ttys007") else {
            return XCTFail("restored local session must resolve by tty")
        }
        XCTAssertEqual(local.sessionID, "local-session")
        XCTAssertNil(local.latestPriorUserPrompt)
        XCTAssertTrue(local.recentFiles.isEmpty)
        XCTAssertTrue(local.recentSnippets.isEmpty)

        let remote = restored.liveRemoteHerdrSessions(hostID: hostID)
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote[0].remoteSessionEnvironment?.herdrPaneID, "pane-7")
        XCTAssertEqual(
            remote[0].remoteSessionEnvironment?.herdrSocketPath,
            "/run/user/501/herdr.sock"
        )
        let paneMatches = restored.liveRemoteHerdrSessions(hostID: hostID).filter {
            $0.remoteSessionEnvironment?.herdrPaneID == "pane-7"
        }
        XCTAssertEqual(paneMatches.map(\.sessionID), [remote[0].sessionID])
    }

    func testRestoreDropsStaleDeadRebootedAndRevokedSessions() {
        let staleStore = MemoryClaudeSessionStore()
        let staleFirst = registry(
            store: staleStore,
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 10)
        )
        staleFirst.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        staleFirst.flushPersistence()
        let stale = registry(
            store: staleStore,
            now: epoch.addingTimeInterval(11),
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 10)
        )
        XCTAssertTrue(stale.liveSessions().isEmpty)

        let deadStore = MemoryClaudeSessionStore()
        let deadFirst = registry(store: deadStore)
        deadFirst.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        deadFirst.flushPersistence()
        XCTAssertTrue(registry(store: deadStore, alive: { $0 != 42 }).liveSessions().isEmpty)

        let rebootStore = MemoryClaudeSessionStore()
        let rebootFirst = registry(store: rebootStore, boot: "boot-a")
        rebootFirst.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        rebootFirst.flushPersistence()
        XCTAssertTrue(registry(store: rebootStore, boot: "boot-b").liveSessions().isEmpty)

        let revokedStore = MemoryClaudeSessionStore()
        let revokedFirst = registry(store: revokedStore)
        revokedFirst.ingest(remoteRecord(.sessionStart), origin: remoteOrigin)
        revokedFirst.flushPersistence()
        XCTAssertTrue(
            registry(store: revokedStore, activeChannels: []).liveRemoteSessions(hostID: hostID).isEmpty
        )
    }

    func testCorruptStoreRestoresNothingAndNextMutationReplacesIt() throws {
        let store = MemoryClaudeSessionStore(Data("not json".utf8))
        let corruptRegistry = registry(store: store)
        XCTAssertTrue(corruptRegistry.liveSessions().isEmpty)
        corruptRegistry.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        corruptRegistry.flushPersistence()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: XCTUnwrap(store.data)))

        let unknownVersion = MemoryClaudeSessionStore(Data(#"{"v":99,"sessions":[]}"#.utf8))
        let versionRegistry = registry(store: unknownVersion)
        XCTAssertTrue(versionRegistry.liveSessions().isEmpty)
        versionRegistry.ingest(
            localRecord(.sessionStart),
            origin: .localAuthenticated(peerUID: 501)
        )
        versionRegistry.flushPersistence()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: XCTUnwrap(unknownVersion.data)))
    }

    func testRemoveAllAndSessionEndAreDurable() {
        let removeStore = MemoryClaudeSessionStore()
        let removeFirst = registry(store: removeStore)
        removeFirst.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        removeFirst.flushPersistence()
        removeFirst.removeAll()
        removeFirst.flushPersistence()
        XCTAssertGreaterThan(removeStore.clears, 0)
        XCTAssertTrue(registry(store: removeStore).liveSessions().isEmpty)

        let endStore = MemoryClaudeSessionStore()
        let endFirst = registry(store: endStore)
        endFirst.ingest(localRecord(.sessionStart), origin: .localAuthenticated(peerUID: 501))
        endFirst.flushPersistence()
        endFirst.ingest(localRecord(.sessionEnd), origin: .localAuthenticated(peerUID: 501))
        endFirst.flushPersistence()
        XCTAssertTrue(registry(store: endStore).liveSessions().isEmpty)
    }
}
