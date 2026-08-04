import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Scripted cmux socket. Records every call so a test can assert that an
/// abstention happened BEFORE any request, not after one.
private final class JoinTestCmuxSurfaces: CmuxSurfaceQuerying, @unchecked Sendable {
    private let focused: CmuxQueryResult<CmuxFocusedSurface>
    private let texts: Mutex<[CmuxQueryResult<String>]>
    private let focusedCalls = Mutex<Int>(0)
    private let textRequests = Mutex<[String]>([])
    private let peerPIDs = Mutex<[pid_t]>([])

    init(
        focused: CmuxQueryResult<CmuxFocusedSurface>,
        texts: [CmuxQueryResult<String>] = []
    ) {
        self.focused = focused
        self.texts = Mutex(texts)
    }

    var focusedSurfaceCallCount: Int { focusedCalls.withLock { $0 } }
    var requestedSurfaceIDs: [String] { textRequests.withLock { $0 } }
    /// Every pid the client was told the peer must turn out to be. The stored
    /// password never leaves the process unless the peer IS that pid.
    var expectedPeerPIDs: [pid_t] { peerPIDs.withLock { $0 } }

    func focusedSurface(expectedPeerPID: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface> {
        focusedCalls.withLock { $0 += 1 }
        peerPIDs.withLock { $0.append(expectedPeerPID) }
        return focused
    }

    func surfaceText(
        surfaceID: String, expectedPeerPID: pid_t
    ) async -> CmuxQueryResult<String> {
        textRequests.withLock { $0.append(surfaceID) }
        peerPIDs.withLock { $0.append(expectedPeerPID) }
        return texts.withLock { $0.isEmpty ? .unavailable : $0.removeFirst() }
    }
}

private final class CmuxJoinLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

/// The cmux surface join: which session a cmux pane resolves to, and — much
/// more often — when it refuses to resolve to one at all.
@MainActor
final class CmuxSurfaceJoinTests: XCTestCase {
    private let cmux = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.cmuxBundleID
    )
    private let surfaceID = "22222222-2222-2222-2222-222222222222"
    private let now = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - Fixtures

    private func makeRegistry(liveness: CmuxJoinLiveness = CmuxJoinLiveness())
        -> ClaudeSessionRegistry
    {
        ClaudeSessionRegistry(
            now: { [now] in now },
            isProcessAlive: liveness.probe,
            allocateMarkerValue: { "lvx-abcd" }
        )
    }

    /// A LOCAL session that published a cmux surface id, exactly as the hook
    /// publisher does over the peer-authenticated socket.
    @discardableResult
    private func ingestLocalSession(
        _ registry: ClaudeSessionRegistry,
        sessionID: String = "local-1",
        surfaceID: String,
        tty: String? = "/dev/ttys004",
        claudePID: Int32 = 9001
    ) -> ClaudeSessionSnapshot? {
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: sessionID,
                timestamp: 0,
                rawCwd: "/repo",
                prompt: nil,
                files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: claudePID,
                    tty: tty,
                    cmuxSurfaceID: surfaceID
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
    }

    /// A REMOTE session whose `cmux ssh` shell reported the same surface id
    /// through the enrolled host's authenticated channel.
    @discardableResult
    private func ingestRemoteSession(
        _ registry: ClaudeSessionRegistry,
        sessionID: String = "remote-1",
        surfaceID: String
    ) -> ClaudeSessionSnapshot? {
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: sessionID,
                timestamp: 0,
                rawCwd: "/remote/repo",
                prompt: nil,
                files: [],
                process: nil
            ),
            origin: .remote(channel: "host-a"),
            environment: ClaudeRemoteSessionEnvironment(cmuxSurfaceID: surfaceID)
        )
    }

    private func makeResolver(
        registry: ClaudeSessionRegistry,
        surfaces: JoinTestCmuxSurfaces?,
        enabled: Bool = true,
        marker: TerminalScreenAXReader.FocusedWindowMarkerRead? = nil,
        statusSink: @escaping @MainActor (CmuxSocketStatus) -> Void = { _ in }
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in marker },
            // cmux has no AppleScript TTY reader; production passes nothing
            // through this seam for it and neither does this suite.
            focusedTerminalTTY: { _ in nil },
            focusedWindowID: { _ in 101 },
            cmuxSurfaces: surfaces,
            cmuxJoinEnabled: { enabled },
            reportCmuxStatus: statusSink
        )
    }

    private func makeSurfaces(
        tty: String? = "/dev/ttys004",
        workspaceIsRemote: Bool? = false,
        texts: [CmuxQueryResult<String>] = []
    ) -> JoinTestCmuxSurfaces {
        JoinTestCmuxSurfaces(
            focused: .value(
                CmuxFocusedSurface(
                    surfaceID: surfaceID, tty: tty, workspaceIsRemote: workspaceIsRemote
                )
            ),
            texts: texts
        )
    }

    // MARK: - The allowlist route

    func testCmuxIsJoinableButNeverCapturedOverAXOrAppleScript() {
        XCTAssertTrue(TerminalScreenAllowlist.isSupported(TerminalScreenAllowlist.cmuxBundleID))
        XCTAssertTrue(
            TerminalScreenAllowlist.isSocketCaptureSupported(TerminalScreenAllowlist.cmuxBundleID)
        )
        XCTAssertFalse(
            TerminalScreenAllowlist.isAXCaptureSupported(TerminalScreenAllowlist.cmuxBundleID),
            "cmux draws into a custom libghostty view with no AX text area"
        )
        XCTAssertFalse(
            TerminalScreenAllowlist.isAppleScriptCaptureSupported(
                TerminalScreenAllowlist.cmuxBundleID
            ),
            "cmux ships no scripting dictionary"
        )
        XCTAssertNil(
            TerminalScreenContextSource.readVisibleScreen(target: cmux),
            "no AX or AppleScript route may answer for cmux"
        )
        XCTAssertFalse(
            TerminalScreenAllowlist.appleEventBundleIDs.contains(
                TerminalScreenAllowlist.cmuxBundleID
            ),
            "pre-warming Automation consent for cmux would prompt for a capability we never use"
        )
    }

    func testTheOtherTerminalsKeepTheirOwnRoutes() {
        XCTAssertFalse(
            TerminalScreenAllowlist.isSocketCaptureSupported(
                TerminalScreenAllowlist.ghosttyBundleID
            )
        )
        XCTAssertFalse(
            TerminalScreenAllowlist.isSocketCaptureSupported(
                TerminalScreenAllowlist.iterm2BundleID
            )
        )
        XCTAssertEqual(TerminalScreenAllowlist.socketCaptureBundleIDs, ["com.cmuxterm.app"])
    }

    // MARK: - The positive paths

    func testLocalSurfaceJoinsTheSessionThatPublishedTheSurfaceID() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces())

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertEqual(join.mechanism, .cmuxSurface)
        XCTAssertEqual(join.cmuxSurface?.surfaceID, surfaceID)
        XCTAssertEqual(join.snapshot.sessionID, "local-1")
        XCTAssertEqual(join.socketPaneKey, surfaceID)
        XCTAssertNotNil(
            join.localWorkspacePath,
            "a local cmux join is an ordinary local join for repo purposes"
        )
    }

    /// A remote session joins only while cmux says the focused surface really
    /// is hosted by a live remote workspace.
    func testRemoteCmuxSSHSessionJoinsWhileTheSurfaceIsRemoteHosted() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertEqual(join.mechanism, .cmuxSurface)
        XCTAssertEqual(join.snapshot.sessionID, "remote-1")
    }

    /// The replay attack the remote arm has to survive: a compromised enrolled
    /// host publishes a `CMUX_SURFACE_ID` it saw during an EARLIER `cmux ssh`
    /// session, after that surface has gone back to a local shell. It is the
    /// sole remote candidate, so nothing but fresh evidence from cmux can stop
    /// it joining and pairing attacker-chosen context with the user's current
    /// local screen.
    func testAReplayedSurfaceIDFromARemoteHostDoesNotJoinALocalSurface() async {
        let registry = makeRegistry()
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: false)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(
            join,
            "a remembered label must not join a surface cmux reports as locally hosted"
        )
    }

    /// cmux not answering the remote-ness question is not permission either —
    /// an older cmux without `workspace.remote.status`, or an errored one.
    func testUnknownRemoteHostingRefusesTheRemoteClaim() async {
        let registry = makeRegistry()
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: nil)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    /// The local arm is unaffected by the remote-hosting answer: a local
    /// session joins its own surface whatever cmux says about workspaces.
    func testLocalJoinDoesNotDependOnTheRemoteHostingAnswer() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: nil)
        )

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertEqual(join.snapshot.sessionID, "local-1")
    }

    /// The whole point of the remote arm's opacity: joining a `cmux ssh`
    /// session must not put another machine's cwd anywhere a collector could
    /// reach it.
    func testRemoteCmuxJoinNeverYieldsALocalWorkspacePath() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertNil(join.localWorkspacePath)
        XCTAssertNil(join.snapshot.localWorkspacePath)
        XCTAssertTrue(
            join.snapshot.localRecentFiles.isEmpty,
            "a remote session's file paths name another machine's filesystem"
        )
    }

    func testAgreeingTTYsStillJoin() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID, tty: "/dev/ttys004")
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(tty: "/dev/ttys004")
        )

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertEqual(join.mechanism, .cmuxSurface)
    }

    /// The join carries the pid the socket peer must turn out to be — the
    /// frontmost cmux app. Without it the client has nothing to authenticate
    /// against before sending the Keychain password.
    func testTheFocusedCmuxAppsPIDIsWhatThePeerMustMatch() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces(texts: [.value("text")])
        let resolver = makeResolver(registry: registry, surfaces: cmuxSocket)

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        _ = await resolver.cmuxSurfaceVisibleText(for: join)

        XCTAssertEqual(cmuxSocket.expectedPeerPIDs, [cmux.pid, cmux.pid])
    }

    // MARK: - The TTY cross-check is mandatory, not best-effort

    /// Absent evidence is not permission. A process that inherited a stale
    /// `CMUX_SURFACE_ID` and moved to another pane publishes no tty we can
    /// contradict — so "no tty" must abstain, not wave the check through.
    func testMissingSurfaceTTYAbstains() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID, tty: "/dev/ttys004")
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces(tty: nil))

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join, "cmux reporting no tty for the surface is not evidence of agreement")
    }

    /// The inverse direction, previously untested: the SESSION published no
    /// tty. That is what an opencode session looks like — its server half
    /// deliberately never claims a pane — so opencode inside cmux does not join
    /// over this arm, by design.
    func testMissingSessionTTYAbstains() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID, tty: nil)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(tty: "/dev/ttys004")
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join, "a session that never claimed a tty cannot be cross-checked")
    }

    func testNeitherSideKnowingATTYAbstains() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID, tty: nil)
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces(tty: nil))

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    // MARK: - The abstention matrix

    func testDisagreeingTTYsAbstain() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID, tty: "/dev/ttys004")
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(tty: "/dev/ttys009")
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join, "a stale surface environment must not join a live pane")
    }

    func testSocketDownAbstains() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = JoinTestCmuxSurfaces(focused: .unavailable)
        let resolver = makeResolver(registry: registry, surfaces: cmuxSocket)

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    func testAuthFailureAbstainsAndSurfacesOneSentence() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = JoinTestCmuxSurfaces(focused: .authenticationRequired)
        let statuses = Mutex<[CmuxSocketStatus]>([])
        let resolver = makeResolver(
            registry: registry,
            surfaces: cmuxSocket,
            statusSink: { status in statuses.withLock { $0.append(status) } }
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
        XCTAssertEqual(statuses.withLock { $0 }, [.authenticationRequired])
        XCTAssertEqual(
            CmuxSocketStatus.authenticationRequired.message,
            "cmux socket requires password mode."
        )
        XCTAssertNil(CmuxSocketStatus.ok.message, "a working socket says nothing in the pane")
    }

    func testCapabilityNotInstalledMakesNoRequestAndAbstains() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(registry: registry, surfaces: nil)

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    func testDisabledSettingNeverDialsTheSocket() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces()
        let resolver = makeResolver(registry: registry, surfaces: cmuxSocket, enabled: false)

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
        XCTAssertEqual(
            cmuxSocket.focusedSurfaceCallCount, 0,
            "an opted-out user's cmux socket must never be contacted"
        )
    }

    func testUnknownFocusedSurfaceAbstains() async {
        let registry = makeRegistry()
        // The session published a DIFFERENT surface id than the one focused.
        ingestLocalSession(registry, surfaceID: "11111111-1111-1111-1111-111111111111")
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces())

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    func testTwoLocalSessionsOnOneSurfaceAbstain() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, sessionID: "local-1", surfaceID: surfaceID, claudePID: 9001)
        ingestLocalSession(registry, sessionID: "local-2", surfaceID: surfaceID, claudePID: 9002)
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces())

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    func testTwoRemoteSessionsOnOneSurfaceAbstain() async {
        let registry = makeRegistry()
        ingestRemoteSession(registry, sessionID: "remote-1", surfaceID: surfaceID)
        ingestRemoteSession(registry, sessionID: "remote-2", surfaceID: surfaceID)
        // Remote-hosted, so the abstention is about the ambiguity and not
        // about the hosting check.
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    /// Should be impossible — one surface hosts one shell. Abstain anyway.
    func testLocalAndRemoteCandidateForOneSurfaceAbstain() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    /// Ambiguity on EITHER side must abstain, not hand the join to the other
    /// origin. Two local claimants make the local side `.ambiguous`; the single
    /// remote claimant used to win by default.
    func testTwoLocalCandidatesPlusOneRemoteAbstain() async {
        let registry = makeRegistry()
        ingestLocalSession(registry, sessionID: "local-1", surfaceID: surfaceID, claudePID: 9001)
        ingestLocalSession(registry, sessionID: "local-2", surfaceID: surfaceID, claudePID: 9002)
        ingestRemoteSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(
            join,
            "an ambiguous local side must not promote the remote claim to the answer"
        )
    }

    /// The mirror image, which used to join the LOCAL session.
    func testTwoRemoteCandidatesPlusOneLocalAbstain() async {
        let registry = makeRegistry()
        ingestRemoteSession(registry, sessionID: "remote-1", surfaceID: surfaceID)
        ingestRemoteSession(registry, sessionID: "remote-2", surfaceID: surfaceID)
        ingestLocalSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(
            registry: registry, surfaces: makeSurfaces(workspaceIsRemote: true)
        )

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(
            join,
            "an ambiguous remote side must not promote the local claim to the answer"
        )
    }

    func testDeadLocalSessionAbstains() async {
        let liveness = CmuxJoinLiveness()
        let registry = makeRegistry(liveness: liveness)
        ingestLocalSession(registry, surfaceID: surfaceID, claudePID: 9001)
        liveness.kill(9001)
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces())

        let join = await resolver.resolve(target: cmux)
        XCTAssertNil(join)
    }

    // MARK: - Origin isolation

    /// The local arm reads `process`, which only a peer-UID-authenticated
    /// record can write. A remote host publishing a surface id can never reach
    /// it, whatever it puts on the wire.
    func testLocalLookupNeverMatchesARemoteSession() {
        let registry = makeRegistry()
        ingestRemoteSession(registry, surfaceID: surfaceID)

        guard case .unknown = registry.resolve(cmuxSurfaceID: surfaceID) else {
            return XCTFail("a remote session must be invisible to the local surface lookup")
        }
    }

    func testRemoteLookupNeverMatchesALocalSession() {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)

        guard case .unknown = registry.resolveRemote(cmuxSurfaceID: surfaceID) else {
            return XCTFail("a local session must be invisible to the remote surface lookup")
        }
    }

    // MARK: - Falling through to the marker

    /// Unlike herdr's, a cmux abstention is not terminal: cmux forwards the
    /// inner OSC 2 to its window title, so a local session under the
    /// title-fallback opt-in can still be joined the old way.
    func testCmuxAbstentionStillTriesTheTitleMarker() async throws {
        let registry = makeRegistry()
        // A session with no cmux surface id at all — only a marker.
        let snapshot = try XCTUnwrap(
            registry.ingest(
                ClaudeHookRecord(
                    event: .sessionStart,
                    sessionID: "marker-1",
                    timestamp: 0,
                    rawCwd: "/repo",
                    prompt: nil,
                    files: [],
                    process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
                ),
                origin: .localAuthenticated(peerUID: 501)
            )
        )
        let resolver = makeResolver(
            registry: registry,
            surfaces: JoinTestCmuxSurfaces(focused: .unavailable),
            marker: TerminalScreenAXReader.FocusedWindowMarkerRead(
                marker: snapshot.marker, windowID: 101
            )
        )

        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        XCTAssertEqual(join.mechanism, .titleMarker)
    }

    // MARK: - Screen authorization

    func testCmuxJoinNeverAuthorizesRawAXAttachment() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let resolver = makeResolver(registry: registry, surfaces: makeSurfaces())
        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)

        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: resolver, currentJoin: { join }
        )
        XCTAssertFalse(
            authorizer.isAuthorized(target: cmux, windowID: 101),
            "there is no accessible cmux text, and a future composite one must not become attachable"
        )
    }

    // MARK: - surface.read_text is keyed by the join

    func testSurfaceReadRequestsExactlyTheJoinedSurface() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces(texts: [.value("cmux pane text")])
        let resolver = makeResolver(registry: registry, surfaces: cmuxSocket)
        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)

        let text = await resolver.cmuxSurfaceVisibleText(for: join)
        XCTAssertEqual(text, "cmux pane text")
        XCTAssertEqual(cmuxSocket.requestedSurfaceIDs, [surfaceID])
    }

    func testHerdrJoinCannotReadThroughTheCmuxClient() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces(texts: [.value("cmux pane text")])
        let resolver = makeResolver(registry: registry, surfaces: cmuxSocket)
        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)
        let impostor = ClaudeSessionJoin(
            target: join.target,
            marker: join.marker,
            snapshot: join.snapshot,
            windowID: join.windowID,
            mechanism: .herdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: "pane-a", socketPath: "/tmp/herdr.sock")
        )

        let text = await resolver.cmuxSurfaceVisibleText(for: impostor)
        XCTAssertNil(text)
        XCTAssertTrue(
            cmuxSocket.requestedSurfaceIDs.isEmpty,
            "a non-cmux join must not reach cmux's socket at all"
        )
    }

    func testDisablingTheSettingStopsTheSurfaceRead() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces(texts: [.value("cmux pane text")])
        // Resolve while enabled, then ask for text as if the user had just
        // turned the toggle off.
        let resolved = await makeResolver(
            registry: registry, surfaces: cmuxSocket
        ).resolve(target: cmux)
        let join = try XCTUnwrap(resolved)
        let disabled = makeResolver(registry: registry, surfaces: cmuxSocket, enabled: false)

        let text = await disabled.cmuxSurfaceVisibleText(for: join)
        XCTAssertNil(text)
        XCTAssertTrue(cmuxSocket.requestedSurfaceIDs.isEmpty)
    }

    func testAuthFailureOnTheReadIsReportedNotAttached() async throws {
        let registry = makeRegistry()
        ingestLocalSession(registry, surfaceID: surfaceID)
        let cmuxSocket = makeSurfaces(texts: [.authenticationRequired])
        let statuses = Mutex<[CmuxSocketStatus]>([])
        let resolver = makeResolver(
            registry: registry,
            surfaces: cmuxSocket,
            statusSink: { status in statuses.withLock { $0.append(status) } }
        )
        let resolvedJoin = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolvedJoin)

        let text = await resolver.cmuxSurfaceVisibleText(for: join)
        XCTAssertNil(text)
        XCTAssertEqual(
            statuses.withLock { $0 }, [.ok, .authenticationRequired],
            "the join succeeded, then the read was refused — both are reported"
        )
    }
}
