import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

// Focused coverage for the wire-v2 additions to the registry: per-agent
// session-id namespacing and the pane focus declarations that make the TTY
// join answer for opencode, where one process (one TTY) hosts several
// sessions and the TUI shows exactly one.
//
// Helpers mirror `ClaudeSessionRegistryTests` (they are file-private there).
// Same capture rules apply: closures capture `[self]`, never the `Mutex`.

private final class TestClock: Sendable {
    private let value: Mutex<Date>

    init(_ start: Date) { value = Mutex(start) }

    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }

    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private final class TestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])

    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }

    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

final class ClaudeSessionFocusResolutionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let tty = "/dev/ttys004"
    /// The opencode process pid — shared by every session it hosts AND by its
    /// focus declarations, because the plugin runs inside that one process.
    private let opencodePID: Int32 = 4242

    /// Endless distinct markers — these tests create many sessions and never
    /// care which marker each one got.
    private final class SequentialMarkers: Sendable {
        private let counter = Mutex(0)

        var allocate: @Sendable () -> String {
            { [self] in
                counter.withLock { value in
                    value += 1
                    return "lvx-" + String(format: "%08x", value)
                }
            }
        }
    }

    private func makeRegistry(
        limits: ClaudeRegistryLimits = .default,
        clock: TestClock? = nil,
        liveness: TestLiveness? = nil
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            limits: limits,
            now: (clock ?? TestClock(epoch)).now,
            isProcessAlive: (liveness ?? TestLiveness()).probe,
            allocateMarkerValue: SequentialMarkers().allocate
        )
    }

    /// An opencode session record as the plugin's server half publishes it:
    /// agent-tagged, pid = the opencode process, and NO tty — the server half
    /// cannot prove it owns a pane, so it never claims one.
    private func opencodeRecord(
        _ event: ClaudeHookEvent,
        session: String,
        cwd: String? = "/repo",
        prompt: String? = nil,
        files: [ClaudeFileTouch] = []
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            agent: .opencode,
            sessionID: session,
            timestamp: 0,
            rawCwd: cwd,
            prompt: prompt,
            files: files,
            process: ClaudeHookProcessInfo(hookPID: opencodePID, claudePID: opencodePID)
        )
    }

    /// A focus declaration as the plugin's TUI half publishes it: the pane's
    /// own TTY plus the session it currently displays.
    private func focusRecord(
        session: String,
        agent: ClaudeHookAgent = .opencode,
        pid: Int32? = nil,
        tty: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .focusChanged,
            agent: agent,
            sessionID: session,
            timestamp: 0,
            process: ClaudeHookProcessInfo(
                hookPID: pid ?? opencodePID,
                claudePID: pid ?? opencodePID,
                tty: tty ?? self.tty
            )
        )
    }

    /// A Claude Code record claiming a TTY per-session, the pre-v2 shape.
    private func claudeRecord(
        _ event: ClaudeHookEvent,
        session: String,
        claudePID: Int32,
        tty: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/repo",
            process: ClaudeHookProcessInfo(hookPID: 999, claudePID: claudePID, tty: tty)
        )
    }

    private func resolvedSessionID(_ resolution: ClaudeMarkerResolution) -> String? {
        if case .resolved(let snapshot) = resolution { return snapshot.sessionID }
        return nil
    }

    // MARK: - Per-agent session-id namespacing

    func testOpencodeSessionIDsAreScopedOnIngestAndClaudeIDsStayBare() throws {
        let registry = makeRegistry()
        let opencode = try XCTUnwrap(
            registry.ingest(opencodeRecord(.sessionStart, session: "ses_1"), origin: local)
        )
        XCTAssertEqual(opencode.sessionID, "opencode:ses_1")
        XCTAssertEqual(opencode.agent, .opencode)

        let claude = try XCTUnwrap(
            registry.ingest(claudeRecord(.sessionStart, session: "ses_1", claudePID: 7), origin: local)
        )
        XCTAssertEqual(claude.sessionID, "ses_1", "Claude ids stay bare — v1 behavior is unchanged")
        XCTAssertEqual(claude.agent, .claude)

        // Same raw id, two agents, two sessions: the namespace IS the
        // collision prevention.
        XCTAssertNotNil(registry.snapshot(sessionID: "opencode:ses_1"))
        XCTAssertNotNil(registry.snapshot(sessionID: "ses_1"))
    }

    func testARecordSpellingAnotherAgentsScopedIDIsDropped() throws {
        // Scoping makes honest collision impossible, so a Claude record whose
        // session id literally reads "opencode:ses_1" is spelling a key that
        // is not its own. It must not mutate the opencode session.
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_1", cwd: "/real"), origin: local)

        let forged = registry.ingest(
            claudeRecord(.cwdChanged, session: "opencode:ses_1", claudePID: 7), origin: local
        )
        XCTAssertNil(forged, "cross-agent key spelling is dropped whole")
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "opencode:ses_1"))
        XCTAssertEqual(snapshot.localWorkspacePath?.path, "/real")
    }

    func testFocusRecordNeverMintsASession() {
        let registry = makeRegistry()
        let result = registry.ingest(focusRecord(session: "ses_ghost"), origin: local)
        XCTAssertNil(result, "a pane can display a session whose records were lost; inventing an empty snapshot for it would let the join resolve to nothing")
        XCTAssertNil(registry.snapshot(sessionID: "opencode:ses_ghost"))
        XCTAssertTrue(registry.liveSessions().isEmpty)
    }

    // MARK: - Focus truth table for resolve(tty:)

    func testSingleSessionWithFreshFocusResolves() {
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(focusRecord(session: "ses_a"), origin: local)

        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: tty)), "opencode:ses_a")
    }

    func testSingleOpencodeSessionWithoutFocusAbstains() {
        // Positive evidence or nothing: the server half never claims a TTY, so
        // an opencode session with no focus declaration is unjoinable — there
        // is deliberately no sole-session fallback.
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)

        XCTAssertEqual(registry.resolve(tty: tty), .unknown)
    }

    func testMultipleSessionsWithFreshFocusResolveToTheDeclaredOne() {
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_b"), origin: local)
        registry.ingest(focusRecord(session: "ses_b"), origin: local)

        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: tty)), "opencode:ses_b")

        // A session switch re-declares; the newest declaration wins.
        registry.ingest(focusRecord(session: "ses_a"), origin: local)
        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: tty)), "opencode:ses_a")
    }

    func testStaleFocusIsAbsentInformationSoMultipleSessionsAbstain() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_b"), origin: local)
        registry.ingest(focusRecord(session: "ses_b"), origin: local)

        clock.advance(ClaudeRegistryLimits.defaultFocusDeclarationTTL - 1)
        XCTAssertEqual(
            resolvedSessionID(registry.resolve(tty: tty)), "opencode:ses_b",
            "inside the bound the declaration still answers"
        )

        clock.advance(2)
        XCTAssertEqual(
            registry.resolve(tty: tty), .unknown,
            "past the bound the declaration is not a hint — nothing claims this TTY anymore"
        )
    }

    func testMultipleSessionsWithNoFocusEverAbstain() {
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_b"), origin: local)

        XCTAssertEqual(registry.resolve(tty: tty), .unknown)
    }

    func testFreshFocusForADeadSessionAbstainsOutright() {
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_b"), origin: local)
        registry.ingest(focusRecord(session: "ses_b"), origin: local)
        // The displayed session ends (session.deleted); the pane has not
        // re-declared yet.
        registry.ingest(opencodeRecord(.sessionEnd, session: "ses_b"), origin: local)

        XCTAssertEqual(
            registry.resolve(tty: tty), .stale,
            "the pane said it displays ses_b; ses_b is gone; resolving to the surviving sibling would contradict the freshest evidence"
        )
    }

    func testFocusForASessionWhoseProcessDiedAbstains() {
        let liveness = TestLiveness()
        let registry = makeRegistry(liveness: liveness)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(focusRecord(session: "ses_a"), origin: local)
        liveness.kill(opencodePID)

        XCTAssertEqual(registry.resolve(tty: tty), .stale)
    }

    func testFocusDeclaredByADifferentProcessThanTheSessionAbstains() {
        // A declaration that outlived its process must not steer a recycled
        // TTY: the declarer's pid and the focused session's registered pid
        // must be the same process.
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(focusRecord(session: "ses_a", pid: 5555), origin: local)

        XCTAssertEqual(registry.resolve(tty: tty), .stale)
    }

    func testFocusDisambiguatesCompetingPerSessionTTYClaims() {
        // The generic form of "multiple + focus fresh": two live sessions each
        // claim the same device per-session (the suspended-agent-under-a-new-
        // one shape), and a fresh declaration picks the displayed one.
        let registry = makeRegistry()
        registry.ingest(claudeRecord(.sessionStart, session: "old", claudePID: 71, tty: tty), origin: local)
        registry.ingest(claudeRecord(.sessionStart, session: "new", claudePID: 72, tty: tty), origin: local)
        XCTAssertEqual(registry.resolve(tty: tty), .ambiguous, "without focus this abstains today")

        registry.ingest(focusRecord(session: "new", agent: .claude, pid: 72), origin: local)
        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: tty)), "new")
    }

    func testConflictBetweenATTYClaimAndAFocusDeclarationAbstains() {
        // A live Claude session claims the device per-session while a fresh
        // opencode declaration names a different live session: two agents each
        // positively claiming one pane. Nobody wins.
        let registry = makeRegistry()
        registry.ingest(claudeRecord(.sessionStart, session: "cl", claudePID: 71, tty: tty), origin: local)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(focusRecord(session: "ses_a"), origin: local)

        XCTAssertEqual(registry.resolve(tty: tty), .ambiguous)
    }

    func testSingleClaudeTTYClaimStillResolvesWithoutAnyFocus() {
        // The pre-v2 join, byte-for-byte: no focus table entry, one live local
        // claim, resolved. Claude behavior must be unchanged by all of this.
        let registry = makeRegistry()
        registry.ingest(claudeRecord(.sessionStart, session: "cl", claudePID: 71, tty: tty), origin: local)

        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: tty)), "cl")
    }

    func testRemoteFocusDeclarationsAreIgnored() {
        // A remote host declaring focus for a local TTY device is exactly the
        // "SSH host claims a local pane" attack the TTY join refuses; the
        // focus table must refuse it at the door too.
        let registry = makeRegistry()
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        registry.ingest(
            focusRecord(session: "ses_a"), origin: .remote(channel: "ssh:host")
        )

        XCTAssertEqual(registry.resolve(tty: tty), .unknown)
    }

    func testFocusRecordForALiveSessionBumpsItsActivity() throws {
        let clock = TestClock(epoch)
        let registry = makeRegistry(clock: clock)
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        clock.advance(100)
        let bumped = try XCTUnwrap(registry.ingest(focusRecord(session: "ses_a"), origin: local))
        XCTAssertEqual(bumped.lastActivity, epoch.addingTimeInterval(100))
        XCTAssertEqual(bumped.activity, .idle, "displaying a session says nothing about its turn state")
    }

    func testFocusTableIsBounded() {
        let clock = TestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(maxFocusDeclarations: 2), clock: clock
        )
        registry.ingest(opencodeRecord(.sessionStart, session: "ses_a"), origin: local)
        for index in 0..<5 {
            clock.advance(1)
            registry.ingest(
                focusRecord(session: "ses_a", tty: "/dev/ttys00\(index)"), origin: local
            )
        }
        // The newest declaration must have survived the cap.
        XCTAssertEqual(resolvedSessionID(registry.resolve(tty: "/dev/ttys004")), "opencode:ses_a")
        // The oldest ones are gone: their TTYs resolve as if never declared.
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys000"), .unknown)
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys001"), .unknown)
    }

    // MARK: - Opencode event shapes through the reducer

    func testOpencodeLifecycleReducesLikeAnyLocalSession() throws {
        // The verified plugin payload mapping: chat.message → UserPromptSubmit,
        // tool.execute.after → PostToolUse, session.idle → Stop,
        // session.deleted → SessionEnd. Everything downstream (blocks, repo
        // collection, budget) reads the same snapshot fields as Claude's.
        let registry = makeRegistry()
        let prompt = try XCTUnwrap(registry.ingest(
            opencodeRecord(
                .userPromptSubmit, session: "ses_a", cwd: "/repo", prompt: "add a --json flag"
            ),
            origin: local
        ))
        XCTAssertEqual(prompt.latestPriorUserPrompt, "add a --json flag")
        XCTAssertEqual(prompt.activity, .working)
        XCTAssertEqual(prompt.localWorkspacePath?.path, "/repo")

        let touched = try XCTUnwrap(registry.ingest(
            opencodeRecord(
                .postToolUse, session: "ses_a",
                files: [ClaudeFileTouch(path: "/repo/src/cli.ts", kind: .edited)]
            ),
            origin: local
        ))
        XCTAssertEqual(touched.recentFiles.map(\.path), ["/repo/src/cli.ts"])

        let idle = try XCTUnwrap(
            registry.ingest(opencodeRecord(.stop, session: "ses_a"), origin: local)
        )
        XCTAssertEqual(idle.activity, .idle)

        let ended = try XCTUnwrap(
            registry.ingest(opencodeRecord(.sessionEnd, session: "ses_a"), origin: local)
        )
        XCTAssertEqual(ended.activity, .ended)
        XCTAssertNil(registry.snapshot(sessionID: "opencode:ses_a"), "SessionEnd evicts")
    }
}
