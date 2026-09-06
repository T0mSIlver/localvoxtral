import ClaudeContextWire
import CoreGraphics
import Foundation
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

/// The local-tty echo arm: a plain `ssh host` Claude session joined on the tty
/// of the window the user is dictating into.
///
/// It exists because the connection arm cannot serve the config people
/// actually have. `ProxyJump` gives the surface's ssh no TCP socket at all and
/// puts the linkage on a jump host that cannot expose it unprivileged
/// (`docs/agent/invariants.md`); `ControlMaster` gives several windows one
/// connection. Environment does not have either problem: ssh carries it per
/// SESSION CHANNEL. MEASURED 2026-09-06 — `LC_LVX_TTY` arrives unchanged
/// through a ProxyJump, and two sessions over one ControlMaster connection
/// each receive their own value.
///
/// The tty the arm compares against is read the way the LOCAL arm reads it,
/// through the terminal's own scripting interface. Nothing the remote host
/// says decides which window is focused.
@MainActor
final class RemoteLocalTTYJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let ghostty = TerminalScreenTarget(
        pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let hostID = "h1a2b3c4"
    private let otherHostID = "h9z8y7x6"
    /// What the AppleScript reader returns for the focused window, and what the
    /// user's shell exported into `LC_LVX_TTY` before running ssh.
    private let surfaceTTY = "/dev/ttys004"

    private func makeRegistry() -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(now: { [epoch] in epoch }, isProcessAlive: { _ in true })
    }

    @discardableResult
    private func ingestRemoteSession(
        into registry: ClaudeSessionRegistry,
        sessionID: String = "s-remote-1",
        host: String? = nil,
        environment: ClaudeRemoteSessionEnvironment? = nil
    ) -> ClaudeSessionSnapshot? {
        let hostID = host ?? self.hostID
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                hostID: hostID, sessionID: sessionID
            ),
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            process: ClaudeHookProcessInfo(hookPID: 11, claudePID: 12, tty: "/dev/pts/3")
        )
        return registry.ingest(
            record,
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID)),
            environment: environment ?? ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", localTTY: surfaceTTY, hookParentPID: "4711"
            )
        )
    }

    private func enrolledHost(id: String? = nil, alias: String = "Sandbox") -> ClaudeRemoteHost {
        ClaudeRemoteHost(
            id: id ?? hostID,
            label: "sandbox",
            sshHostAlias: alias,
            createdAt: epoch,
            lastSeenAt: nil,
            revokedAt: nil
        )
    }

    /// The surface's ssh started a minute before the session was first seen —
    /// the only ordering a real window can produce, since the session is
    /// created INSIDE that ssh.
    private var sshStartedAt: Date { epoch.addingTimeInterval(-60) }

    /// The owner's actual shape: a ProxyJump'd connection, so the surface's ssh
    /// holds NO socket. This arm must not care, and the fixture says so by
    /// defaulting to exactly that.
    private func surfaceConnection(
        destination: String = "sandbox",
        sockets: [SSHClientSocket]? = [],
        startedAt: Date? = nil,
        noStartTime: Bool = false
    ) -> SSHDestinationTTYProbeResult {
        .connection(
            SSHSurfaceConnection(
                destination: destination,
                hasCompetingHerdrClient: false,
                herdr: .notHerdr,
                usesProxyJump: true,
                sockets: sockets,
                surfaceProcessStartTime: noStartTime ? nil : (startedAt ?? sshStartedAt)
            )
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        sshResult: SSHDestinationTTYProbeResult,
        hosts: [ClaudeRemoteHost]? = nil,
        focusedTTY: String? = nil
    ) -> ClaudeSessionJoinResolver {
        let hostList = hosts ?? [enrolledHost()]
        let tty = focusedTTY ?? surfaceTTY
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in tty },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in false },
            sshDestinationProbe: { _ in sshResult },
            enrolledHosts: { destination in
                hostList.filter { $0.sshHostAlias?.lowercased() == destination.lowercased() }
            },
            speculativeHosts: { hostList }
        )
    }

    // MARK: - The join

    func testAPlainSSHSessionJoinsOnTheTTYItEchoedBack() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)

        let resolved = await resolver(registry: registry, sshResult: surfaceConnection())
            .resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)

        XCTAssertEqual(join.mechanism, .remoteLocalTTY)
        XCTAssertEqual(
            join.snapshot.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-remote-1")
        )
        XCTAssertNil(join.localWorkspacePath, "a remote origin carries no local workspace")
        XCTAssertNil(join.herdrPane)
        XCTAssertNil(join.remoteHerdrForward)
    }

    func testTheJoinNeedsNoSocketAtAllWhichIsThePoint() async throws {
        // The fixture already gives the surface's ssh an EMPTY socket list —
        // the ProxyJump shape, where the connection arm can never answer. This
        // pins that the local-tty arm is reached and satisfied anyway, and it
        // is the whole reason the arm exists.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(registry: registry, sshResult: self.surfaceConnection())
                .resolve(target: self.ghostty)
        }
        XCTAssertEqual(join?.mechanism, .remoteLocalTTY)
        XCTAssertFalse(
            causes.contains { $0.hasPrefix("remote-ssh:") },
            "the connection arm must never even run once this one answered: \(causes)"
        )
    }

    func testAnUnreadableSocketTableIsAlsoIrrelevantHere() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let resolved = await resolver(
            registry: registry, sshResult: surfaceConnection(sockets: nil)
        ).resolve(target: ghostty)
        XCTAssertEqual(try XCTUnwrap(resolved).mechanism, .remoteLocalTTY)
    }

    func testTheJoinIsReportedUnderItsOwnArmName() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let join = await resolver(registry: registry, sshResult: surfaceConnection())
            .resolve(target: ghostty)
        XCTAssertEqual(
            ClaudeSessionJoinSummary.summarize(join: join, abstentions: []).arm,
            "remoteLocalTTY"
        )
    }

    func testTheJoinNeverAuthorizesRawScreenAttachment() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let joinResolver = resolver(registry: registry, sshResult: surfaceConnection())
        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        let authorizer = TerminalScreenClaudeJoinAuthorizer(
            resolver: joinResolver, currentJoin: { join }
        )
        XCTAssertFalse(authorizer.isAuthorized(target: ghostty, windowID: 101))
    }

    // MARK: - Abstentions

    private func assertNoJoin(
        _ sshResult: SSHDestinationTTYProbeResult,
        registry: ClaudeSessionRegistry,
        hosts: [ClaudeRemoteHost]? = nil,
        focusedTTY: String? = nil,
        expectedCause: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(
                registry: registry, sshResult: sshResult, hosts: hosts, focusedTTY: focusedTTY
            ).resolve(target: self.ghostty)
        }
        XCTAssertNil(join, file: file, line: line)
        if let expectedCause {
            XCTAssertTrue(
                causes.contains("remote-tty: \(expectedCause)"),
                "expected `remote-tty: \(expectedCause)`, got \(causes)",
                file: file, line: line
            )
        }
    }

    func testATTYMismatchDoesNotJoin() async {
        // The load-bearing case: the session is on the right host and reports a
        // well-formed tty — just not this window's.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", localTTY: "/dev/ttys009"
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session reports this terminal's tty"
        )
    }

    func testASessionOnANOTHERENROLLEDHOSTCannotClaimThisWindow() async {
        // The origin pin, and it is what bounds a compromised host: it may
        // claim any tty name it likes, but only for windows whose ssh actually
        // goes to IT.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry, host: otherHostID)
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            hosts: [enrolledHost(), enrolledHost(id: otherHostID, alias: "elsewhere")]
        )
    }

    func testTwoSessionsClaimingOneTTYAbstain() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry, sessionID: "s-remote-1")
        ingestRemoteSession(into: registry, sessionID: "s-remote-2")
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "several live sessions claim this terminal's tty"
        )
    }

    func testASessionInsideAMultiplexerDoesNotJoin() async {
        // A multiplexer server keeps the FIRST client's environment, so a
        // pane's `$LC_LVX_TTY` names whichever window started the server —
        // the same inheritance that rules tmux out of the connection arm.
        for label in ClaudeSessionJoinResolver.multiplexerLabels {
            let registry = makeRegistry()
            var environment = ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", localTTY: surfaceTTY
            )
            environment[label] = "x"
            ingestRemoteSession(into: registry, environment: environment)
            await assertNoJoin(
                surfaceConnection(), registry: registry,
                expectedCause: "no live session on this host is a plain ssh shell"
            )
        }
    }

    func testASessionWithNoSSHTTYDoesNotJoin() async {
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(localTTY: surfaceTTY)
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testAMalformedTTYValueIsRefusedRatherThanCompared() async {
        for value in ["", "ttys004", "/etc/passwd", "/dev/../etc/passwd", "/dev/"] {
            let registry = makeRegistry()
            ingestRemoteSession(
                into: registry,
                environment: ClaudeRemoteSessionEnvironment(
                    sshTTY: "/dev/pts/3", localTTY: value
                )
            )
            await assertNoJoin(
                surfaceConnection(), registry: registry,
                expectedCause: "no live session on this host reports its local tty"
            )
        }
    }

    func testTwoEnrolledHostsSharingTheDestinationAbstain() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            hosts: [enrolledHost(), enrolledHost(id: otherHostID)],
            expectedCause: "ssh destination matches multiple enrolled hosts"
        )
    }

    func testAnUndeterminableSSHProbeAbstains() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            .undeterminable(.unreadableArguments), registry: registry,
            expectedCause: "ssh session undeterminable (unreadable argv)"
        )
    }

    func testASurfaceWithNoSSHAtAllIsNotAnAbstention() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(registry: registry, sshResult: .noSSHClient)
                .resolve(target: self.ghostty)
        }
        XCTAssertNil(join)
        XCTAssertFalse(causes.contains { $0.hasPrefix("remote-tty:") }, "\(causes)")
    }

    // MARK: - The recycled tty

    func testASESSIONOLDERTHANTHISWINDOWSSSHDoesNotJoin() async {
        // THE mis-join this arm would otherwise have. macOS hands out pty
        // minors first-free, so a closed window's `/dev/ttysNNN` goes to the
        // next window opened — while the dead session's registry entry lives
        // on for the session TTL with no liveness check available for another
        // machine's pid. Fixtured exactly so: the session was first seen
        // BEFORE this window's ssh existed, so it cannot be the session this
        // ssh created, and everything else about it matches perfectly.
        // Found by review, 2026-09-06.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(startedAt: epoch.addingTimeInterval(60)),
            registry: registry,
            expectedCause: "the session claiming this tty predates this terminal's ssh"
        )
    }

    func testASessionFirstSeenEXACTLYWhenTheSSHStartedStillJoins() async throws {
        // The boundary is inclusive on purpose: a session cannot be seen
        // before the ssh that created it, so equality is the earliest honest
        // ordering and must not be refused.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let resolved = await resolver(
            registry: registry, sshResult: surfaceConnection(startedAt: epoch)
        ).resolve(target: ghostty)
        XCTAssertEqual(try XCTUnwrap(resolved).mechanism, .remoteLocalTTY)
    }

    func testAnUnreadableSSHStartTimeRefusesRatherThanSkippingTheCheck() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(noStartTime: true), registry: registry,
            expectedCause: "this terminal's ssh has no readable start time"
        )
    }

    // MARK: - The socket corroboration, where a socket exists

    func testWhereTheSSHDOESHoldASocketTheSessionMustBeOnIt() async {
        // A pure negative check: in the direct shape the kernel can still
        // speak, so the tty arm is strictly stronger than the connection arm
        // rather than a weaker alternative to it. Here the tty matches and the
        // ports do not.
        let socket = SSHClientSocket(localPort: 51_960, peerPort: 22, peerAddress: "192.168.1.9")
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                localTTY: surfaceTTY,
                sshConnection: "10.0.0.2,40001,192.168.1.9,22"
            )
        )
        await assertNoJoin(
            surfaceConnection(sockets: [socket]), registry: registry,
            expectedCause: "the session claiming this tty is not on this terminal's connection"
        )
    }

    func testWhereTheSSHHoldsASocketAndTheSessionISOnItTheJoinStands() async throws {
        let socket = SSHClientSocket(localPort: 51_960, peerPort: 22, peerAddress: "192.168.1.9")
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                localTTY: surfaceTTY,
                sshConnection: "10.0.0.2,51960,192.168.1.9,22"
            )
        )
        let resolved = await resolver(
            registry: registry, sshResult: surfaceConnection(sockets: [socket])
        ).resolve(target: ghostty)
        XCTAssertEqual(try XCTUnwrap(resolved).mechanism, .remoteLocalTTY)
    }

    // MARK: - Falling through to the connection arm

    func testASessionWithNoLocalTTYFallsThroughToTheConnectionArm() async throws {
        // The zero-setup path stays intact: a user who never exported
        // `LC_LVX_TTY` still joins on the connection when their config allows
        // it. This is the ONE case where both arms are exercised in order.
        let socket = SSHClientSocket(localPort: 51_960, peerPort: 22, peerAddress: "192.168.1.9")
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", sshConnection: "10.0.0.2,51960,192.168.1.9,22"
            )
        )
        let direct: SSHDestinationTTYProbeResult = .connection(
            SSHSurfaceConnection(
                destination: "sandbox",
                hasCompetingHerdrClient: false,
                herdr: .notHerdr,
                sockets: [socket],
                surfaceProcessStartTime: sshStartedAt
            )
        )
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(registry: registry, sshResult: direct)
                .resolve(target: self.ghostty)
        }
        XCTAssertEqual(try XCTUnwrap(join).mechanism, .remoteSSHConnection)
        XCTAssertTrue(
            causes.contains("remote-tty: no live session on this host reports its local tty"),
            "the tty arm must say what is missing before falling through: \(causes)"
        )
    }
}

/// The device-path grammar, away from the resolver.
final class ClaudeRemoteLocalTTYPathTests: XCTestCase {
    func testTheShapesRealTerminalsProduceAreAccepted() {
        for value in ["/dev/ttys004", "/dev/ttys000", "/dev/pts/19", "/dev/ttyp0"] {
            XCTAssertTrue(ClaudeRemoteLocalTTYPath.isAcceptable(value), value)
        }
    }

    func testAnythingThatIsNotADeviceUnderDevIsRefused() {
        let refused = [
            "",
            "ttys004",                                   // relative
            "dev/ttys004",
            "/dev/",                                     // no device
            "/dev/tty",                                  // the controlling-terminal ALIAS,
                                                         // which names no particular window
            "/dev/ttys004/",                             // trailing slash
            "/etc/passwd",
            "/dev/../etc/passwd",                        // traversal
            "/dev/pts/../../etc/passwd",
            "/dev/a/b/c",                                // too deep for a tty
            "/dev/tty-004",                              // outside the charset
            "/dev/tty 004",
            "/dev/" + String(repeating: "a", count: 64),  // over the bound
        ]
        for value in refused {
            XCTAssertFalse(ClaudeRemoteLocalTTYPath.isAcceptable(value), "must refuse: \(value)")
        }
    }
}
#endif
