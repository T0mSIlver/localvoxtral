import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Test clock — the registry never reads the wall clock itself.
private final class DesktopJoinTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// Counts live-seam calls, so "never asked" assertions are about the read, not
/// its result.
private final class DesktopJoinReadCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// The Claude Desktop join: the `local_…` id in the address of the web view
/// holding keyboard focus, against the `CLAUDE_CODE_HOST_SESSION_ID` a live
/// session's own hooks published.
///
/// The browser-tab arm's shape with a different reader, so these tests mirror
/// `BrowserTabClaudeJoinTests`: it joins local and remote sessions, abstains on
/// every non-answer, never authorizes a screen read, and its commit-time
/// liveness re-resolves the id rather than trusting the start-time answer.
@MainActor
final class DesktopSessionClaudeJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:host-a")
    private let desktop = TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
    private let chrome = TerminalScreenTarget(pid: 5150, bundleID: BrowserTabAllowlist.chromeBundleID)
    private let ghostty = TerminalScreenTarget(pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    private let desktopID = "local_fb53459c-6a7b-43b1-a326-52258b970501"
    private var sessionAddress: String { "https://claude.ai/epitaxy/\(desktopID)" }

    private func record(
        session: String = "s1",
        claudePID: Int32? = 9001,
        desktopSessionID: String? = "local_fb53459c-6a7b-43b1-a326-52258b970501",
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
                ClaudeHookProcessInfo(hookPID: 777, claudePID: $0, desktopSessionID: desktopSessionID)
            }
        )
    }

    private func remoteEnvironment(_ id: String? = nil) -> ClaudeRemoteSessionEnvironment {
        ClaudeRemoteSessionEnvironment(desktopSessionID: id ?? desktopID)
    }

    private func makeRegistry(clock: DesktopJoinTestClock? = nil) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            now: (clock ?? DesktopJoinTestClock(epoch)).now,
            isProcessAlive: { _ in true }
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        address: String?,
        desktopReads: DesktopJoinReadCounter? = nil,
        tabReads: DesktopJoinReadCounter? = nil,
        ttyReads: DesktopJoinReadCounter? = nil
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in
                ttyReads?.increment()
                return nil
            },
            focusedBrowserTabURL: { _ in
                tabReads?.increment()
                return nil
            },
            focusedDesktopSessionURL: { _ in
                desktopReads?.increment()
                return address
            },
            focusedWindowID: { _ in 101 }
        )
    }

    // MARK: - The joins

    // A session Claude Desktop runs on this Mac: the local hook's environment
    // carried the id, and the focused web view shows the same one.
    func testFocusedDesktopSessionJoinsALocalSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(registry: registry, address: sessionAddress)
            .resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .desktopSession)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.desktopSession?.desktopSessionID, desktopID)
        XCTAssertNil(join.browserTab)
        XCTAssertEqual(join.target, desktop)
        XCTAssertEqual(join.localWorkspacePath?.path, "/repo")
    }

    // A session Claude Desktop runs on an ssh host (measured: the remote hook
    // environment carries the same `local_…` id). It joins, and its workspace
    // stays remote.
    func testFocusedDesktopSessionJoinsARemoteSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(record(claudePID: nil), origin: remote, environment: remoteEnvironment())
        )
        let resolved = await resolver(registry: registry, address: sessionAddress)
            .resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .desktopSession)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertNil(join.localWorkspacePath, "a remote session never hands a path to the collector")
    }

    // MARK: - Abstentions

    // Focus in the chat tab, the sidebar, a settings page: no session id.
    func testAddressThatIsNotASessionDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        for address in [
            "https://claude.ai/new",
            "https://claude.ai/chat/0b7c4f1e-aaaa-bbbb-cccc-000000000000",
            "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
        ] {
            // Not a session view, so nothing for the badge to call unjoined.
            let resolution = await resolver(registry: registry, address: address).resolution(target: desktop)
            XCTAssertEqual(resolution, ClaudeJoinResolution(join: nil), address)
        }
    }

    func testReadFailureAbstains() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolution = await resolver(registry: registry, address: nil).resolution(target: desktop)
        XCTAssertEqual(resolution, ClaudeJoinResolution(join: nil))
    }

    // The desktop shows a session whose hooks never reach us (no plugin on that
    // host, or the host is not enrolled): nothing reports the id.
    func testSessionNobodyReportsDoesNotJoin() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(desktopSessionID: "local_other"), origin: local))
        // Focus IS in a session view: the badge says it did not join (#658).
        let resolution = await resolver(registry: registry, address: sessionAddress)
            .resolution(target: desktop)
        XCTAssertEqual(resolution, ClaudeJoinResolution(join: nil, focusedSessionUnmatched: true))
    }

    func testTwoSessionsReportingOneDesktopIDAbstain() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil), origin: remote, environment: remoteEnvironment()
            )
        )
        // Focus IS in a session view: the badge says it did not join (#658).
        let resolution = await resolver(registry: registry, address: sessionAddress)
            .resolution(target: desktop)
        XCTAssertEqual(resolution, ClaudeJoinResolution(join: nil, focusedSessionUnmatched: true))
    }

    func testStaleSessionDoesNotJoin() async {
        let clock = DesktopJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        // Focus IS in a session view: the badge says it did not join (#658).
        let resolution = await resolver(registry: registry, address: sessionAddress)
            .resolution(target: desktop)
        XCTAssertEqual(resolution, ClaudeJoinResolution(join: nil, focusedSessionUnmatched: true))
    }

    // A Remote Control id and a desktop id are different keys: a browser tab
    // naming a session's bridge id does not match its desktop id, and the
    // reverse.
    func testBridgeAndDesktopIDsAreNotInterchangeable() async {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                ClaudeHookRecord(
                    event: .sessionStart,
                    sessionID: "s1",
                    timestamp: 0,
                    rawCwd: "/repo",
                    process: ClaudeHookProcessInfo(
                        hookPID: 1, claudePID: 9001, bridgeSessionID: "session_abc123"
                    )
                ),
                origin: local
            )
        )
        XCTAssertEqual(registry.resolve(desktopSessionID: "session_abc123"), .unknown)
        let join = await resolver(
            registry: registry, address: "https://claude.ai/epitaxy/session_abc123"
        ).resolve(target: desktop)
        XCTAssertNil(join, "a bridge id under the desktop path is not a desktop session address")
    }

    // MARK: - Which reader each target reaches

    func testDesktopTargetAsksOnlyTheDesktopReader() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let desktopReads = DesktopJoinReadCounter()
        let tabReads = DesktopJoinReadCounter()
        let ttyReads = DesktopJoinReadCounter()
        _ = await resolver(
            registry: registry, address: sessionAddress,
            desktopReads: desktopReads, tabReads: tabReads, ttyReads: ttyReads
        ).resolve(target: desktop)
        XCTAssertEqual(desktopReads.count, 1)
        XCTAssertEqual(tabReads.count, 0)
        XCTAssertEqual(ttyReads.count, 0)
    }

    func testTerminalAndBrowserTargetsNeverReadTheDesktop() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let desktopReads = DesktopJoinReadCounter()
        for target in [ghostty, chrome] {
            let join = await resolver(
                registry: registry, address: sessionAddress, desktopReads: desktopReads
            ).resolve(target: target)
            XCTAssertNil(join)
        }
        XCTAssertEqual(desktopReads.count, 0)
    }

    // The resolver's default abstains: a test (or diagnostic) that does not
    // inject the reader can never reach the live Accessibility read.
    func testUninjectedResolverAbstainsForClaudeDesktop() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let join = await ClaudeSessionJoinResolver(registry: registry).resolve(target: desktop)
        XCTAssertNil(join)
    }

    // MARK: - What the join authorizes

    func testDesktopJoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertNil(join.windowID)
        XCTAssertNil(join.socketPaneKey)
        let authorizer = TerminalScreenClaudeJoinAuthorizer(resolver: joinResolver, currentJoin: { join })
        XCTAssertFalse(authorizer.isAuthorized(target: desktop, windowID: 101))
        XCTAssertFalse(authorizer.isAuthorized(target: desktop, windowID: nil))
        XCTAssertFalse(authorizer.isAuthorized(target: ghostty, windowID: 101))
    }

    // The mechanism refuses, not the missing window id: a desktop join that
    // satisfies every other condition is still refused.
    func testTheMechanismItselfRefusesEvenWhenEveryOtherConditionHolds() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let arm = try XCTUnwrap(resolved)
        let joinWithWindow = ClaudeSessionJoin(
            target: arm.target,
            snapshot: arm.snapshot,
            windowID: 101,
            mechanism: .desktopSession,
            desktopSession: arm.desktopSession
        )
        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { joinWithWindow }
        )
        XCTAssertTrue(joinResolver.isStillLive(joinWithWindow), "precondition")
        XCTAssertFalse(authorizer.isAuthorized(target: desktop, windowID: 101))
    }

    func testJoinSummaryNamesTheArm() {
        XCTAssertEqual(ClaudeSessionJoinSummary.armName(.desktopSession), "desktopSession")
    }

    // MARK: - Liveness

    func testJoinStaysLiveWhileTheSessionKeepsReporting() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        XCTAssertTrue(joinResolver.isStillLive(join))
    }

    // A second reporter arriving mid-dictation kills the join (the browser
    // arm's codex finding on PR #218, same rule here).
    func testACollisionAppearingAfterResolutionKillsTheJoin() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertTrue(joinResolver.isStillLive(join))
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil), origin: remote, environment: remoteEnvironment()
            )
        )
        XCTAssertEqual(registry.resolve(desktopSessionID: desktopID), .ambiguous)
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    // The joined session starts reporting a different id (a new record whose
    // process block replaces the old one): the binding no longer holds.
    func testASessionThatStopsReportingTheIDIsNoLongerLive() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertNotNil(registry.ingest(record(desktopSessionID: nil), origin: local))
        XCTAssertNotNil(registry.snapshot(sessionID: "s1"), "the session itself is still live")
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    func testAJoinWithoutItsBindingIsNotLive() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let arm = try XCTUnwrap(resolved)
        let unbound = ClaudeSessionJoin(
            target: arm.target, snapshot: arm.snapshot, windowID: nil, mechanism: .desktopSession
        )
        XCTAssertFalse(joinResolver.isStillLive(unbound))
    }

    func testEndedSessionIsNotLive() async throws {
        let clock = DesktopJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, address: sessionAddress)
        let resolved = await joinResolver.resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    // MARK: - Registry arm

    func testRegistryResolvesLocalAndRemoteDesktopIDs() {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(
            registry.ingest(
                record(session: "s2", claudePID: nil),
                origin: remote,
                environment: remoteEnvironment("local_remote")
            )
        )
        guard case .resolved(let localSnapshot) = registry.resolve(desktopSessionID: desktopID)
        else { return XCTFail("local desktop id must resolve") }
        XCTAssertEqual(localSnapshot.sessionID, "s1")
        guard case .resolved(let remoteSnapshot) = registry.resolve(desktopSessionID: "local_remote")
        else { return XCTFail("remote desktop id must resolve") }
        XCTAssertEqual(remoteSnapshot.sessionID, "s2")
        XCTAssertEqual(registry.resolve(desktopSessionID: "local_nobody"), .unknown)
    }

    // The accessor routes by origin: a local record cannot smuggle a desktop id
    // in through a remote-style environment.
    func testDesktopSessionIDIsReadFromTheOriginsOwnStore() {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(desktopSessionID: nil),
                origin: local,
                environment: remoteEnvironment("local_smuggled")
            )
        )
        XCTAssertEqual(registry.resolve(desktopSessionID: "local_smuggled"), .unknown)
    }

    func testRegistryReportsStaleRatherThanUnknownForAnExpiredSession() {
        let clock = DesktopJoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        clock.advance(ClaudeRegistryLimits.default.sessionTTL + 1)
        XCTAssertEqual(registry.resolve(desktopSessionID: desktopID), .stale)
    }

    // MARK: - Allowlist

    // The resolver's desktop branch runs before the terminal allowlist check,
    // and the three lists grant different capabilities: an overlap would
    // silently reroute an app.
    func testDesktopAllowlistIsDisjointFromTheOthers() {
        let bundleID = ClaudeDesktopAllowlist.bundleID
        XCTAssertFalse(TerminalScreenAllowlist.isSupported(bundleID))
        XCTAssertFalse(TerminalScreenAllowlist.isAXCaptureSupported(bundleID))
        XCTAssertFalse(TerminalScreenAllowlist.isAppleScriptCaptureSupported(bundleID))
        XCTAssertFalse(BrowserTabAllowlist.isSupported(bundleID))
        for other in BrowserTabAllowlist.supportedBundleIDs.union(TerminalScreenAllowlist.supportedBundleIDs) {
            XCTAssertFalse(ClaudeDesktopAllowlist.isSupported(other), other)
        }
    }

    func testAllowlistIsExactMatch() {
        XCTAssertTrue(ClaudeDesktopAllowlist.isSupported("com.anthropic.claudefordesktop"))
        for bundleID in [
            "com.anthropic.claudefordesktop.beta", "com.anthropic.claude",
            "COM.ANTHROPIC.CLAUDEFORDESKTOP", "",
        ] {
            XCTAssertFalse(ClaudeDesktopAllowlist.isSupported(bundleID), bundleID)
        }
        XCTAssertFalse(ClaudeDesktopAllowlist.isSupported(nil))
    }
}

/// The parser that turns a Claude Desktop web view address into a join key.
/// Same asymmetry as `ClaudeBridgeSessionURLTests`: a false positive is a join.
final class ClaudeDesktopSessionURLTests: XCTestCase {
    private let id = "local_fb53459c-6a7b-43b1-a326-52258b970501"

    // The exact address measured on Claude Desktop 2.2553.1.
    func testMeasuredAddressParses() {
        XCTAssertEqual(
            ClaudeDesktopSessionURL.sessionID(inWebAreaURL: "https://claude.ai/epitaxy/\(id)"), id
        )
    }

    func testQueryFragmentAndOneTrailingSlashAreTolerated() {
        for address in [
            "https://claude.ai/epitaxy/\(id)?x=1",
            "https://claude.ai/epitaxy/\(id)#top",
            "https://claude.ai/epitaxy/\(id)/",
            "HTTPS://CLAUDE.AI/epitaxy/\(id)",
        ] {
            XCTAssertEqual(ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address), id, address)
        }
    }

    func testEveryOtherShapeIsRejected() {
        for address in [
            // Wrong scheme, host, userinfo, port.
            "http://claude.ai/epitaxy/\(id)",
            "https://claude.ai.evil.com/epitaxy/\(id)",
            "https://x.claude.ai/epitaxy/\(id)",
            "https://evil.com/claude.ai/epitaxy/\(id)",
            "https://claude.ai@evil.com/epitaxy/\(id)",
            "https://claude.ai:8443/epitaxy/\(id)",
            // Wrong path: the Remote Control path, a subpage, a doubled slash.
            "https://claude.ai/code/\(id)",
            "https://claude.ai/epitaxy/\(id)/files",
            "https://claude.ai/epitaxy/\(id)//",
            "https://claude.ai/epitaxy/",
            "https://claude.ai/epitaxy",
            // Wrong id: another prefix, an empty tail, escapes, non-ASCII.
            "https://claude.ai/epitaxy/session_abc",
            "https://claude.ai/epitaxy/local_",
            "https://claude.ai/epitaxy/local_abc%2Fdef",
            "https://claude.ai/epitaxy/local_ab%00",
            "https://claude.ai/epitaxy/local_аbc",
            "https://claude.ai/epitaxy/local_\(String(repeating: "a", count: 130))",
            // The desktop shell's own address.
            "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
            "",
            "not a url",
        ] {
            XCTAssertNil(ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address), address)
        }
    }

    // The shared checks did not change what the Remote Control parser accepts.
    func testTheBridgeParserStillAcceptsOnlyItsOwnPath() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_abc"),
            "session_abc"
        )
        XCTAssertNil(ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/epitaxy/\(id)"))
    }
}

/// The walk from the focused element to the nearest web view, and the one
/// retry around it. No AX involved: the walk is generic over its element.
@MainActor
final class ClaudeDesktopSessionReaderTests: XCTestCase {
    /// A fake AX element: index into `nodes`.
    private struct Node {
        var role: String?
        var url: String?
        var parent: Int?
        var failsRole = false
        var failsParent = false
    }

    private func walk(_ nodes: [Node], from start: Int = 0, maxHops: Int = 64) -> ClaudeDesktopWebAreaLookup {
        typealias Failure = AXClaudeDesktopSessionURLReader.AXLookupError
        return AXClaudeDesktopSessionURLReader.nearestWebArea(
            from: start,
            role: { nodes[$0].failsRole ? .failure(Failure()) : .success(nodes[$0].role) },
            url: { .success(nodes[$0].url) },
            parent: { nodes[$0].failsParent ? .failure(Failure()) : .success(nodes[$0].parent) },
            maxHops: maxHops
        )
    }

    // The measured shape: button → … → session web area → shell web area →
    // window. The NEAREST web area wins; the shell's is never consulted.
    func testTheNearestWebAreaWins() {
        let nodes = [
            Node(role: "AXButton", parent: 1),
            Node(role: "AXGroup", parent: 2),
            Node(role: "AXWebArea", url: "https://claude.ai/epitaxy/local_a", parent: 3),
            Node(role: "AXWebArea", url: "file:///shell/index.html", parent: 4),
            Node(role: "AXWindow", parent: nil),
        ]
        XCTAssertEqual(walk(nodes), .webArea(url: "https://claude.ai/epitaxy/local_a"))
    }

    // Focus in the shell (sidebar): its nearest web area is the shell's, which
    // the parser then refuses — never a session further down another branch.
    func testFocusInTheShellReportsTheShell() {
        let nodes = [
            Node(role: "AXButton", parent: 1),
            Node(role: "AXWebArea", url: "file:///shell/index.html", parent: 2),
            Node(role: "AXWindow", parent: nil),
        ]
        XCTAssertEqual(walk(nodes), .webArea(url: "file:///shell/index.html"))
    }

    func testNoWebAreaUpToTheTop() {
        let nodes = [Node(role: "AXButton", parent: 1), Node(role: "AXWindow", parent: nil)]
        XCTAssertEqual(walk(nodes), .noWebArea)
    }

    func testAnAXErrorEndsTheWalk() {
        XCTAssertEqual(walk([Node(role: "AXButton", parent: 1, failsParent: true), Node(role: "AXWebArea")]), .unavailable)
        XCTAssertEqual(walk([Node(role: "AXButton", parent: 1), Node(failsRole: true)]), .unavailable)
    }

    // A cyclic tree cannot hold the main actor.
    func testTheHopCapEndsACycle() {
        let nodes = [Node(role: "AXGroup", parent: 1), Node(role: "AXGroup", parent: 0)]
        XCTAssertEqual(walk(nodes, maxHops: 10), .unavailable)
    }

    // Codex review, PR #333: the hop cap is not a time bound. An app that
    // answers every message just under the messaging timeout must still be
    // abandoned once the attempt's budget is spent, having sent no message
    // after it.
    func testTheTimeBudgetEndsTheWalkBeforeTheNextMessage() {
        let nodes = (0..<40).map { Node(role: "AXGroup", parent: $0 + 1 < 40 ? $0 + 1 : nil) }
        var roleReads = 0
        var budgetChecks = 0
        let lookup = AXClaudeDesktopSessionURLReader.nearestWebArea(
            from: 0,
            role: { roleReads += 1; return .success(nodes[$0].role) },
            url: { _ in .success(nil) },
            parent: { .success(nodes[$0].parent) },
            outOfTime: { budgetChecks += 1; return budgetChecks > 3 }
        )
        XCTAssertEqual(lookup, .unavailable)
        XCTAssertEqual(roleReads, 3, "no AX message after the budget ran out")
    }

    // MARK: - The retry

    private final class Calls: @unchecked Sendable {
        var reads = 0
        var sleeps: [Double] = []
    }

    private func reader(
        _ results: [ClaudeDesktopWebAreaLookup], calls: Calls
    ) -> AXClaudeDesktopSessionURLReader {
        AXClaudeDesktopSessionURLReader(
            readOnce: { _ in
                defer { calls.reads += 1 }
                return results[min(calls.reads, results.count - 1)]
            },
            sleepFor: { calls.sleeps.append($0) }
        )
    }

    func testAFoundAddressIsReturnedWithoutRetrying() async {
        let calls = Calls()
        let address = await reader([.webArea(url: "https://claude.ai/epitaxy/local_a")], calls: calls)
            .focusedSessionURL(applicationPID: 1)
        XCTAssertEqual(address, "https://claude.ai/epitaxy/local_a")
        XCTAssertEqual(calls.reads, 1)
        XCTAssertEqual(calls.sleeps, [])
    }

    // Electron builds its tree only once asked: the first read after launch
    // finds no web area, and one bounded wait later the tree is there.
    func testAMissingTreeIsRetriedOnceAfterTheBuildWait() async {
        let calls = Calls()
        let address = await reader(
            [.noWebArea, .webArea(url: "https://claude.ai/epitaxy/local_a")], calls: calls
        ).focusedSessionURL(applicationPID: 1)
        XCTAssertEqual(address, "https://claude.ai/epitaxy/local_a")
        XCTAssertEqual(calls.reads, 2)
        XCTAssertEqual(calls.sleeps, [AXClaudeDesktopSessionURLReader.treeBuildWaitSeconds])
    }

    func testOnlyOneRetry() async {
        let calls = Calls()
        let address = await reader([.noWebArea], calls: calls).focusedSessionURL(applicationPID: 1)
        XCTAssertNil(address)
        XCTAssertEqual(calls.reads, 2)
    }

    // Nothing focused, or an AX error: no retry, no address.
    func testUnavailableIsNotRetried() async {
        let calls = Calls()
        let address = await reader([.unavailable], calls: calls).focusedSessionURL(applicationPID: 1)
        XCTAssertNil(address)
        XCTAssertEqual(calls.reads, 1)
        XCTAssertEqual(calls.sleeps, [])
    }

    // The reply gets the browser reader's shape check before the parser sees it.
    func testMalformedAddressesAreDropped() async {
        for bad: String? in [nil, "", "https://claude.ai/epitaxy/local_a\nX"] {
            let address = await reader([.webArea(url: bad)], calls: Calls())
                .focusedSessionURL(applicationPID: 1)
            XCTAssertNil(address)
        }
    }
}
