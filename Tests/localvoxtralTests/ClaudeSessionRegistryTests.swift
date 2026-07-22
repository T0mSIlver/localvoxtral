import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

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

/// Deterministic marker allocator; can be forced to collide.
private final class TestMarkers: Sendable {
    private let queue: Mutex<[String]>

    init(_ values: [String]) { queue = Mutex(values) }

    var allocate: @Sendable () -> String {
        { [self] in
            queue.withLock { values in
                values.isEmpty ? "lvx-exhausted" : values.removeFirst()
            }
        }
    }
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
        liveness: TestLiveness? = nil,
        markers: TestMarkers? = nil
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            limits: limits,
            now: (clock ?? TestClock(epoch)).now,
            isProcessAlive: (liveness ?? TestLiveness()).probe,
            allocateMarkerValue: (markers ?? TestMarkers(["lvx-0001"])).allocate
        )
    }

    // MARK: Ingest and origin

    func testIngestCreatesSessionWithBrokerAllocatedMarker() throws {
        let registry = makeRegistry(markers: TestMarkers(["lvx-abcd"]))
        let snapshot = try XCTUnwrap(registry.ingest(record(.sessionStart), origin: local))
        XCTAssertEqual(snapshot.sessionID, "s1")
        XCTAssertEqual(snapshot.marker, ClaudeSessionMarker(value: "lvx-abcd"))
        XCTAssertEqual(snapshot.origin, local)
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

    func testSessionEndFreesTheMarkerForReuse() {
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-1"]))
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionEnd, session: "s1"), origin: local)
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")), .unknown)

        // The same marker value is now free, so a new session may take it.
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        guard case .resolved(let snapshot) = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")) else {
            return XCTFail("expected resolution")
        }
        XCTAssertEqual(snapshot.sessionID, "s2")
    }

    // MARK: Marker uniqueness

    func testCollidingAllocatorNeverAliasesTwoLiveSessions() throws {
        // Force the allocator to hand out the same value twice. Aliasing would
        // silently feed one session's context into the other's dictation.
        let registry = makeRegistry(markers: TestMarkers(["lvx-same", "lvx-same", "lvx-other"]))
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)

        let first = try XCTUnwrap(registry.snapshot(sessionID: "s1"))
        let second = try XCTUnwrap(registry.snapshot(sessionID: "s2"))
        XCTAssertNotEqual(first.marker, second.marker)
        XCTAssertEqual(first.marker.value, "lvx-same")
        XCTAssertEqual(second.marker.value, "lvx-other")
    }

    func testExhaustedAllocatorStillYieldsUniqueMarkers() throws {
        // Allocator that always returns one value: the fallback path must still
        // produce distinct markers rather than alias.
        let registry = makeRegistry(markers: TestMarkers([]))
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        let first = try XCTUnwrap(registry.snapshot(sessionID: "s1"))
        let second = try XCTUnwrap(registry.snapshot(sessionID: "s2"))
        XCTAssertNotEqual(first.marker, second.marker)
    }

    // Unique is necessary but not sufficient: the fallback marker also has to be
    // one the publisher can WRITE. `lvx-fallback-<n>` was unique and unemittable
    // — `k` is not in `ClaudeMarkerSequence`'s hex allowlist — so a session that
    // reached the fallback was minted, indexed, and then permanently unjoinable,
    // silently, because the marker join is positive-only.
    func testFallbackMarkersAreEmittableAsTerminalSequences() throws {
        let registry = makeRegistry(markers: TestMarkers([]))
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        let fallback = try XCTUnwrap(registry.snapshot(sessionID: "s2"))
        XCTAssertTrue(
            ClaudeMarkerSequence.isValidMarker(fallback.marker.value),
            "\(fallback.marker.value) is minted but would never be emitted"
        )
    }

    func testDefaultMarkerValuesAreWellFormed() {
        let value = ClaudeSessionRegistry.defaultMarkerValue()
        XCTAssertTrue(value.hasPrefix("lvx-"))
        XCTAssertEqual(value.count, 12, "lvx- plus 8 hex chars")
    }

    func testDefaultMarkersAreEmittableAsTerminalSequences() {
        // The registry mints markers and the publisher puts them in a terminal
        // title. If the grammars ever drift apart, the focus join silently
        // stops emitting — no error, just no markers. Pin them together.
        for _ in 0..<32 {
            let value = ClaudeSessionRegistry.defaultMarkerValue()
            XCTAssertTrue(
                ClaudeMarkerSequence.isValidMarker(value),
                "\(value) is minted but would never be emitted"
            )
        }
    }

    // MARK: Marker lookup — abstention

    func testUnknownMarkerAbstains() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "nope")), .unknown)
    }

    func testStaleMarkerAbstainsAfterTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 100),
            clock: clock,
            markers: TestMarkers(["lvx-1"])
        )
        registry.ingest(record(.sessionStart), origin: local)
        let marker = ClaudeSessionMarker(value: "lvx-1")

        clock.advance(99)
        guard case .resolved = registry.resolve(marker: marker) else {
            return XCTFail("still inside TTL")
        }

        clock.advance(2) // now 101 > TTL
        XCTAssertEqual(registry.resolve(marker: marker), .stale)
    }

    func testActivityRefreshesTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 100),
            clock: clock,
            markers: TestMarkers(["lvx-1"])
        )
        registry.ingest(record(.sessionStart), origin: local)
        clock.advance(90)
        registry.ingest(record(.stop), origin: local)
        clock.advance(90) // 180 since start, but only 90 since last activity
        guard case .resolved = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")) else {
            return XCTFail("activity should have refreshed the TTL")
        }
    }

    func testDeadClaudeProcessMakesMarkerStaleBeforeTTLExpires() {
        // Claude Code can die without firing SessionEnd (SIGKILL, closed
        // terminal), so TTL alone would keep a ghost session resolvable.
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness, markers: TestMarkers(["lvx-1"]))
        registry.ingest(record(.sessionStart, claudePID: 4242), origin: local)
        let marker = ClaudeSessionMarker(value: "lvx-1")
        guard case .resolved = registry.resolve(marker: marker) else {
            return XCTFail("alive session should resolve")
        }

        liveness.kill(4242)
        XCTAssertEqual(registry.resolve(marker: marker), .stale)
    }

    func testPIDLessLocalSessionUsesTheShortExposureTTL() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 4 * 60 * 60),
            clock: clock,
            markers: TestMarkers(["lvx-1"])
        )
        registry.ingest(record(.sessionStart), origin: local)

        clock.advance(5 * 60 + 1)

        XCTAssertEqual(
            registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")),
            .stale,
            "without a Claude pid to probe, a dead local session must not remain joinable for four hours"
        )
    }

    /// Regression, production-shaped: the publisher is a one-shot process, so
    /// by the time the app looks at a record the `hookPID` is ALWAYS dead. If
    /// liveness probes it, every local session is `.stale` the instant it is
    /// created and the whole feature silently returns nothing.
    ///
    /// This reproduces the real arrangement — dead hook pid, live Claude pid —
    /// rather than asserting on the field name.
    func testLivenessProbesClaudePIDNotTheShortLivedHookPID() {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness, markers: TestMarkers(["lvx-1"]))

        // Exactly what production looks like a millisecond after the hook ran.
        liveness.kill(31_337) // the publisher: exited the moment it wrote its line
        registry.ingest(
            record(.sessionStart, claudePID: 4242, hookPID: 31_337), origin: local
        )

        guard case .resolved(let snapshot) = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")) else {
            return XCTFail("a live Claude session must resolve even though the hook process is gone")
        }
        XCTAssertEqual(snapshot.process?.claudePID, 4242)
        XCTAssertEqual(snapshot.process?.hookPID, 31_337)

        // And the session does go stale when CLAUDE dies — proving liveness is
        // wired to the right pid rather than simply disabled.
        liveness.kill(4242)
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")), .stale)
    }

    func testRemoteSessionPidIsNotProbedForLiveness() {
        // A remote pid names a process on another machine; probing it locally
        // would be meaningless (and could match an unrelated local process).
        let liveness = TestLiveness()
        liveness.kill(4242)
        let registry = makeRegistry(liveness: liveness, markers: TestMarkers(["lvx-1"]))
        registry.ingest(record(.sessionStart, claudePID: 4242), origin: .remote(channel: "ssh"))
        guard case .resolved = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")) else {
            return XCTFail("remote sessions rely on TTL, not local pid liveness")
        }
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
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2"]))
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

    // MARK: herdr pane lookup — the marker-free focus join

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
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2"]))
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
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2", "lvx-3"]))
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
        let registry = makeRegistry(liveness: liveness, markers: TestMarkers(["lvx-1", "lvx-2"]))
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
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2"]))
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
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2"]))
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
            clock: clock,
            markers: TestMarkers(["lvx-1", "lvx-2", "lvx-3"])
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

    func testEvictedSessionReleasesItsMarker() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 1, sessionTTL: 10_000),
            clock: clock,
            markers: TestMarkers(["lvx-1", "lvx-2"])
        )
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        clock.advance(1)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        XCTAssertEqual(
            registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")), .unknown,
            "the evicted session's marker must not linger in the index"
        )
    }

    func testOneOriginsBurstCannotEvictAnotherOriginsLiveSession() {
        let clock = TestClock(epoch)
        let quietOrigin = ClaudeTransportOrigin.remote(channel: "ssh:quiet")
        let burstingOrigin = ClaudeTransportOrigin.remote(channel: "ssh:burst")
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 4, sessionTTL: 10_000),
            clock: clock,
            markers: TestMarkers(["lvx-q", "lvx-b1", "lvx-b2", "lvx-b3", "lvx-b4"])
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
            clock: clock,
            markers: TestMarkers(["lvx-q", "lvx-z1", "lvx-z2", "lvx-z3", "lvx-a"])
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

    func testStaleSessionsArePrunedOnIngest() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxSessions: 32, sessionTTL: 10),
            clock: clock,
            markers: TestMarkers(["lvx-1", "lvx-2"])
        )
        registry.ingest(record(.sessionStart, session: "old"), origin: local)
        clock.advance(50)
        registry.ingest(record(.sessionStart, session: "new"), origin: local)
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["new"])
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-1")), .unknown)
    }

    func testLiveSessionsAreOrderedMostRecentlyActiveFirst() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock, markers: TestMarkers(["lvx-1", "lvx-2"]))
        registry.ingest(record(.sessionStart, session: "first"), origin: local)
        clock.advance(5)
        registry.ingest(record(.sessionStart, session: "second"), origin: local)
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["second", "first"])
    }

    func testExplicitEvictAndRemoveAll() {
        let registry = makeRegistry(markers: TestMarkers(["lvx-1", "lvx-2"]))
        registry.ingest(record(.sessionStart, session: "s1"), origin: local)
        registry.ingest(record(.sessionStart, session: "s2"), origin: local)
        registry.evict(sessionID: "s1")
        XCTAssertEqual(registry.liveSessions().map(\.sessionID), ["s2"])
        registry.removeAll()
        XCTAssertTrue(registry.liveSessions().isEmpty)
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-2")), .unknown)
    }

    // MARK: Remote host eviction

    /// Sessions for four origins: two SSH hosts, another remote transport, and
    /// a local peer-authenticated process.
    private func makeMixedOriginRegistry() -> ClaudeSessionRegistry {
        let registry = makeRegistry(
            markers: TestMarkers(["lvx-gone", "lvx-kept", "lvx-relay", "lvx-local"])
        )
        registry.ingest(record(.sessionStart, session: "remote:hgone:s1"), origin: .remote(channel: "ssh:hgone"))
        registry.ingest(record(.sessionStart, session: "remote:hkeep:s1"), origin: .remote(channel: "ssh:hkeep"))
        registry.ingest(record(.sessionStart, session: "relay:s1"), origin: .remote(channel: "relay"))
        registry.ingest(record(.sessionStart, session: "local-1"), origin: local)
        return registry
    }

    func testEvictingARemoteHostTakesItsSessionsAndItsMarkers() {
        let registry = makeMixedOriginRegistry()

        let evicted = registry.evictRemoteSessions(notIn: ["ssh:hkeep"])

        XCTAssertEqual(evicted, 1)
        XCTAssertNil(registry.snapshot(sessionID: "remote:hgone:s1"))
        // The marker matters as much as the session: it is the ONLY way context
        // is joined, so a marker left pointing at an evicted session — or worse,
        // dangling for a later session to collide with — is the bug, not
        // bookkeeping.
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-gone")), .unknown)
    }

    func testEvictingOneRemoteHostLeavesSiblingsAndLocalSessionsAlone() throws {
        let registry = makeMixedOriginRegistry()

        registry.evictRemoteSessions(notIn: ["ssh:hkeep"])

        let sibling = try XCTUnwrap(
            registry.snapshot(sessionID: "remote:hkeep:s1"),
            "a sibling host's session is not collateral"
        )
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-kept")), .resolved(sibling))
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
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-local")), .resolved(survivor))
        XCTAssertNotEqual(
            registry.resolve(marker: ClaudeSessionMarker(value: "lvx-relay")),
            .unknown,
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
}
