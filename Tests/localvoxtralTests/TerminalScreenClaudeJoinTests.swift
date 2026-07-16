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

    private func record(
        session: String = "s1",
        claudePID: Int32? = 9001
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: claudePID.map { ClaudeHookProcessInfo(hookPID: 777, claudePID: $0) }
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
        title: String?
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                title.flatMap { ClaudeMarkerTitleParser.marker(inTitle: $0) }
            }
        )
    }

    /// The authorizer over a join resolved from `title`. Mirrors production:
    /// resolve once, then consult that join.
    private func authorizer(
        registry: ClaudeSessionRegistry,
        title: String?,
        target: TerminalScreenTarget? = nil
    ) -> TerminalScreenClaudeJoinAuthorizer {
        let resolver = resolver(registry: registry, title: title)
        let join = resolver.resolve(target: target ?? ghostty)
        return TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { join })
    }

    // MARK: - Known marker

    // The one case that joins: the broker issued this marker to a session it
    // authenticated from peer credentials, Claude wrote it into the title, and
    // the session is still live.
    func testKnownLiveMarkerInTitleResolvesAndAuthorizes() throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = try XCTUnwrap(
            resolver(registry: registry, title: "lvx-abcd — ~/repo").resolve(target: ghostty)
        )
        XCTAssertEqual(join.marker, ClaudeSessionMarker(value: "lvx-abcd"))
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.target, ghostty)
        XCTAssertTrue(
            authorizer(registry: registry, title: "lvx-abcd — ~/repo").isAuthorized(target: ghostty)
        )
    }

    // The join carries the session's LOCAL workspace, which is what the repo
    // collector needs and the only thing that can reach the filesystem.
    func testLocalSessionJoinExposesTheWorkspacePath() throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = try XCTUnwrap(
            resolver(registry: registry, title: "lvx-abcd").resolve(target: ghostty)
        )
        XCTAssertEqual(join.localWorkspacePath?.path, "/repo")
    }

    // A REMOTE session joins (its marker is real and its context is usable as
    // opaque text) but exposes no path — so the collector cannot be called for
    // it, and that is enforced by the type, not by a check.
    func testRemoteSessionJoinExposesNoWorkspacePath() throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(record(), origin: .remote(channel: "ssh"))
        )
        let join = try XCTUnwrap(
            resolver(registry: registry, title: "lvx-abcd").resolve(target: ghostty)
        )
        XCTAssertNil(
            join.localWorkspacePath,
            "a remote session must never hand a filesystem path to the collector"
        )
    }

    // MARK: - Abstentions

    // Plain Ghostty: a terminal the user opened themselves, no Claude session,
    // nothing in the title. This is the common case and the one that keeps
    // arbitrary scrollback out of prompts.
    func testPlainGhosttyWithNoMarkerInTitleDoesNotJoin() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        // A live session EXISTS — it is just not this window. The join must
        // still fail: "a Claude session is running somewhere" is not a join, and
        // a sole-session heuristic is exactly what this asserts we do not have.
        XCTAssertNil(resolver(registry: registry, title: "~/repo — zsh").resolve(target: ghostty))
        XCTAssertFalse(
            authorizer(registry: registry, title: "~/repo — zsh").isAuthorized(target: ghostty)
        )
    }

    func testAbsentTitleDoesNotJoin() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertNil(resolver(registry: registry, title: nil).resolve(target: ghostty))
        XCTAssertFalse(authorizer(registry: registry, title: nil).isAuthorized(target: ghostty))
    }

    // A marker we never issued — or one left in a title after the session ended
    // and was evicted. Both arrive here as `.unknown`.
    func testUnknownMarkerDoesNotJoin() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertNil(resolver(registry: registry, title: "lvx-9999").resolve(target: ghostty))
        XCTAssertFalse(
            authorizer(registry: registry, title: "lvx-9999").isAuthorized(target: ghostty)
        )
    }

    // Past TTL: the title still shows the marker, but the registry no longer
    // vouches for the session. A stale title is exactly how a pane that WAS a
    // Claude session goes on looking like one.
    func testStaleMarkerPastTTLDoesNotJoin() {
        let clock = JoinTestClock(epoch)
        let registry = makeRegistry(limits: ClaudeRegistryLimits(sessionTTL: 60), clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let gate = resolver(registry: registry, title: "lvx-abcd")
        XCTAssertNotNil(gate.resolve(target: ghostty), "precondition: live before the TTL")
        clock.advance(61)
        XCTAssertNil(gate.resolve(target: ghostty))
    }

    // The Claude process died without firing SessionEnd (SIGKILL, closed
    // terminal). TTL alone would still call this live; the liveness probe is
    // what makes it stale.
    func testStaleMarkerWhoseProcessIsGoneDoesNotJoin() {
        let liveness = JoinTestLiveness()
        let registry = makeRegistry(liveness: liveness)
        XCTAssertNotNil(registry.ingest(record(claudePID: 9001), origin: local))
        let gate = resolver(registry: registry, title: "lvx-abcd")
        XCTAssertNotNil(gate.resolve(target: ghostty), "precondition: live while the pid is alive")
        liveness.kill(9001)
        XCTAssertNil(gate.resolve(target: ghostty))
    }

    // Two markers in one title: we cannot tell which session owns the window.
    // The parser abstains and so must the join.
    func testAmbiguousTitleCarryingTwoMarkersDoesNotJoin() {
        let registry = makeRegistry(markers: ["lvx-abcd", "lvx-beef"])
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(registry.ingest(record(session: "s2"), origin: local))
        XCTAssertNil(
            ClaudeMarkerTitleParser.marker(inTitle: "lvx-abcd lvx-beef"),
            "precondition: the parser abstains on two markers"
        )
        XCTAssertNil(
            resolver(registry: registry, title: "lvx-abcd lvx-beef").resolve(target: ghostty)
        )
    }

    // MARK: - App identity

    // The marker join does not override the allowlist. A non-Ghostty app whose
    // title happens to carry a valid marker (an editor showing the terminal's
    // title, a window named after a log line) must not become readable.
    func testNonGhosttyAppDoesNotJoinEvenWithALiveMarkerInTitle() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        for bundleID in TerminalScreenAllowlist.explicitlyExcludedBundleIDs {
            let editor = TerminalScreenTarget(pid: 4242, bundleID: bundleID)
            XCTAssertNil(
                resolver(registry: registry, title: "lvx-abcd").resolve(target: editor),
                "\(bundleID) must never join a Claude session"
            )
        }
    }

    // MARK: - Resolve once, share everywhere

    // The whole point of storing the join: ONE title read per dictation, whose
    // answer every consumer shares. Three independent resolutions could each
    // answer honestly about a different moment — the user can switch tabs
    // mid-sentence — and the prompt would then describe one session's screen
    // next to another's repository.
    func testTheWindowTitleIsReadExactlyOncePerDictation() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let reads = Mutex(0)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                reads.withLock { $0 += 1 }
                return ClaudeSessionMarker(value: "lvx-abcd")
            }
        )
        let join = resolver.resolve(target: ghostty)
        XCTAssertNotNil(join)
        XCTAssertEqual(reads.withLock { $0 }, 1)

        // The authorizer consults the resolved join; it must not read again.
        let gate = TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { join })
        XCTAssertTrue(gate.isAuthorized(target: ghostty))
        XCTAssertTrue(gate.isAuthorized(target: ghostty))
        XCTAssertEqual(
            reads.withLock { $0 }, 1,
            "the authorizer must consult the resolved join, never re-read the title"
        )
    }

    // A join describes ONE pane. A different target — including a recycled pid
    // now owned by another app — inherits nothing from it.
    func testJoinDoesNotAuthorizeADifferentTarget() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let other = TerminalScreenTarget(pid: 777, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let gate = authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty), "precondition: the joined pane authorizes")
        XCTAssertFalse(gate.isAuthorized(target: other))
    }

    // Same pid, different app: the bundle id is part of the identity compare,
    // so a quit-and-relaunch that recycled the pid cannot inherit the join.
    func testJoinDoesNotAuthorizeARecycledPIDOwnedByAnotherApp() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let recycled = TerminalScreenTarget(pid: ghostty.pid, bundleID: "com.apple.Terminal")
        XCTAssertFalse(
            authorizer(registry: registry, title: "lvx-abcd").isAuthorized(target: recycled)
        )
    }

    // The session can end between start and stop. The marker is fixed by the
    // start read — what is re-checked is whether it still names a live session.
    func testSessionEndingAfterTheJoinWithdrawsAuthorization() {
        let liveness = JoinTestLiveness()
        let registry = makeRegistry(liveness: liveness)
        XCTAssertNotNil(registry.ingest(record(claudePID: 9001), origin: local))
        let gate = authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty), "precondition: live at join time")
        liveness.kill(9001)
        XCTAssertFalse(
            gate.isAuthorized(target: ghostty),
            "a session that died mid-dictation must not attach its pane"
        )
    }

    // No join at all (the common case: a plain terminal) means nothing to
    // authorize, and no live read to make.
    func testNoJoinAuthorizesNothing() {
        let registry = makeRegistry()
        let resolver = resolver(registry: registry, title: nil)
        let gate = TerminalScreenClaudeJoinAuthorizer(resolver: resolver, currentJoin: { nil })
        XCTAssertFalse(gate.isAuthorized(target: ghostty))
    }

    // MARK: - Wiring into the reconciler

    // The end-to-end shape: an authorized pane whose screen is unchanged is the
    // ONLY path to `.render`.
    func testAuthorizedUnchangedScreenRendersThroughTheLiveSource() {
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { $0 == self.ghostty }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .render(excerpt: "swift build"))
    }

    // Authorization is asked about the START capture's pane — the one the user
    // was looking at while speaking — never the frontmost app, which by commit
    // time may be our own overlay.
    func testAuthorizationIsAskedAboutTheStartCapturesTarget() {
        let other = TerminalScreenTarget(pid: 777, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let asked = Mutex<[TerminalScreenTarget]>([])
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { target in
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
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { _ in
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
        try await super.tearDown()
    }
}
