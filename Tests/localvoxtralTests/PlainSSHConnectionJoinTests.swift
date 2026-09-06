import ClaudeContextWire
import CoreGraphics
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

/// The plain-ssh arm: a Claude Code session in `ssh host` with no herdr, no
/// cmux and no Remote Control, joined by the TCP CONNECTION the surface's ssh
/// process holds.
///
/// This is the shape #250 left with no join at all when it removed the
/// window-title marker. The replacement's whole claim is that the remote host
/// has to name a port pair that only the two kernels on the ends of one
/// connection know, so most of this file is the matrix of ways that agreement
/// can fail — every one of which must abstain rather than guess.
///
/// The kernel is never read here: the socket list arrives through the probe
/// result the resolver is handed, exactly as the herdr arm's fixtures do.
@MainActor
final class PlainSSHConnectionJoinTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let ghostty = TerminalScreenTarget(
        pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let hostID = "h1a2b3c4"
    private let otherHostID = "h9z8y7x6"
    private let surfaceTTY = "/dev/ttys-outer"

    /// The connection under test, in both spellings: what OUR kernel says about
    /// the socket, and what the REMOTE session reports through `$SSH_CONNECTION`.
    private let clientPort: UInt16 = 51_960
    private let serverPort: UInt16 = 22
    private let serverAddress = "192.168.1.9"

    private var surfaceSocket: SSHClientSocket {
        SSHClientSocket(
            localPort: clientPort, peerPort: serverPort, peerAddress: serverAddress
        )
    }

    /// The value the shim publishes: sshd's four fields re-joined with commas.
    private func reportedConnection(
        client: String = "10.0.0.2",
        clientPort: UInt16? = nil,
        server: String? = nil,
        serverPort: UInt16? = nil
    ) -> String {
        [
            client,
            String(clientPort ?? self.clientPort),
            server ?? serverAddress,
            String(serverPort ?? self.serverPort),
        ].joined(separator: ",")
    }

    private func makeRegistry() -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(now: { [epoch] in epoch }, isProcessAlive: { _ in true })
    }

    /// One live REMOTE session that looks like a plain interactive ssh shell.
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
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection(),
                hookParentPID: "4711"
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

    /// - Parameter unreadableSockets: the probe could not read the fd table.
    ///   A separate flag rather than `sockets: nil`, because nil there is the
    ///   parameter's own "use the default" — the first draft of this file
    ///   conflated the two and the unreadable-table test JOINED (caught by the
    ///   test failing, 2026-09-05).
    private func surfaceConnection(
        destination: String = "sandbox",
        usesProxyJump: Bool = false,
        sockets: [SSHClientSocket]? = nil,
        unreadableSockets: Bool = false,
        siblings: SSHSiblingSurvey = SSHSiblingSurvey()
    ) -> SSHDestinationTTYProbeResult {
        .connection(
            SSHSurfaceConnection(
                destination: destination,
                hasCompetingHerdrClient: false,
                herdr: .notHerdr,
                usesProxyJump: usesProxyJump,
                sockets: unreadableSockets ? nil : (sockets ?? [surfaceSocket]),
                siblings: siblings
            )
        )
    }

    /// The resolver with every OTHER arm disabled: no local herdr client, no
    /// pane query capability, no forward. Whatever answers here answered
    /// through the plain-ssh arm.
    private func resolver(
        registry: ClaudeSessionRegistry,
        sshResult: SSHDestinationTTYProbeResult,
        hosts: [ClaudeRemoteHost]? = nil,
        proxyJump: SSHProxyJumpShape? = nil
    ) -> ClaudeSessionJoinResolver {
        let hostList = hosts ?? [enrolledHost()]
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in false },
            sshDestinationProbe: { _ in sshResult },
            enrolledHosts: { destination in
                hostList.filter { $0.sshHostAlias?.lowercased() == destination.lowercased() }
            },
            // Defaults to nil — "no readable config" — so no test reaches a
            // real `ssh -G`, and the un-injected resolver behaves as it did
            // before the shape existed.
            proxyJumpShape: { _ in proxyJump },
            speculativeHosts: { hostList }
        )
    }

    // MARK: - The join

    func testAPlainSSHSessionJoinsWhenTheReportedConnectionIsTheSurfacesSocket() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)

        let resolved = await resolver(registry: registry, sshResult: surfaceConnection())
            .resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)

        XCTAssertEqual(join.mechanism, .remoteSSHConnection)
        XCTAssertEqual(
            join.snapshot.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-remote-1")
        )
        // A remote origin can never carry a local workspace path, whatever
        // joined it. The type is what enforces that; this pins it for the arm.
        XCTAssertNil(join.localWorkspacePath)
        XCTAssertNil(join.herdrPane, "a plain ssh join binds no pane")
        XCTAssertNil(join.remoteHerdrForward, "and opens no forward")
    }

    func testTheJoinIsReportedUnderItsOwnArmName() async throws {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let join = await resolver(registry: registry, sshResult: surfaceConnection())
            .resolve(target: ghostty)
        XCTAssertEqual(
            ClaudeSessionJoinSummary.summarize(join: join, abstentions: []).arm,
            "remoteSSHConnection"
        )
    }

    func testTheJoinNeverAuthorizesRawScreenAttachment() async throws {
        // The marker join never licensed a raw AX capture for a remote session
        // and neither does its replacement: the grid is the user's whole remote
        // shell, not this session's pane.
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

    func testAnIPv4MappedPeerMatchesThePlainIPv4TheServerReports() async throws {
        // A dual-stack socket describes an IPv4 peer as `::ffff:a.b.c.d` while
        // sshd — reading its own AF_INET peer — writes `a.b.c.d`. Both are the
        // same address, and comparing the text would abstain on the ordinary
        // case.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let mapped = SSHClientSocket(
            localPort: clientPort, peerPort: serverPort,
            peerAddress: "::ffff:\(serverAddress)"
        )
        let join = await resolver(
            registry: registry, sshResult: surfaceConnection(sockets: [mapped])
        ).resolve(target: ghostty)
        XCTAssertEqual(join?.mechanism, .remoteSSHConnection)
    }

    func testTheMatchingSocketMayBeOneOfSeveralTheProcessHolds() async throws {
        // An `ssh -L` with a live forwarded connection gives the client extra
        // established sockets. The transport socket still has to be found among
        // them — the arm matches a tuple, it does not require a lone socket.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let forwarded = SSHClientSocket(
            localPort: 44_000, peerPort: 53_000, peerAddress: "127.0.0.1"
        )
        let join = await resolver(
            registry: registry,
            sshResult: surfaceConnection(sockets: [forwarded, surfaceSocket])
        ).resolve(target: ghostty)
        XCTAssertEqual(join?.mechanism, .remoteSSHConnection)
    }

    // MARK: - Abstentions

    private func assertNoJoin(
        _ sshResult: SSHDestinationTTYProbeResult,
        registry: ClaudeSessionRegistry,
        hosts: [ClaudeRemoteHost]? = nil,
        proxyJump: SSHProxyJumpShape? = nil,
        expectedCause: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(
                registry: registry, sshResult: sshResult, hosts: hosts, proxyJump: proxyJump
            ).resolve(target: self.ghostty)
        }
        XCTAssertNil(join, file: file, line: line)
        if let expectedCause {
            XCTAssertTrue(
                causes.contains("remote-ssh: \(expectedCause)"),
                "expected `remote-ssh: \(expectedCause)`, got \(causes)",
                file: file, line: line
            )
        }
    }

    func testAClientPortMismatchDoesNotJoin() async {
        // The load-bearing case. The session is on the right host, is a plain
        // ssh shell, and reports a well-formed connection — but not THIS one.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection(clientPort: clientPort &+ 1)
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session reports this surface's connection"
        )
    }

    func testAServerPortMismatchDoesNotJoin() async {
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection(serverPort: 2222)
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session reports this surface's connection"
        )
    }

    func testAServerAddressMismatchDoesNotJoin() async {
        // Both ports agree and the address does not: a host claiming a
        // connection whose ports it guessed (or inherited) still has to name
        // the address our own socket actually talks to.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection(server: "192.168.1.10")
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session reports this surface's connection"
        )
    }

    func testAProxyJumpSurfaceDoesNotJoinEvenWhenThePortsWouldAgree() async {
        // With `-J` the local socket goes to the JUMP host while the
        // destination's sshd sees the jump host's source port, so the two
        // halves describe different connections. Fixtured so the ports DO
        // agree: without the explicit refusal this would be a mis-join.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(usesProxyJump: true), registry: registry,
            expectedCause: "the connection goes through a jump host"
        )
    }

    func testASessionInsideTmuxDoesNotJoinEvenWithAMatchingConnection() async {
        // Measured on the dev box, 2026-09-05: a tmux server started by
        // connection A keeps A's `$SSH_CONNECTION` in every pane, so a session
        // reporting a matching tuple may be living in a DIFFERENT surface's
        // connection. That is a mis-join, not a missed one.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                tmux: "/tmp/tmux-1000/default,3721,0",
                tmuxPane: "%3",
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection()
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testASessionInsideHerdrDoesNotJoinThroughThisArm() async {
        // herdr is a multiplexer with the same inheritance property, and it has
        // an arm of its own that binds the pane rather than the connection.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                herdrPaneID: "pane-7",
                herdrSocketPath: "/run/user/1000/herdr/default.sock",
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection()
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testASessionInsideCmuxDoesNotJoinThroughThisArm() async {
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                cmuxSurfaceID: "surface-3",
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection()
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testASessionWithNoSSHTTYDoesNotJoin() async {
        // `ssh host claude -p …` is not a surface anyone is dictating into.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(sshConnection: reportedConnection())
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testTwoSessionsReportingTheSameConnectionAbstain() async {
        // Two agents inside ONE ssh session share its `$SSH_CONNECTION`.
        // Nothing here says which one the user is looking at.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry, sessionID: "s-remote-1")
        ingestRemoteSession(into: registry, sessionID: "s-remote-2")
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "several live sessions report this surface's connection"
        )
    }

    func testASessionOnANOTHERENROLLEDHOSTCannotClaimThisSurface() async {
        // The origin-host pin. The session's tuple matches the surface's socket
        // exactly — it is registered against a DIFFERENT enrolled host's
        // channel, and the candidate set never contains it.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry, host: otherHostID)
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            hosts: [enrolledHost(), enrolledHost(id: otherHostID, alias: "elsewhere")]
        )
    }

    func testAnUnreadableSocketTableAbstainsRatherThanReadingAsNoSockets() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(unreadableSockets: true), registry: registry,
            expectedCause: "this ssh's socket table is unreadable"
        )
    }

    func testAnSSHHoldingNoEstablishedSocketAbstains() async {
        // A `ProxyCommand` from ssh_config is invisible in argv and leaves the
        // client with no TCP socket of its own.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(sockets: []), registry: registry,
            expectedCause: "this ssh holds no connection of its own "
                + "(a ControlMaster client or a ProxyCommand)"
        )
    }

    // MARK: The shape the owner's Mac actually has

    func testAProxyJumpedConnectionSaysSoInsteadOfGuessingAtControlMaster() async {
        // The field case (2026-09-06). `ProxyJump` lives in `~/.ssh/config`,
        // is invisible in argv, and is carried by an `ssh -W` CHILD — so the
        // surface's own ssh holds no TCP socket, exactly like a ControlMaster
        // client. The old wording blamed ControlMaster; `ssh -G` knows better.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(sockets: []), registry: registry, proxyJump: .singleHop,
            expectedCause: "this connection goes through a jump host (ProxyJump)"
        )
    }

    func testAChainOfJumpHostsHasItsOwnCause() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(sockets: []), registry: registry, proxyJump: .chain,
            expectedCause: "this connection goes through a chain of jump hosts"
        )
    }

    func testAnUnreadableSSHConfigFallsBackToTheOlderWording() async {
        // Nothing is claimed that was not read: with no `ssh -G` answer the
        // arm says what it can still see, which is a socketless client.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(sockets: []), registry: registry, proxyJump: nil,
            expectedCause: "this ssh holds no connection of its own "
                + "(a ControlMaster client or a ProxyCommand)"
        )
    }

    func testAConfigWithNoProxyJumpStillBlamesTheSocketlessClient() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(sockets: []), registry: registry, proxyJump: SSHProxyJumpShape.none,
            expectedCause: "this ssh holds no connection of its own "
                + "(a ControlMaster client or a ProxyCommand)"
        )
    }

    func testTheDIRECTPathNeverConsultsTheSSHConfigAtAll() async throws {
        // `ssh -G` is a process spawn. It runs only on the branch that is
        // already abstaining, so an ordinary join must not pay for it — and
        // must not be able to be changed by it.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let consulted = Mutex(0)
        let sshResult = surfaceConnection()
        let hostList = [enrolledHost()]
        let joinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { [surfaceTTY] _ in surfaceTTY },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in false },
            sshDestinationProbe: { _ in sshResult },
            enrolledHosts: { destination in
                hostList.filter { $0.sshHostAlias?.lowercased() == destination.lowercased() }
            },
            proxyJumpShape: { _ in
                consulted.withLock { $0 += 1 }
                return .singleHop
            },
            speculativeHosts: { hostList }
        )
        let resolved = await joinResolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .remoteSSHConnection)
        XCTAssertEqual(consulted.withLock { $0 }, 0, "the direct path must spawn no ssh -G")
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
        // A local shell is the overwhelmingly common surface; the arm must not
        // fill the diagnostic record with a cause every time one is focused.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(registry: registry, sshResult: .noSSHClient)
                .resolve(target: self.ghostty)
        }
        XCTAssertNil(join)
        XCTAssertFalse(
            causes.contains { $0.hasPrefix("remote-ssh:") },
            "a local shell is the arm not applying, not an abstention: \(causes)"
        )
    }

    func testAnSSHToAHostThatIsNotEnrolledIsNotAnAbstention() async {
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let (join, causes) = await ClaudeJoinAbstentionTap.collecting {
            await self.resolver(
                registry: registry, sshResult: self.surfaceConnection(destination: "stranger")
            ).resolve(target: self.ghostty)
        }
        XCTAssertNil(join)
        XCTAssertFalse(causes.contains { $0.hasPrefix("remote-ssh:") }, "\(causes)")
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

    // MARK: - The regression #250 left behind

    func testAPlainSSHSessionReportingNOConnectionDoesNotJoin() async {
        // The state of main before this arm: the session is live, on the right
        // enrolled host, in the surface's own ssh — and publishes no
        // `$SSH_CONNECTION`, because its remote plugin predates it. There is no
        // marker arm underneath any more, so the answer is nil.
        //
        // This is also the fail-closed proof for the new field: everything the
        // join needs EXCEPT the connection report is present.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", hookParentPID: "4711"
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host reports its ssh connection"
        )
    }

    func testAMalformedConnectionReportIsRefusedRatherThanPartiallyMatched() async {
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3",
                // Three fields: the shim drops these, so only a hand-crafted or
                // hostile report gets here — and it must not match on a prefix.
                sshConnection: "10.0.0.2,\(clientPort),\(serverAddress)"
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host reports its ssh connection"
        )
    }

    func testAControlMasterMuxSiblingAbstainsEvenWhenThePortsAgree() async {
        // Terminal A holds the master and its TCP socket; terminal B's
        // `ssh sandbox` is a mux client with no socket of its own. sshd derives
        // `$SSH_CONNECTION` from the CONNECTION, so B's Claude session
        // truthfully reports A's ports — and joining would attach B's session
        // to a dictation into A, where no agent is running. Fixtured so the
        // ports DO agree: without the guard this is a mis-join. Found by
        // review, 2026-09-05.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(siblings: SSHSiblingSurvey(considered: 1, socketless: 1)),
            registry: registry,
            expectedCause: "another ssh session to this destination holds no connection "
                + "of its own (1 of 1)"
        )
    }

    func testAnUnreadableSiblingAbstainsUnderItsOWNCause() async {
        // Same abstention, different story, and the field needs to be able to
        // tell them apart: a real ControlMaster client is the user's ssh
        // config, an unreadable process is a bug or a missing permission.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        await assertNoJoin(
            surfaceConnection(siblings: SSHSiblingSurvey(considered: 6, unreadable: 2)),
            registry: registry,
            expectedCause: "another ssh session to this destination is unreadable (2 of 6)"
        )
    }

    func testSiblingsThatAllHoldTheirOwnConnectionDoNotAbstain() async throws {
        // The ordinary shape — several terminals, several connections — must
        // keep joining. This is what the counted survey is FOR: `considered`
        // can be large as long as nothing is socketless or unreadable.
        let registry = makeRegistry()
        ingestRemoteSession(into: registry)
        let resolved = await resolver(
            registry: registry,
            sshResult: surfaceConnection(siblings: SSHSiblingSurvey(considered: 4))
        ).resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .remoteSSHConnection)
    }

    func testASessionInsideScreenDoesNotJoinThroughThisArm() async {
        // screen is a multiplexer SERVER with tmux's inheritance property and
        // publishes `$STY` (screen(1), ENVIRONMENT). Until the review it was
        // not on the wire at all, so this exact fixture JOINED.
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                screenSession: "3721.pts-0.sandbox",
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection()
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testASessionInsideZellijDoesNotJoinThroughThisArm() async {
        let registry = makeRegistry()
        ingestRemoteSession(
            into: registry,
            environment: ClaudeRemoteSessionEnvironment(
                zellijSession: "0",
                sshTTY: "/dev/pts/3",
                sshConnection: reportedConnection()
            )
        )
        await assertNoJoin(
            surfaceConnection(), registry: registry,
            expectedCause: "no live session on this host is a plain ssh shell"
        )
    }

    func testEveryMultiplexerLabelOnTheWireRefusesTheJoinOnItsOwn() async {
        // The exclusion is a LIST over the wire allowlist, so this walks it
        // instead of restating it: a label added to `multiplexerLabels` that
        // the arm does not actually honour fails here, and a multiplexer field
        // added to the wire and forgotten in the list fails the companion
        // assertion below.
        for label in ClaudeSessionJoinResolver.multiplexerLabels {
            let registry = makeRegistry()
            var environment = ClaudeRemoteSessionEnvironment(
                sshTTY: "/dev/pts/3", sshConnection: reportedConnection()
            )
            environment[label] = "x"
            ingestRemoteSession(into: registry, environment: environment)
            let (join, _) = await ClaudeJoinAbstentionTap.collecting {
                await self.resolver(registry: registry, sshResult: self.surfaceConnection())
                    .resolve(target: self.ghostty)
            }
            XCTAssertNil(join, "\(label) must refuse the join on its own")
        }
    }

    func testTheMultiplexerLabelListCoversEveryMultiplexerFieldOnTheWire() {
        // A wire field naming a multiplexer that is NOT in the list is a
        // silent mis-join waiting to happen — that is exactly how screen got
        // missed. Anything matching these names must be in the list or
        // deliberately excluded here with a reason.
        let deliberatelyOutside: Set<ClaudeRemoteEnvironmentField> = [
            // A Remote Control session has no multiplexer between it and its
            // connection, and its own arm runs on a browser target.
            .bridgeSessionID,
        ]
        let multiplexerNamed = ClaudeRemoteEnvironmentField.allCases.filter { field in
            let name = field.rawValue.lowercased()
            return ["herdr", "cmux", "tmux", "screen", "zellij", "bridge"]
                .contains { name.contains($0) }
        }
        for field in multiplexerNamed where !deliberatelyOutside.contains(field) {
            XCTAssertTrue(
                ClaudeSessionJoinResolver.multiplexerLabels.contains(field),
                "\(field) names a multiplexer and must refuse a plain-ssh join"
            )
        }
    }

}

/// The value grammar and the address comparison, away from the resolver.
final class SSHConnectionReportTests: XCTestCase {
    func testTheShapeSSHDActuallyEmitsParses() throws {
        let report = try XCTUnwrap(
            ClaudeRemoteSSHConnectionReport.parse("10.0.0.2,51960,10.0.0.9,22")
        )
        XCTAssertEqual(report.clientAddress, "10.0.0.2")
        XCTAssertEqual(report.clientPort, 51_960)
        XCTAssertEqual(report.serverAddress, "10.0.0.9")
        XCTAssertEqual(report.serverPort, 22)
    }

    func testAnIPv6ConnectionParses() throws {
        let report = try XCTUnwrap(ClaudeRemoteSSHConnectionReport.parse("::1,51960,::1,2222"))
        XCTAssertEqual(report.clientAddress, "::1")
        XCTAssertEqual(report.serverPort, 2_222)
    }

    func testEveryMalformedShapeIsRefused() {
        let refused = [
            "",
            "10.0.0.2,51960,10.0.0.9",                    // three fields
            "10.0.0.2,51960,10.0.0.9,22,extra",           // five fields
            "10.0.0.2,,10.0.0.9,22",                      // empty field
            "10.0.0.2 51960 10.0.0.9 22",                 // never re-joined
            "10.0.0.2,051960,10.0.0.9,22",                // leading zero
            "10.0.0.2,0,10.0.0.9,22",                     // port 0
            "10.0.0.2,65536,10.0.0.9,22",                 // out of range
            "10.0.0.2,999999,10.0.0.9,22",                // too many digits
            "10.0.0.2,+960,10.0.0.9,22",                  // signed
            "10.0.0.2,51960,evil.example.com,22",         // a name, not an address
            "10.0.0.2,51960,10.0.0.9/../x,22",            // path-shaped
            "10.0.0.2,51960,fe80::1%eth0,22",             // zone id: unmatchable
            String(repeating: "a", count: 46) + ",1,::1,22",  // over the length bound
        ]
        for value in refused {
            XCTAssertNil(
                ClaudeRemoteSSHConnectionReport.parse(value), "must be refused: \(value)"
            )
        }
    }

    #if canImport(Darwin)
    func testAddressComparisonIsBytesNotText() {
        // Literal expectations, not a round trip through the parser under test.
        XCTAssertEqual(SSHConnectionAddressMatch.addressBytes("127.0.0.1"), [127, 0, 0, 1])
        XCTAssertEqual(
            SSHConnectionAddressMatch.addressBytes("::ffff:127.0.0.1"), [127, 0, 0, 1],
            "an IPv4-mapped address is the IPv4 address it wraps"
        )
        XCTAssertEqual(
            SSHConnectionAddressMatch.addressBytes("::1"),
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        )

        XCTAssertTrue(SSHConnectionAddressMatch.sameAddress("::1", "0:0:0:0:0:0:0:1"))
        XCTAssertTrue(SSHConnectionAddressMatch.sameAddress("::ffff:10.0.0.9", "10.0.0.9"))
        XCTAssertFalse(SSHConnectionAddressMatch.sameAddress("10.0.0.9", "10.0.0.10"))
        XCTAssertFalse(SSHConnectionAddressMatch.sameAddress("::1", "127.0.0.1"))
        // Nothing that fails to parse may compare equal to anything, including
        // an identical unparseable string.
        XCTAssertFalse(SSHConnectionAddressMatch.sameAddress("not-an-address", "not-an-address"))
        XCTAssertNil(SSHConnectionAddressMatch.addressBytes(""))
    }
    #endif
}
#endif
