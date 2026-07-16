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

/// The gate that decides whether a captured Ghostty pane's raw text may be
/// rendered into a prompt.
///
/// The asymmetry these tests defend: a wrong `true` renders an unrelated
/// terminal's scrollback into someone's prompt, while a wrong `false` costs only
/// an excerpt whose terms the vocabulary matcher already extracted. So every
/// case that is not "exactly one live session, positively identified" must
/// answer false.
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

    private func authorizer(
        registry: ClaudeSessionRegistry,
        title: String?
    ) -> TerminalScreenClaudeJoinAuthorizer {
        TerminalScreenClaudeJoinAuthorizer(
            registry: registry,
            markerInWindowTitle: { _ in
                title.flatMap { ClaudeMarkerTitleParser.marker(inTitle: $0) }
            }
        )
    }

    // MARK: - Known marker

    // The one case that authorizes: the broker issued this marker to a session
    // it authenticated from peer credentials, Claude wrote it into the title,
    // and the session is still live.
    func testKnownLiveMarkerInTitleAuthorizes() throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertTrue(
            authorizer(registry: registry, title: "lvx-abcd — ~/repo").isAuthorized(target: ghostty)
        )
    }

    // MARK: - Abstentions

    // Plain Ghostty: a terminal the user opened themselves, no Claude session,
    // nothing in the title. This is the common case and the one that keeps
    // arbitrary scrollback out of prompts.
    func testPlainGhosttyWithNoMarkerInTitleIsUnauthorized() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        // A live session EXISTS — it is just not this window. Authorization must
        // still fail: "a Claude session is running somewhere" is not a join.
        XCTAssertFalse(
            authorizer(registry: registry, title: "~/repo — zsh").isAuthorized(target: ghostty)
        )
    }

    func testAbsentTitleIsUnauthorized() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertFalse(authorizer(registry: registry, title: nil).isAuthorized(target: ghostty))
    }

    // A marker we never issued — or one left in a title after the session ended
    // and was evicted. Both arrive here as `.unknown`.
    func testUnknownMarkerIsUnauthorized() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertFalse(
            authorizer(registry: registry, title: "lvx-9999").isAuthorized(target: ghostty)
        )
    }

    // Past TTL: the title still shows the marker, but the registry no longer
    // vouches for the session. A stale title is exactly how a pane that WAS a
    // Claude session goes on looking like one.
    func testStaleMarkerPastTTLIsUnauthorized() {
        let clock = JoinTestClock(epoch)
        let registry = makeRegistry(limits: ClaudeRegistryLimits(sessionTTL: 60), clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let gate = authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty), "precondition: live before the TTL")
        clock.advance(61)
        XCTAssertFalse(gate.isAuthorized(target: ghostty))
    }

    // The Claude process died without firing SessionEnd (SIGKILL, closed
    // terminal). TTL alone would still call this live; the liveness probe is
    // what makes it stale.
    func testStaleMarkerWhoseProcessIsGoneIsUnauthorized() {
        let liveness = JoinTestLiveness()
        let registry = makeRegistry(liveness: liveness)
        XCTAssertNotNil(registry.ingest(record(claudePID: 9001), origin: local))
        let gate = authorizer(registry: registry, title: "lvx-abcd")
        XCTAssertTrue(gate.isAuthorized(target: ghostty), "precondition: live while the pid is alive")
        liveness.kill(9001)
        XCTAssertFalse(gate.isAuthorized(target: ghostty))
    }

    // Two markers in one title: we cannot tell which session owns the window.
    // The parser abstains and so must the gate.
    func testAmbiguousTitleCarryingTwoMarkersIsUnauthorized() {
        let registry = makeRegistry(markers: ["lvx-abcd", "lvx-beef"])
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(registry.ingest(record(session: "s2"), origin: local))
        XCTAssertNil(
            ClaudeMarkerTitleParser.marker(inTitle: "lvx-abcd lvx-beef"),
            "precondition: the parser abstains on two markers"
        )
        XCTAssertFalse(
            authorizer(registry: registry, title: "lvx-abcd lvx-beef").isAuthorized(target: ghostty)
        )
    }

    // MARK: - App identity

    // The marker join does not override the allowlist. A non-Ghostty app whose
    // title happens to carry a valid marker (an editor showing the terminal's
    // title, a window named after a log line) must not become readable.
    func testNonGhosttyAppIsUnauthorizedEvenWithALiveMarkerInTitle() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        for bundleID in TerminalScreenAllowlist.explicitlyExcludedBundleIDs {
            let editor = TerminalScreenTarget(pid: 4242, bundleID: bundleID)
            XCTAssertFalse(
                authorizer(registry: registry, title: "lvx-abcd").isAuthorized(target: editor),
                "\(bundleID) must never have its screen rendered into a prompt"
            )
        }
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

    // MARK: - The gate comes before the join read

    // Regression: asking the policy is not passive — the broker-backed
    // authorizer makes a live AX round trip for the window title. It must sit
    // BEHIND the stop-time gate like every other read.
    //
    // These drive the REAL authorizer (not `debugAuthorizationOverride`), which
    // is the only way the title read is reachable, and count title reads.
    private func titleCountingAuthorizer() -> () -> Int {
        var count = 0
        let registry = makeRegistry()
        // A live session carrying `lvx-abcd`, so the ONLY thing that can make
        // these tests answer "unauthorized" is the title never being read.
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        TerminalScreenRawAttachmentPolicy.configure(
            authorizer: TerminalScreenClaudeJoinAuthorizer(
                registry: registry,
                markerInWindowTitle: { _ in
                    count += 1
                    return ClaudeSessionMarker(value: "lvx-abcd")
                }
            )
        )
        return { count }
    }

    // Consent withdrawn mid-session (setting off, endpoint repointed off
    // loopback, trust revoked): nothing about the pane may be touched, not even
    // its title.
    func testWithdrawnConsentNeverReadsTheWindowTitle() {
        let titleReads = titleCountingAuthorizer()
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty),
            settingEnabled: false,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .drop(reason: .policyRejected))
        XCTAssertEqual(titleReads(), 0, "a rejected gate must not reach AX for the title either")
    }

    // A recycled PID now belongs to a DIFFERENT app. The authorizer
    // allowlist-checks the START capture's bundle ID (still Ghostty), so asking
    // it here would read the new owner's window title.
    func testRecycledPIDNeverReadsTheNewOwnersWindowTitle() {
        let titleReads = titleCountingAuthorizer()
        TerminalScreenContextSource.debugTargetForPIDOverride = { pid in
            TerminalScreenTarget(pid: pid, bundleID: "com.apple.Terminal")
        }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .drop(reason: .targetChanged))
        XCTAssertEqual(titleReads(), 0, "a target we cannot vouch for must never have its title read")
    }

    // The positive control: with the gate holding and the target intact, the
    // title IS read and the join authorizes. Without this, the two tests above
    // would pass just as well if the authorizer were never called at all.
    func testGateHoldingAndTargetIntactDoesReadTheTitleAndAuthorize() {
        let titleReads = titleCountingAuthorizer()
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.ghostty }
        TerminalScreenAXReader.debugScreenReadOverride = { _ in "swift build" }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "swift build", target: ghostty),
            settingEnabled: true,
            endpointURL: URL(string: "http://127.0.0.1:8472/v1/chat/completions")!,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .render(excerpt: "swift build"))
        XCTAssertEqual(titleReads(), 1)
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
