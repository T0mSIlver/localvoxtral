import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Test clock — the registry never reads the wall clock itself, so TTL and
/// staleness move by hand (AGENTS: no wall-clock in tests).
private final class JoinTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private final class JoinTestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

private final class JoinTestMarkers: Sendable {
    private let queue: Mutex<[String]>
    init(_ values: [String]) { queue = Mutex(values) }
    var allocate: @Sendable () -> String {
        { [self] in queue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() } }
    }
}

private struct JoinTestHerdrPanes: HerdrPaneQuerying {
    var focused: HerdrFocusedPane?
    var foreground: HerdrPaneForegroundInfo?
    var visibleText: String?
    var onFocused: @Sendable () -> Void = {}

    func focusedPane(socketPath _: String) async -> HerdrFocusedPane? {
        onFocused()
        return focused
    }

    func paneForegroundInfo(
        socketPath _: String,
        paneID _: String
    ) async -> HerdrPaneForegroundInfo? {
        foreground
    }

    func paneVisibleText(socketPath _: String, paneID _: String) async -> String? {
        visibleText
    }
}

/// The gate that decides which Claude session a dictation is about, and
/// whether a captured Ghostty pane's raw text may be rendered into a prompt.
///
/// The asymmetry these tests defend: a wrong join renders an unrelated
/// terminal's scrollback — and now its repository — into someone's prompt,
/// while a wrong abstention costs only an excerpt whose terms the vocabulary
/// matcher already extracted. So every case that is not "exactly one live
/// session, positively identified" must abstain.
@MainActor
final class TerminalScreenClaudeJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    /// Two windows of the SAME Ghostty process: identical target, different
    /// window identity. What review F2 is about.
    private let windowA: CGWindowID = 101
    private let windowB: CGWindowID = 202

    private func record(
        session: String = "s1",
        claudePID: Int32? = 9001,
        tty: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: claudePID.map {
                ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: $0,
                    tty: tty,
                    herdrPaneID: herdrPaneID,
                    herdrSocketPath: herdrSocketPath
                )
            }
        )
    }

    /// Every seam injected, always. A registry built with the DEFAULT liveness
    /// probe would run a real `kill(pid, 0)` against whatever process happens to
    /// hold that pid on the host — the live-state flake class this repo pins
    /// seams to avoid.
    private func makeRegistry(
        limits: ClaudeRegistryLimits = .default,
        clock: JoinTestClock? = nil,
        liveness: JoinTestLiveness? = nil,
        markers: [String] = ["lvx-abcd"]
    ) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            limits: limits,
            now: (clock ?? JoinTestClock(epoch)).now,
            isProcessAlive: (liveness ?? JoinTestLiveness()).probe,
            allocateMarkerValue: JoinTestMarkers(markers).allocate
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        title: String?,
        focusedTTY: String? = nil,
        titleWindowID: CGWindowID? = 101,
        ttyWindowID: CGWindowID? = 101,
        herdrClient: Bool = false,
        herdrPanes: HerdrPaneQuerying? = nil
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                title.flatMap { ClaudeMarkerTitleParser.marker(inTitle: $0) }.map {
                    TerminalScreenAXReader.FocusedWindowMarkerRead(
                        marker: $0, windowID: titleWindowID
                    )
                }
            },
            focusedTerminalTTY: { _ in focusedTTY },
            focusedWindowID: { _ in ttyWindowID },
            herdrClientProbe: { _ in herdrClient },
            herdrPanes: herdrPanes
        )
    }

    /// The authorizer over a join resolved from `title`. Mirrors production:
    /// resolve once, then consult that join.
    private func authorizer(
        registry: ClaudeSessionRegistry,
        title: String?,
        target: TerminalScreenTarget? = nil,
        titleWindowID: CGWindowID? = 101
    ) async -> TerminalScreenClaudeJoinAuthorizer {
        let resolver = resolver(registry: registry, title: title, titleWindowID: titleWindowID)
        let join = await resolver.resolve(target: target ?? ghostty)
        return TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { join })
    }

    // MARK: - Known marker

    // The one case that joins: the broker issued this marker to a session it
    // authenticated from peer credentials, Claude wrote it into the title, and
    // the session is still live.
    func testKnownLiveMarkerInTitleResolvesAndAuthorizes() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(
            registry: registry, title: "lvx-abcd — ~/repo"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.marker, ClaudeSessionMarker(value: "lvx-abcd"))
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.target, ghostty)
        XCTAssertEqual(join.mechanism, .titleMarker)
        let gate = await authorizer(registry: registry, title: "lvx-abcd — ~/repo")
        XCTAssertTrue(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // The join carries the session's LOCAL workspace, which is what the repo
    // collector needs and the only thing that can reach the filesystem.
    func testLocalSessionJoinExposesTheWorkspacePath() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(
            registry: registry, title: "lvx-abcd"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.localWorkspacePath?.path, "/repo")
    }

    // A REMOTE session joins (its marker is real and its context is usable as
    // opaque text) but exposes no path — so the collector cannot be called for
    // it, and that is enforced by the type, not by a check.
    func testRemoteSessionJoinExposesNoWorkspacePath() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(record(), origin: .remote(channel: "ssh"))
        )
        let resolved = await resolver(
            registry: registry, title: "lvx-abcd"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertNil(
            join.localWorkspacePath,
            "a remote session must never hand a filesystem path to the collector"
        )
    }

    // MARK: - TTY join

    // The title-war case this mechanism exists for: Claude Code's own
    // conversation title has clobbered the marker, so the title read answers
    // nothing — but the focused pane's device still names the session.
    func testTTYJoinsWhenTheTitleCarriesNoMarker() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(record(tty: "/dev/ttys003"), origin: local)
        )
        let joinResolver = resolver(
            registry: registry, title: "Fixing the flaky supervisor test", focusedTTY: "/dev/ttys003"
        )
        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.marker, ClaudeSessionMarker(value: "lvx-abcd"))
        XCTAssertEqual(join.mechanism, .ttyDevice)
        // The tty-joined session revalidates at stop through the same
        // marker-keyed liveness path as a title join.
        XCTAssertTrue(joinResolver.isStillLive(join))
    }

    func testTTYJoinDoesNotReadTheTitleAtAll() async throws {
        // Precedence is observable: when the device answers, the title is not
        // even consulted — a stale marker in it cannot compete.
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys003"), origin: local))
        var titleReads = 0
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                titleReads += 1
                return nil
            },
            focusedTerminalTTY: { _ in "/dev/ttys003" },
            focusedWindowID: { _ in self.windowA }
        )
        let join = await joinResolver.resolve(target: ghostty)
        XCTAssertNotNil(join)
        XCTAssertEqual(titleReads, 0)
    }

    func testTTYJoinWinsOverAStaleMarkerNamingAnotherSession() async throws {
        // Pane recycling: claude #1 ended, its marker lingers in the title;
        // claude #2 runs in the same pane on the same device. The process
        // table is current, the title is history — the device must win.
        let registry = makeRegistry(markers: ["lvx-aaaa", "lvx-bbbb"])
        XCTAssertNotNil(
            registry.ingest(record(session: "old", tty: "/dev/ttys009"), origin: local)
        )
        XCTAssertNotNil(
            registry.ingest(
                record(session: "new", claudePID: 9002, tty: "/dev/ttys003"), origin: local
            )
        )
        let resolved = await resolver(
            registry: registry, title: "lvx-aaaa", focusedTTY: "/dev/ttys003"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "new")
    }

    func testUnmatchedTTYFallsBackToTheTitleMarker() async throws {
        // Old Ghostty answers no tty; a device with no session answers
        // `.unknown`. Either way the marker path must still join — the tty
        // mechanism only ever adds joins, never removes one.
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys003"), origin: local))
        let resolved = await resolver(
            registry: registry, title: "lvx-abcd", focusedTTY: "/dev/ttys777"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.mechanism, .titleMarker)
    }

    func testAmbiguousTTYFallsBackToTheTitleMarker() async throws {
        // Two local sessions on one device abstain at the registry; the
        // marker — which names exactly one of them — may still disambiguate.
        let registry = makeRegistry(markers: ["lvx-aaaa", "lvx-bbbb"])
        XCTAssertNotNil(
            registry.ingest(record(session: "s1", tty: "/dev/ttys003"), origin: local)
        )
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: 9002, tty: "/dev/ttys003"), origin: local
            )
        )
        let resolved = await resolver(
            registry: registry, title: "lvx-bbbb", focusedTTY: "/dev/ttys003"
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "s2")
    }

    // The tty join carries the focused window's identity exactly like the
    // marker join carries the title read's — and the authorizer holds both to
    // the same compare. Without it, a tty join would either always refuse raw
    // attachment (nil identity) or bypass the F2 window check entirely.
    func testTTYJoinCarriesTheFocusedWindowIdentity() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys003"), origin: local))
        let joinResolver = resolver(
            registry: registry, title: nil, focusedTTY: "/dev/ttys003", ttyWindowID: windowB
        )
        let join = await joinResolver.resolve(target: ghostty)
        XCTAssertEqual(join?.windowID, windowB)
        XCTAssertEqual(join?.mechanism, .ttyDevice)
        let gate = TerminalScreenClaudeJoinAuthorizer(resolver: joinResolver, currentJoin: { join })
        XCTAssertTrue(
            gate.isAuthorized(target: ghostty, windowID: windowB),
            "precondition: the tty-joined window itself authorizes"
        )
        XCTAssertFalse(
            gate.isAuthorized(target: ghostty, windowID: windowA),
            "a capture from another window of the same app must not inherit a tty join"
        )
    }

    // A tty join whose window identity could not be established still joins —
    // hook state and repo context remain usable — but raw screen attachment
    // refuses, same as an unknown marker-read identity.
    func testTTYJoinWithUnknownWindowIdentityRefusesRawAttachment() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys003"), origin: local))
        let joinResolver = resolver(
            registry: registry, title: nil, focusedTTY: "/dev/ttys003", ttyWindowID: nil
        )
        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertNil(join.windowID)
        let gate = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { join }
        )
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: nil))
    }

    func testRemoteSessionNeverJoinsViaTTY() async {
        // End-to-end shape of the registry's remote refusal: an SSH session
        // publishing the local pane's device must not claim the pane. With no
        // marker in the title either, there is no join at all.
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(tty: "/dev/ttys003"), origin: .remote(channel: "ssh")
            )
        )
        let join = await resolver(
            registry: registry, title: nil, focusedTTY: "/dev/ttys003"
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    // MARK: - herdr join

    private func herdrRecord(
        session: String = "s1",
        claudePID: Int32 = 9001,
        paneID: String = "pane-a",
        socketPath: String = "/tmp/herdr-a.sock"
    ) -> ClaudeHookRecord {
        record(
            session: session,
            claudePID: claudePID,
            tty: "/dev/ttys-inner",
            herdrPaneID: paneID,
            herdrSocketPath: socketPath
        )
    }

    private func herdrPanes(
        paneID: String = "pane-a",
        claim: String? = nil,
        foregroundPIDs: [Int32]? = [9001]
    ) -> JoinTestHerdrPanes {
        JoinTestHerdrPanes(
            focused: HerdrFocusedPane(
                paneID: paneID, claimedClaudeSessionID: claim
            ),
            foreground: HerdrPaneForegroundInfo(
                shellPID: 8000, foregroundPIDs: foregroundPIDs
            )
        )
    }

    func testTTYResolutionWinsBeforeHerdrProbe() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(
                    tty: "/dev/ttys003",
                    herdrPaneID: "pane-a",
                    herdrSocketPath: "/tmp/herdr.sock"
                ),
                origin: local
            )
        )
        let probeCalls = Mutex(0)
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in "/dev/ttys003" },
            focusedWindowID: { _ in self.windowA },
            herdrClientProbe: { _ in
                probeCalls.withLock { $0 += 1 }
                return true
            },
            herdrPanes: herdrPanes()
        )

        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .ttyDevice)
        XCTAssertEqual(probeCalls.withLock { $0 }, 0)
    }

    func testHerdrPaneJoinsWhenPaneAndForegroundPIDMatch() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let joinResolver = resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(claim: "s1")
        )

        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.mechanism, .herdrPane)
        XCTAssertEqual(join.windowID, windowA)
        XCTAssertTrue(joinResolver.isStillLive(join))
    }

    func testHerdrPaneWithNilSessionClaimStillJoins() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(claim: nil)
        ).resolve(target: ghostty)

        XCTAssertEqual(try XCTUnwrap(join).mechanism, .herdrPane)
    }

    func testHerdrSurfaceNeverFallsBackToTitleMarker() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let titleReads = Mutex(0)
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                titleReads.withLock { $0 += 1 }
                return TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: self.windowA
                )
            },
            focusedTerminalTTY: { _ in "/dev/ttys-outer" },
            herdrClientProbe: { _ in true },
            herdrPanes: JoinTestHerdrPanes(focused: nil, foreground: nil)
        )

        let join = await joinResolver.resolve(target: ghostty)
        XCTAssertNil(join)
        XCTAssertEqual(titleReads.withLock { $0 }, 0)
    }

    func testHerdrJoinAbstainsWithNoRegisteredSocket() async {
        let registry = makeRegistry()
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes()
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWithMultipleRegisteredSockets() async {
        let registry = makeRegistry(markers: ["lvx-aaaa", "lvx-bbbb"])
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                herdrRecord(
                    session: "s2",
                    claudePID: 9002,
                    paneID: "pane-b",
                    socketPath: "/tmp/herdr-b.sock"
                ),
                origin: local
            )
        )
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes()
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenLivePaneQueryIsNotInjected() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testDefaultHerdrProbeAbstains() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in "/dev/ttys-outer" }
        )
        let join = await joinResolver.resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenFocusedPaneIsUnavailable() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: JoinTestHerdrPanes(focused: nil, foreground: nil)
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenFocusedPaneIsUnmatched() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(paneID: "pane-unregistered")
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenFocusedPaneIsAmbiguous() async {
        let registry = makeRegistry(markers: ["lvx-aaaa", "lvx-bbbb"])
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                herdrRecord(session: "s2", claudePID: 9002), origin: local
            )
        )
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes()
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenFocusedPaneTurnsStaleDuringQuery() async {
        let clock = JoinTestClock(epoch)
        let registry = makeRegistry(
            limits: ClaudeRegistryLimits(sessionTTL: 60), clock: clock
        )
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let panes = JoinTestHerdrPanes(
            focused: HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: nil),
            foreground: HerdrPaneForegroundInfo(shellPID: nil, foregroundPIDs: [9001]),
            onFocused: { clock.advance(61) }
        )
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: panes
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenSessionClaimDisagrees() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(claim: "another-session")
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenForegroundQueryIsUnavailable() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let panes = JoinTestHerdrPanes(
            focused: HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: nil),
            foreground: nil
        )
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: panes
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenForegroundDetectionIsUnavailable() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(foregroundPIDs: nil)
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrJoinAbstainsWhenClaudePIDIsNotForeground() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let join = await resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes(foregroundPIDs: [7777])
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testHerdrForegroundCrossCheckRefusesSnapshotWithoutProcessInfo() {
        let snapshot = ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: local,
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: epoch
        )
        XCTAssertNil(snapshot.process, "precondition")
        XCTAssertFalse(
            ClaudeSessionJoinResolver.registeredAgentIsForeground(
                snapshot: snapshot, foregroundPIDs: [9001]
            )
        )
    }

    func testNoTTYAnswerUsesMarkerWithoutCallingHerdrProbe() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let probeCalls = Mutex(0)
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: self.windowA
                )
            },
            focusedTerminalTTY: { _ in nil },
            herdrClientProbe: { _ in
                probeCalls.withLock { $0 += 1 }
                return true
            },
            herdrPanes: herdrPanes()
        )

        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .titleMarker)
        XCTAssertEqual(probeCalls.withLock { $0 }, 0)
    }

    func testHerdrJoinNeverAuthorizesCompositeRawScreen() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(herdrRecord(), origin: local))
        let joinResolver = resolver(
            registry: registry,
            title: nil,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: herdrPanes()
        )
        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        let gate = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { join }
        )

        XCTAssertEqual(join.mechanism, .herdrPane)
        XCTAssertEqual(join.windowID, windowA)
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // MARK: - TTY reply validation

    func testFocusedTTYAppleScriptExecutesOffTheMainThread() async {
        let reader = AppleScriptTerminalTTYReader { _ in
            XCTAssertFalse(
                Thread.isMainThread,
                "the blocking AppleScript execute must not run on the main thread"
            )
            return .success("/dev/ttys123")
        }

        let tty = await reader.focusedTerminalTTY(
            bundleID: TerminalScreenAllowlist.ghosttyBundleID
        )

        XCTAssertEqual(tty, "/dev/ttys123")
    }

    func testValidatedTTYAcceptsOnlyPlausibleDevicePaths() {
        XCTAssertEqual(
            AppleScriptTerminalTTYReader.validatedTTY("/dev/ttys000"), "/dev/ttys000"
        )
        XCTAssertNil(AppleScriptTerminalTTYReader.validatedTTY(nil))
        XCTAssertNil(AppleScriptTerminalTTYReader.validatedTTY(""))
        XCTAssertNil(
            AppleScriptTerminalTTYReader.validatedTTY("ttys000"),
            "a bare name is not a device path"
        )
        XCTAssertNil(
            AppleScriptTerminalTTYReader.validatedTTY("/dev/ttys0 00"),
            "whitespace means this is a title, not a device"
        )
        XCTAssertNil(
            AppleScriptTerminalTTYReader.validatedTTY(
                "/dev/tty" + String(repeating: "s", count: 64)
            ),
            "a reply longer than any real pty path is not a device"
        )
        XCTAssertNil(AppleScriptTerminalTTYReader.validatedTTY("/dev/ttys00é"))
    }

    // MARK: - Abstentions

    // Plain Ghostty: a terminal the user opened themselves, no Claude session,
    // nothing in the title. This is the common case and the one that keeps
    // arbitrary scrollback out of prompts.
    func testPlainGhosttyWithNoMarkerInTitleDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        // A live session EXISTS — it is just not this window. The join must
        // still fail: "a Claude session is running somewhere" is not a join, and
        // a sole-session heuristic is exactly what this asserts we do not have.
        let join = await resolver(
            registry: registry, title: "~/repo — zsh"
        ).resolve(target: ghostty)
        XCTAssertNil(join)
        let gate = await authorizer(registry: registry, title: "~/repo — zsh")
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    func testAbsentTitleDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = await resolver(registry: registry, title: nil).resolve(target: ghostty)
        XCTAssertNil(join)
        let gate = await authorizer(registry: registry, title: nil)
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // A marker we never issued — or one left in a title after the session ended
    // and was evicted. Both arrive here as `.unknown`.
    func testUnknownMarkerDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = await resolver(
            registry: registry, title: "lvx-9999"
        ).resolve(target: ghostty)
        XCTAssertNil(join)
        let gate = await authorizer(registry: registry, title: "lvx-9999")
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // Past TTL: the title still shows the marker, but the registry no longer
    // vouches for the session. A stale title is exactly how a pane that WAS a
    // Claude session goes on looking like one.
    func testStaleMarkerPastTTLDoesNotJoin() async {
        let clock = JoinTestClock(epoch)
        let registry = makeRegistry(limits: ClaudeRegistryLimits(sessionTTL: 60), clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let gate = resolver(registry: registry, title: "lvx-abcd")
        let liveJoin = await gate.resolve(target: ghostty)
        XCTAssertNotNil(liveJoin, "precondition: live before the TTL")
        clock.advance(61)
        let staleJoin = await gate.resolve(target: ghostty)
        XCTAssertNil(staleJoin)
    }

    // The Claude process died without firing SessionEnd (SIGKILL, closed
    // terminal). TTL alone would still call this live; the liveness probe is
    // what makes it stale.
    func testStaleMarkerWhoseProcessIsGoneDoesNotJoin() async {
        let liveness = JoinTestLiveness()
        let registry = makeRegistry(liveness: liveness)
        XCTAssertNotNil(registry.ingest(record(claudePID: 9001), origin: local))
        let gate = resolver(registry: registry, title: "lvx-abcd")
        let liveJoin = await gate.resolve(target: ghostty)
        XCTAssertNotNil(liveJoin, "precondition: live while the pid is alive")
        liveness.kill(9001)
        let staleJoin = await gate.resolve(target: ghostty)
        XCTAssertNil(staleJoin)
    }

    // Two markers in one title: we cannot tell which session owns the window.
    // The parser abstains and so must the join.
    func testAmbiguousTitleCarryingTwoMarkersDoesNotJoin() async {
        let registry = makeRegistry(markers: ["lvx-abcd", "lvx-beef"])
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(registry.ingest(record(session: "s2"), origin: local))
        XCTAssertNil(
            ClaudeMarkerTitleParser.marker(inTitle: "lvx-abcd lvx-beef"),
            "precondition: the parser abstains on two markers"
        )
        let join = await resolver(
            registry: registry, title: "lvx-abcd lvx-beef"
        ).resolve(target: ghostty)
        XCTAssertNil(join)
    }

    // MARK: - App identity

    // The marker join does not override the allowlist. A non-Ghostty app whose
    // title happens to carry a valid marker (an editor showing the terminal's
    // title, a window named after a log line) must not become readable.
    func testNonGhosttyAppDoesNotJoinEvenWithALiveMarkerInTitle() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        for bundleID in TerminalScreenAllowlist.explicitlyExcludedBundleIDs {
            let editor = TerminalScreenTarget(pid: 4242, bundleID: bundleID)
            let join = await resolver(
                registry: registry, title: "lvx-abcd"
            ).resolve(target: editor)
            XCTAssertNil(join, "\(bundleID) must never join a Claude session")
        }
    }

    // MARK: - Resolve once, share everywhere

    // The whole point of storing the join: ONE title read per dictation, whose
    // answer every consumer shares. Three independent resolutions could each
    // answer honestly about a different moment — the user can switch tabs
    // mid-sentence — and the prompt would then describe one session's screen
    // next to another's repository.
    func testTheWindowTitleIsReadExactlyOncePerDictation() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let reads = Mutex(0)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                reads.withLock { $0 += 1 }
                return TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        let join = await resolver.resolve(target: ghostty)
        XCTAssertNotNil(join)
        XCTAssertEqual(reads.withLock { $0 }, 1)

        // The authorizer consults the resolved join; it must not read again.
        let gate = TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { join })
        XCTAssertTrue(gate.isAuthorized(target: ghostty, windowID: windowA))
        XCTAssertTrue(gate.isAuthorized(target: ghostty, windowID: windowA))
        XCTAssertEqual(
            reads.withLock { $0 }, 1,
            "the authorizer must consult the resolved join, never re-read the title"
        )
    }

    // A join describes ONE pane. A different target — including a recycled pid
    // now owned by another app — inherits nothing from it.
    func testJoinDoesNotAuthorizeADifferentTarget() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let other = TerminalScreenTarget(pid: 777, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let gate = await authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty, windowID: windowA), "precondition: the joined pane authorizes")
        XCTAssertFalse(gate.isAuthorized(target: other, windowID: windowA))
    }

    // Same pid, different app: the bundle id is part of the identity compare,
    // so a quit-and-relaunch that recycled the pid cannot inherit the join.
    func testJoinDoesNotAuthorizeARecycledPIDOwnedByAnotherApp() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let recycled = TerminalScreenTarget(pid: ghostty.pid, bundleID: "com.apple.Terminal")
        let gate = await authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertFalse(gate.isAuthorized(target: recycled, windowID: windowA))
    }

    // The session can end between start and stop. The marker is fixed by the
    // start read — what is re-checked is whether it still names a live session.
    func testSessionEndingAfterTheJoinWithdrawsAuthorization() async {
        let liveness = JoinTestLiveness()
        let registry = makeRegistry(liveness: liveness)
        XCTAssertNotNil(registry.ingest(record(claudePID: 9001), origin: local))
        let gate = await authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty, windowID: windowA), "precondition: live at join time")
        liveness.kill(9001)
        XCTAssertFalse(
            gate.isAuthorized(target: ghostty, windowID: windowA),
            "a session that died mid-dictation must not attach its pane"
        )
    }

    // No join at all (the common case: a plain terminal) means nothing to
    // authorize, and no live read to make.
    func testNoJoinAuthorizesNothing() {
        let registry = makeRegistry()
        let resolver = resolver(registry: registry, title: nil)
        let gate = TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { nil })
        XCTAssertFalse(gate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // MARK: - Window identity (review F2)

    // Two windows of ONE Ghostty process share pid and bundle ID, so the
    // target compare cannot tell them apart. The screen capture and the join's
    // title read are two separate AX reads: focus moving between them pairs
    // window A's SCREEN with window B's SESSION. The window identity is what
    // must refuse that.
    func testJoinDoesNotAuthorizeADifferentWindowOfTheSameApp() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let gate = await authorizer(registry: registry, title: "lvx-abcd", titleWindowID: windowB)
        XCTAssertTrue(
            gate.isAuthorized(target: ghostty, windowID: windowB),
            "precondition: the joined window itself authorizes"
        )
        XCTAssertFalse(
            gate.isAuthorized(target: ghostty, windowID: windowA),
            "a capture from another window of the same app must not inherit the join"
        )
    }

    // Unknown identity never authorizes: two unknowns are not "the same
    // window", they are two questions nobody answered.
    func testMissingWindowIdentityRefusesRawAttachment() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let nilIdentityGate = await authorizer(
            registry: registry, title: "lvx-abcd", titleWindowID: nil
        )
        XCTAssertFalse(
            nilIdentityGate.isAuthorized(target: ghostty, windowID: nil),
            "nil join identity + nil capture identity must abstain, never match"
        )
        let knownIdentityGate = await authorizer(
            registry: registry, title: "lvx-abcd", titleWindowID: windowA
        )
        XCTAssertFalse(knownIdentityGate.isAuthorized(target: ghostty, windowID: nil))
        XCTAssertFalse(nilIdentityGate.isAuthorized(target: ghostty, windowID: windowA))
    }

    // MARK: - Wiring into the reconciler

    // The end-to-end shape: an authorized pane whose screen is unchanged is the
    // ONLY path to `.render`.
    func testAuthorizedUnchangedScreenRendersThroughTheLiveSource() {
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = {
            $0 == self.ghostty && $1 == self.windowA
        }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        TerminalScreenAXReader.debugScreenWindowIDOverride = { _ in self.windowA }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty, windowID: windowA),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .render(excerpt: "swift build", startText: "swift build", elidedChurnLines: 0))
    }

    // "Unchanged" means unchanged AFTER the deterministic whitespace
    // compaction, not byte-identical raw AX payloads: a redraw that only
    // changed row padding or blank-row runs still renders, because both reads
    // pass through the same sanitize seam before comparison. This pins the
    // `.render` contract's wording.
    func testWhitespaceOnlyRedrawStillRendersThroughTheLiveSource() {
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = {
            $0 == self.ghostty && $1 == self.windowA
        }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        // The stop-time raw grid re-padded the rows and grew a trailing blank
        // run; the compacted form is identical to the start capture.
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build   \u{00A0}\n\n\n\n" }
        TerminalScreenAXReader.debugScreenWindowIDOverride = { _ in self.windowA }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty, windowID: windowA),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .render(excerpt: "swift build", startText: "swift build", elidedChurnLines: 0))
    }

    // The stop-time confirmation read must describe the pane captured at
    // start. A different window of the same app can show byte-identical text
    // (two idle panes), and the text compare alone would then "confirm" a
    // screen nobody re-read — the window identity is what catches it
    // (review F2).
    func testStopReadFromADifferentWindowOfTheSameAppNeverRenders() {
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { _, _ in true }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        TerminalScreenAXReader.debugScreenWindowIDOverride = { _ in self.windowB }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty, windowID: windowA),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(
            decision, .vocabularyOnly(startText: "swift build", cause: .stopReadFailed),
            "identical text from another window must degrade to matching-only, never render"
            + " — the mismatch is a failed confirmation of the START window"
            + " (its own info log line marks this sub-case)"
        )
    }

    // Authorization is asked about the START capture's pane — the one the user
    // was looking at while speaking — never the frontmost app, which by commit
    // time may be our own overlay.
    func testAuthorizationIsAskedAboutTheStartCapturesTarget() {
        let other = TerminalScreenTarget(pid: 777, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let asked = Mutex<[TerminalScreenTarget]>([])
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { target, _ in
            asked.withLock { $0.append(target) }
            return false
        }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        _ = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(asked.withLock { $0 }, [ghostty])
        XCTAssertFalse(asked.withLock { $0 }.contains(other))
    }

    // No start capture means no pane to join, so the gate is never consulted —
    // and `reconcile` drops on `noStartCapture` regardless.
    func testNoStartCaptureNeverConsultsTheGate() {
        let consulted = Mutex(false)
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { _, _ in
            consulted.withLock { $0 = true }
            return true
        }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: nil,
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .drop(reason: .noStartCapture))
        XCTAssertFalse(consulted.withLock { $0 }, "no pane means nothing to authorize")
    }

    override func tearDown() async throws {
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = nil
        TerminalScreenRawAttachmentPolicy.configure(authorizer: nil)
        TerminalScreenContextSource.debugTargetForPIDOverride = nil
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        TerminalScreenAXReader.debugScreenReadOverride = nil
        TerminalScreenAXReader.debugWindowTitleOverride = nil
        TerminalScreenAXReader.debugScreenWindowIDOverride = nil
        TerminalScreenAXReader.debugTitleWindowIDOverride = nil
        try await super.tearDown()
    }
}
