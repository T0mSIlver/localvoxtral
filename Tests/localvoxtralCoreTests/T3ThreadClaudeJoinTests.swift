import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// Test clock: the registry never reads the wall clock itself.
private final class T3JoinTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// The T3 Code join (LVX-55): the thread id in the address of the web view
/// whose composer holds focus, against the `T3CODE_THREAD_ID` a live
/// session's own hooks published. The Claude Desktop arm's shape, so these
/// tests mirror `DesktopSessionClaudeJoinTests`.
@MainActor
final class T3ThreadClaudeJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:host-a")
    private let t3 = TerminalScreenTarget(pid: 7070, bundleID: T3CodeAllowlist.bundleID)
    private let desktop = TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
    private let threadID = "1ee24371-ab04-46f6-9d0e-4a845f8ee58f"
    private let environmentID = "74a15ae1-8c33-453a-8378-35d6f10dafc5"
    private var threadAddress: String { "t3code://app/#/\(environmentID)/\(threadID)" }

    private func record(session: String = "s1", claudePID: Int32? = 9001, t3ThreadID: String? = nil) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: claudePID.map {
                ClaudeHookProcessInfo(hookPID: 777, claudePID: $0, t3ThreadID: t3ThreadID ?? threadID)
            }
        )
    }

    private func makeRegistry(clock: T3JoinTestClock? = nil) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(now: (clock ?? T3JoinTestClock(epoch)).now, isProcessAlive: { _ in true })
    }

    private func resolver(registry: ClaudeSessionRegistry, read: T3CodeFocusRead) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            focusedDesktopSessionURL: { _ in .address("https://claude.ai/epitaxy/local_x") },
            focusedT3ThreadURL: { _ in read },
            focusedWindowID: { _ in 101 }
        )
    }

    // MARK: - The joins

    func testFocusedThreadJoinsALocalSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let resolved = await resolver(registry: registry, read: .address(threadAddress)).resolve(target: t3)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .t3Thread)
        XCTAssertEqual(join.snapshot.sessionID, "s1")
        XCTAssertEqual(join.t3Thread?.t3ThreadID, threadID)
        XCTAssertNil(join.desktopSession)
        XCTAssertNil(join.windowID, "no screen capture to pair")
        XCTAssertNil(join.socketPaneKey)
        XCTAssertEqual(join.localWorkspacePath?.path, "/repo")
    }

    /// A thread T3 Code runs on another machine (the dev box): the remote hook
    /// sends the id as a header. It joins, and its workspace stays remote.
    func testFocusedThreadJoinsARemoteSession() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(
            record(claudePID: nil), origin: remote,
            environment: ClaudeRemoteSessionEnvironment(t3ThreadID: threadID)
        ))
        let resolved = await resolver(registry: registry, read: .address(threadAddress)).resolve(target: t3)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .t3Thread)
        XCTAssertNil(join.localWorkspacePath, "a remote session never hands a path to the collector")
    }

    /// An agent-launched thread's id has colons, which the router may
    /// percent-encode.
    func testAnAgentLaunchedThreadJoinsEncodedOrNot() async throws {
        let launched = "mcp:launch:" + String(repeating: "ab", count: 32)
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(t3ThreadID: launched), origin: local))
        for address in [
            "t3code://app/#/\(environmentID)/\(launched)",
            "t3code://app/#/\(environmentID)/" + launched.replacingOccurrences(of: ":", with: "%3A"),
        ] {
            let resolved = await resolver(registry: registry, read: .address(address)).resolve(target: t3)
            XCTAssertEqual(resolved?.snapshot.sessionID, "s1", address)
        }
    }

    // MARK: - Abstentions

    func testEveryNonAnswerAbstainsAndSaysWhy() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let cases: [(T3CodeFocusRead, String, Bool)] = [
            (.refused(.outsideComposer), "t3Thread: focus is not in a T3 Code thread's composer", false),
            (.refused(.noWebView), "t3Thread: focus is not inside a T3 Code web view", false),
            (.refused(.unavailable), "t3Thread: focused T3 Code view address unavailable", false),
            (.address("t3code://app/#/draft/abc"), "t3Thread: focus is not in a T3 Code thread", false),
            (.address("t3code://app/#/\(environmentID)/\(UUID().uuidString)"),
             "t3Thread: no live session reports this T3 Code thread", true),
        ]
        for (read, cause, unmatched) in cases {
            let (_, causes) = await ClaudeJoinAbstentionTap.collecting {
                let resolution = await resolver(registry: registry, read: read).resolution(target: t3)
                XCTAssertNil(resolution.join, cause)
                XCTAssertEqual(resolution.focusedSessionUnmatched, unmatched, cause)
            }
            XCTAssertEqual(causes, [cause])
        }
    }

    func testTwoSessionsReportingOneThreadAbstain() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        XCTAssertNotNil(registry.ingest(record(session: "s2", claudePID: 9002), origin: local))
        let resolved = await resolver(registry: registry, read: .address(threadAddress)).resolve(target: t3)
        XCTAssertNil(resolved)
    }

    func testDesktopAndT3IdsAreNotInterchangeable() async {
        let registry = makeRegistry()
        let desktopRecord = ClaudeHookRecord(
            event: .sessionStart, sessionID: "d1", timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
            process: ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, desktopSessionID: threadID)
        )
        XCTAssertNotNil(registry.ingest(desktopRecord, origin: local))
        let resolved = await resolver(registry: registry, read: .address(threadAddress)).resolve(target: t3)
        XCTAssertNil(resolved, "a desktop id equal to the thread id is not a thread report")
        XCTAssertEqual(registry.resolve(t3ThreadID: threadID), .unknown)
    }

    /// A Claude Desktop target never reads T3 Code, and the uninjected
    /// resolver abstains for T3 Code.
    func testOnlyAT3TargetReadsT3Code() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let reads = Mutex(0)
        let counting = ClaudeSessionJoinResolver(
            registry: registry,
            focusedT3ThreadURL: { _ in
                reads.withLock { $0 += 1 }
                return .address("t3code://app/#/e/\(self.threadID)")
            }
        )
        _ = await counting.resolve(target: desktop)
        XCTAssertEqual(reads.withLock { $0 }, 0)
        let uninjected = await ClaudeSessionJoinResolver(registry: registry).resolve(target: t3)
        XCTAssertNil(uninjected)
    }

    // MARK: - Screen and liveness

    func testAT3JoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, read: .address(threadAddress))
        let resolved = await joinResolver.resolve(target: t3)
        let arm = try XCTUnwrap(resolved)
        let withWindow = ClaudeSessionJoin(
            target: arm.target, snapshot: arm.snapshot, windowID: 101, mechanism: .t3Thread, t3Thread: arm.t3Thread
        )
        let authorizer = TerminalScreenClaudeJoinAuthorizer(resolver: joinResolver, currentJoin: { withWindow })
        XCTAssertTrue(joinResolver.isStillLive(withWindow), "precondition")
        XCTAssertFalse(authorizer.isAuthorized(target: t3, windowID: 101, paneTTY: nil))
    }

    func testACollisionAfterResolutionKillsTheJoin() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(session: "s1"), origin: local))
        let joinResolver = resolver(registry: registry, read: .address(threadAddress))
        let resolved = await joinResolver.resolve(target: t3)
        let join = try XCTUnwrap(resolved)
        XCTAssertTrue(joinResolver.isStillLive(join))
        XCTAssertNotNil(registry.ingest(record(session: "s2", claudePID: 9002), origin: local))
        XCTAssertFalse(joinResolver.isStillLive(join))
    }

    func testAJoinWithoutItsBindingIsNotLive() async throws {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(), origin: local))
        let joinResolver = resolver(registry: registry, read: .address(threadAddress))
        let resolved = await joinResolver.resolve(target: t3)
        let arm = try XCTUnwrap(resolved)
        let unbound = ClaudeSessionJoin(target: arm.target, snapshot: arm.snapshot, windowID: nil, mechanism: .t3Thread)
        XCTAssertFalse(joinResolver.isStillLive(unbound))
    }

    // MARK: - Registry

    /// A thread left open overnight still joins: a record reporting a T3
    /// thread is fresh for the app-view TTL, like a Claude Desktop one (#657).
    func testAnIdleThreadOutlivesTheTerminalTTL() async {
        let clock = T3JoinTestClock(epoch)
        let registry = makeRegistry(clock: clock)
        XCTAssertNotNil(registry.ingest(
            record(claudePID: nil), origin: remote,
            environment: ClaudeRemoteSessionEnvironment(t3ThreadID: threadID)
        ))
        clock.advance(4 * 60 * 60 + 60)  // past the 4 h terminal TTL
        guard case .resolved = registry.resolve(t3ThreadID: threadID) else {
            return XCTFail("an idle T3 thread must stay joinable past the terminal TTL")
        }
        clock.advance(ClaudeRegistryLimits.defaultDesktopSessionTTL)
        XCTAssertEqual(registry.resolve(t3ThreadID: threadID), .stale)
    }

    func testTheThreadIDIsReadFromTheOriginsOwnStore() {
        var localSnapshot = ClaudeSessionSnapshot(sessionID: "a", origin: local, firstSeen: epoch)
        localSnapshot.remoteEnvironment = ClaudeRemoteSessionEnvironment(t3ThreadID: threadID)
        XCTAssertNil(localSnapshot.t3ThreadID, "a local session never reads the remote store")
        XCTAssertFalse(localSnapshot.reportsAppViewID)
        localSnapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, t3ThreadID: threadID)
        XCTAssertEqual(localSnapshot.t3ThreadID, threadID)
        XCTAssertTrue(localSnapshot.reportsAppViewID)
    }

    func testAllowlistIsExactAndDisjoint() {
        XCTAssertTrue(T3CodeAllowlist.isSupported("com.t3tools.t3code"))
        XCTAssertFalse(T3CodeAllowlist.isSupported("com.t3tools.t3code.helper"))
        XCTAssertFalse(T3CodeAllowlist.isSupported(nil))
        XCTAssertFalse(ClaudeDesktopAllowlist.isSupported(T3CodeAllowlist.bundleID))
        XCTAssertFalse(TerminalScreenAllowlist.isSupported(T3CodeAllowlist.bundleID))
        XCTAssertFalse(BrowserTabAllowlist.isSupported(T3CodeAllowlist.bundleID))
    }

    func testJoinSummaryNamesTheArm() {
        XCTAssertEqual(ClaudeSessionJoinSummary.armName(.t3Thread), "t3Thread")
    }
}

final class T3CodeThreadURLTests: XCTestCase {
    private let env = "74a15ae1-8c33-453a-8378-35d6f10dafc5"
    private let thread = "1ee24371-ab04-46f6-9d0e-4a845f8ee58f"

    func testTheProductionAddressParses() {
        XCTAssertEqual(T3CodeThreadURL.threadID(inWebAreaURL: "t3code://app/#/\(env)/\(thread)"), thread)
        XCTAssertEqual(T3CodeThreadURL.threadID(inWebAreaURL: "t3code://app#/\(env)/\(thread)"), thread)
        XCTAssertEqual(T3CodeThreadURL.threadID(inWebAreaURL: "t3code://app/#/\(env)/\(thread)/"), thread)
        XCTAssertEqual(
            T3CodeThreadURL.threadID(inWebAreaURL: "t3code://app/#/\(env)/\(thread)?panel=diff"), thread,
            "the hash router keeps search params after the route"
        )
    }

    func testEveryOtherShapeIsRejected() {
        for address in [
            // Another origin: the integrated browser, a dev build, a lookalike.
            "https://app/#/\(env)/\(thread)",
            "http://localhost:3773/#/\(env)/\(thread)",
            "t3code-dev://app/#/\(env)/\(thread)",
            "t3code://evil/#/\(env)/\(thread)",
            "t3code://app:80/#/\(env)/\(thread)",
            "t3code://user@app/#/\(env)/\(thread)",
            "t3code://app/other/#/\(env)/\(thread)",
            // The route in the path, not the fragment (the web build's shape).
            "t3code://app/\(env)/\(thread)",
            // Other routes and malformed ones.
            "t3code://app/#/",
            "t3code://app/#/\(thread)",
            "t3code://app/#/draft/",
            "t3code://app/#/draft/abc",
            "t3code://app/#/projects/abc",
            "t3code://app/#/\(env)/\(thread)/extra",
            "t3code://app/#//\(thread)",
            "t3code://app/#/\(env)//",
            "t3code://app/#/\(env)/\(thread)//",
            "t3code://app/#/\(env)/thread%2Fother",
            "t3code://app/#/\(env)/th%20read",
            "t3code://app/#/\(env)/\u{0442}hread",
            "t3code://app/#/\(env)/" + String(repeating: "a", count: T3CodeThreadURL.maxThreadIDCount + 1),
            "t3code://app/",
            "not a url",
        ] {
            XCTAssertNil(T3CodeThreadURL.threadID(inWebAreaURL: address), address)
        }
    }
}
