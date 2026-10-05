import ClaudeContextWire
import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

/// The remote mod channel's leases (#1412): attach admission, delivery by
/// long poll, acks, the hold, expiry and replies, all on a manual clock.
final class ClaudeRemoteModChannelsTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 5_000_000)
    private let instance = String(repeating: "1", count: 32)
    private let nonce = String(repeating: "2", count: 32)

    private struct Fixture {
        let clock = ManualSessionClock()
        let hubClock = ManualSessionClock()
        let registry: ClaudeSessionRegistry
        let hub: ClaudeModChannelHub
        let channels: ClaudeRemoteModChannels

        let now = LockedBox(ClaudeRemoteModChannelsTests.epoch)

        init() {
            registry = ClaudeSessionRegistry(now: { [now] in now.value }, isProcessAlive: { _ in true })
            hub = ClaudeModChannelHub(sleep: { [hubClock] in await hubClock.sleep($0) })
            channels = ClaudeRemoteModChannels(
                hub: hub, registry: registry, hold: .seconds(25), grace: .seconds(10),
                maxQueuedLines: 3, sleep: { [clock] in await clock.sleep($0) }, now: { [clock] in clock.now }
            )
        }

        /// A hook of `hostID` names `sessionID`, as the listener ingests it.
        func announce(_ sessionID: String, on hostID: String) {
            let record = ClaudeHookRecord(
                event: .sessionStart,
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: sessionID),
                timestamp: 1, rawCwd: "/srv/repo"
            )
            _ = registry.ingest(record, origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID)))
        }
    }

    /// A poll carrying a challenge the channels just issued for it, as a mod
    /// that verified the last answer sends.
    private func poll(
        _ fixture: Fixture, host: String = "h1", session: String = "sess-1", instance: String? = nil,
        attach: UInt64 = 0, acked: Int = 0
    ) -> Task<ClaudeRemoteModChannels.PollOutcome, Never> {
        let instance = instance ?? self.instance
        let request = ClaudeRemoteModWire.PollRequest(
            sessionID: session, instance: instance, nonce: nonce,
            challenge: fixture.channels.issueChallenge(hostID: host, sessionID: session, instance: instance),
            attach: attach, acked: acked
        )
        return Task { await fixture.channels.poll(hostID: host, request: request) }
    }

    private func line(_ kind: ClaudeModChannelWire.Kind, id: String) throws -> Data {
        try XCTUnwrap(ClaudeModChannelWire.encodeLine(ClaudeModChannelWire.Message(kind: kind, id: id)))
    }

    func testASessionNoHookOfThatHostNamedCannotAttach() async {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")

        let fromOtherHost = await poll(fixture, host: "h2").value
        let unnamed = await poll(fixture, session: "sess-9").value

        XCTAssertEqual(fromOtherHost, .busy)
        XCTAssertEqual(unnamed, .busy)
        XCTAssertFalse(fixture.hub.hasAttachedChannels)
    }

    func testALineReachesAHeldPollAtOnceAndGoesAgainUntilAcked() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")

        let held = poll(fixture)
        await fixture.clock.waitForSleepers(1)
        XCTAssertTrue(fixture.hub.isAttached(scoped))
        XCTAssertTrue(fixture.hub.post(.init(kind: .state, phase: .listening), to: scoped))

        guard case .lines(let attach, let first, let lines) = await held.value else { return XCTFail("no lines") }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(lines.count, 1)

        // The answer was lost: the next poll acks nothing and gets it again.
        let again = await poll(fixture).value
        XCTAssertEqual(again, .lines(attach: attach, first: 1, lines))

        // Armed so far: the first poll's hold and each answer's expiry; this
        // poll's hold is the fourth.
        let acked = poll(fixture, attach: attach, acked: 1)
        await fixture.clock.waitForSleepers(4)
        fixture.clock.advance(by: 25)
        let empty = await acked.value
        XCTAssertEqual(empty, .lines(attach: attach, first: 2, []))
    }

    func testAReplyRoundTripsUnderTheScopedIdAndAnotherHostCannotAnswerIt() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        let held = poll(fixture)
        await fixture.clock.waitForSleepers(1)

        let exchange = Task { await fixture.hub.exchange(.init(kind: .ping), with: scoped, timeout: .seconds(5)) }
        guard case .lines(_, _, let lines) = await held.value, let sent = lines.first else { return XCTFail("no ping") }
        let message = try XCTUnwrap(ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: sent.dropLast()))

        fixture.channels.deliver(hostID: "h2", reply: .init(sessionID: "sess-1", id: message.id, ok: false))
        fixture.channels.deliver(hostID: "h1", reply: .init(sessionID: "sess-1", id: message.id, ok: true))

        let exchanged = await exchange.value
        XCTAssertEqual(exchanged, .replied(.init(sessionID: scoped, id: message.id, ok: true)))
    }

    func testAnotherProcessOfTheSessionWaitsUntilTheLeaseExpires() async {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        let first = poll(fixture)
        await fixture.clock.waitForSleepers(1)

        let other = await poll(fixture, instance: String(repeating: "3", count: 32)).value
        XCTAssertEqual(other, .busy)

        // The first poll's hold ends; with no poll for the grace, it detaches.
        let detached = expectation(description: "the channel detached")
        fixture.hub.debugConfigureAttachHook { attached in if !attached { detached.fulfill() } }
        fixture.clock.advance(by: 25)
        _ = await first.value
        await fixture.clock.waitForSleepers(1)
        fixture.clock.advance(by: 10)
        await fulfillment(of: [detached], timeout: 10)
        XCTAssertFalse(fixture.hub.isAttached(scoped))
        XCTAssertFalse(fixture.channels.hasLease(scoped))
    }

    /// A remote pid means nothing on this Mac, so polls are the session's
    /// liveness (#1412): a poll within the TTL keeps it past the TTL from its
    /// last hook, and without one it expires as before.
    func testPollsKeepARemoteSessionPastItsTTL() async throws {
        let ttl = ClaudeRegistryLimits.default.sessionTTL
        for polledLate in [true, false] {
            let fixture = Fixture()
            fixture.announce("sess-1", on: "h1")
            let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
            let first = poll(fixture)
            await fixture.clock.waitForSleepers(1)
            XCTAssertTrue(fixture.hub.post(.init(kind: .state), to: scoped))
            _ = await first.value

            if polledLate {
                fixture.now.set(Self.epoch.addingTimeInterval(ttl - 60))
                _ = poll(fixture, acked: 1)
                await fixture.clock.waitForSleepers(3)
            }
            fixture.now.set(Self.epoch.addingTimeInterval(ttl + 600))

            XCTAssertEqual(fixture.registry.snapshot(sessionID: scoped) != nil, polledLate, "polled late: \(polledLate)")
        }
    }

    func testAFullQueueRefusesTheLine() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        let held = poll(fixture)
        await fixture.clock.waitForSleepers(1)
        XCTAssertTrue(fixture.hub.isAttached(scoped))

        // A line counts until a poll acks it, delivered or not.
        for _ in 0..<3 { XCTAssertTrue(fixture.hub.post(.init(kind: .state), to: scoped)) }
        XCTAssertFalse(fixture.hub.post(.init(kind: .state), to: scoped))
        _ = await held.value
    }

    func testTheModsByeEndsTheSessionAndTheLastPollCarriesTheAppsBye() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        let held = poll(fixture)
        await fixture.clock.waitForSleepers(1)

        fixture.channels.bye(hostID: "h1", sessionID: "sess-1")

        guard case .lines(_, _, let lines) = await held.value, let last = lines.last else { return XCTFail("no bye") }
        let message = try XCTUnwrap(ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: last.dropLast()))
        XCTAssertEqual(message.kind, .bye)
        XCTAssertFalse(fixture.hub.isAttached(scoped))
        XCTAssertNil(fixture.registry.snapshot(sessionID: scoped))
    }

    /// A squatter on the forward port keeps the polls it captured; replayed
    /// once the forward is back, they must get neither a lease nor a line.
    func testOnlyAPollWithALiveChallengeGetsTheChannelAndEachChallengeServesOnce() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        func request(_ challenge: String, instance: String? = nil) -> ClaudeRemoteModWire.PollRequest {
            .init(sessionID: "sess-1", instance: instance ?? self.instance, nonce: nonce, challenge: challenge, acked: 0)
        }

        let bare = await fixture.channels.poll(hostID: "h1", request: request(""))
        let made = await fixture.channels.poll(hostID: "h1", request: request(String(repeating: "9", count: 32)))
        XCTAssertEqual(bare, .unchallenged)
        XCTAssertEqual(made, .unchallenged)
        XCTAssertFalse(fixture.hub.isAttached(scoped))

        // Issued for another host or another process of the session: no.
        let elsewhere = fixture.channels.issueChallenge(hostID: "h2", sessionID: "sess-1", instance: instance)
        let otherInstance = fixture.channels.issueChallenge(
            hostID: "h1", sessionID: "sess-1", instance: String(repeating: "3", count: 32)
        )
        let fromElsewhere = await fixture.channels.poll(hostID: "h1", request: request(elsewhere))
        let fromOtherInstance = await fixture.channels.poll(hostID: "h1", request: request(otherInstance))
        XCTAssertEqual(fromElsewhere, .unchallenged)
        XCTAssertEqual(fromOtherInstance, .unchallenged)

        // Past the grace, a challenge is dead.
        let stale = fixture.channels.issueChallenge(hostID: "h1", sessionID: "sess-1", instance: instance)
        fixture.clock.advance(by: 11)
        let late = await fixture.channels.poll(hostID: "h1", request: request(stale))
        XCTAssertEqual(late, .unchallenged)
        XCTAssertFalse(fixture.hub.isAttached(scoped))

        let challenge = fixture.channels.issueChallenge(hostID: "h1", sessionID: "sess-1", instance: instance)
        let live = request(challenge)
        let held = Task { await fixture.channels.poll(hostID: "h1", request: live) }
        await fixture.clock.waitForSleepers(1)
        XCTAssertTrue(fixture.hub.isAttached(scoped))
        XCTAssertTrue(fixture.hub.post(.init(kind: .state, phase: .listening), to: scoped))
        guard case .lines(_, _, let lines) = await held.value else { return XCTFail("no lines") }
        XCTAssertEqual(lines.count, 1)

        // The same poll again, its line still unacked: nothing.
        let replayed = await fixture.channels.poll(hostID: "h1", request: live)
        XCTAssertEqual(replayed, .unchallenged)
    }

    /// The mod lost the answer that told it of a new attach and still acks
    /// lines of the old one: the new attach's lines, numbered from 1 again,
    /// must stay.
    func testAnAckFromAnEarlierAttachDropsNoLineOfANewOne() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")

        let first = poll(fixture)
        await fixture.clock.waitForSleepers(1)
        XCTAssertTrue(fixture.hub.post(.init(kind: .state, phase: .listening), to: scoped))
        guard case .lines(let oldAttach, 1, let oldLines) = await first.value else { return XCTFail("no lines") }
        XCTAssertEqual(oldLines.count, 1)

        // The forward dropped: no poll in the grace, so the lease goes. Armed:
        // the first poll's hold and its answer's expiry.
        await fixture.clock.waitForSleepers(2)
        let detached = expectation(description: "the channel detached")
        fixture.hub.debugConfigureAttachHook { attached in if !attached { detached.fulfill() } }
        fixture.clock.advance(by: 10)
        await fulfillment(of: [detached], timeout: 10)
        fixture.hub.debugConfigureAttachHook { _ in }

        // A new attach: the answer that carried its first line is lost, and
        // a second line queues behind it.
        let second = poll(fixture, attach: oldAttach, acked: 1)
        // The first poll's hold, still armed, and this one's.
        await fixture.clock.waitForSleepers(2)
        XCTAssertTrue(fixture.hub.post(.init(kind: .state, phase: .done), to: scoped))
        guard case .lines(let newAttach, 1, let lost) = await second.value else { return XCTFail("no lines") }
        XCTAssertNotEqual(newAttach, oldAttach)
        XCTAssertTrue(fixture.hub.post(.init(kind: .append, id: "a1"), to: scoped))

        let again = await poll(fixture, attach: oldAttach, acked: 1).value
        guard case .lines(newAttach, 1, let lines) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(Array(lines.prefix(1)), lost)
        XCTAssertEqual(lines.count, 2)
    }

    /// The forward dropped a poll after the waiting band was acked, and the
    /// mod cleared its band; a hook ended its backoff inside the grace, so
    /// it polls again on the same lease (#1799). Its unchallenged poll must
    /// bring the band's state back.
    func testAModThatStartsOverOnTheSameLeaseGetsTheWaitingBandAgain() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        let band = await MainActor.run { AgentWaitingBand(hub: fixture.hub) }
        let told = LockedBox(0)
        let toldAgain = expectation(description: "the band told the mod again")
        fixture.hub.observeAttach { sessionID in
            told.set(told.value + 1)
            let count = told.value
            Task { @MainActor in
                band.attached(sessionID: sessionID)
                if count == 2 { toldAgain.fulfill() }
            }
        }
        await MainActor.run {
            var queue = AgentAttentionQueue()
            queue.wait(sessionID: "other", name: "payments", agent: .claude, at: Self.epoch)
            band.update(queue)
        }
        func waiting(_ line: Data?) throws -> [String]? {
            let line = try XCTUnwrap(line)
            return try XCTUnwrap(ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: line.dropLast()))
                .waiting
        }

        guard case .lines(let attach, 1, let first) = await poll(fixture).value else { return XCTFail("no band") }
        XCTAssertEqual(try waiting(first.first), ["payments"])

        // The poll that acks it is lost on the way; the mod clears its band
        // and its next poll carries no challenge.
        let lost = poll(fixture, attach: attach, acked: 1)
        // Armed: the first poll's hold and its answer's expiry, and this
        // poll's hold.
        await fixture.clock.waitForSleepers(3)
        let unchallenged = ClaudeRemoteModWire.PollRequest(
            sessionID: "sess-1", instance: instance, nonce: nonce, challenge: "", attach: attach, acked: 1
        )
        let answered = await fixture.channels.poll(hostID: "h1", request: unchallenged)
        XCTAssertEqual(answered, .unchallenged)
        await fulfillment(of: [toldAgain], timeout: 10)
        guard told.value == 2 else { return lost.cancel() }
        // A replay of that unchallenged poll queues nothing more.
        _ = await fixture.channels.poll(hostID: "h1", request: unchallenged)
        XCTAssertEqual(told.value, 2)

        guard case .lines(attach, 2, let again) = await poll(fixture, attach: attach, acked: 1).value else {
            return XCTFail("no band after the mod started over")
        }
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(try waiting(again.first), ["payments"])
    }

    func testClosingARevokedHostsChannelsAnswersItsHeldPollWithNothing() async throws {
        let fixture = Fixture()
        fixture.announce("sess-1", on: "h1")
        fixture.announce("sess-2", on: "h2")
        let revoked = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h1", sessionID: "sess-1")
        let kept = ClaudeRemoteSessionScope.scopedSessionID(hostID: "h2", sessionID: "sess-2")
        let held = poll(fixture)
        let other = poll(fixture, host: "h2", session: "sess-2")
        await fixture.clock.waitForSleepers(2)

        fixture.channels.closeChannels(ofHostsNotIn: ["h2"])
        // Past the hold: a poll still held answers now, whatever it holds.
        fixture.clock.advance(by: 25)

        let outcome = await held.value
        XCTAssertEqual(outcome, .revoked)
        XCTAssertFalse(fixture.hub.isAttached(revoked))
        XCTAssertFalse(fixture.hub.post(.init(kind: .state, waiting: ["payments"]), to: revoked))
        XCTAssertFalse(fixture.channels.hasLease(revoked))
        XCTAssertTrue(fixture.hub.isAttached(kept))
        XCTAssertTrue(fixture.hub.post(.init(kind: .state, phase: .listening), to: kept))
        _ = await other.value
    }
}

/// The wire and its proofs. The vectors are the ones the remote plugin's
/// TypeScript must produce (integrations/claude-code/plugins/localvoxtral-remote/tests).
final class ClaudeRemoteModWireTests: XCTestCase {
    private let key = String(repeating: "a", count: 64)

    func testProofsMatchTheModsVectors() {
        let body = Data(#"{"x":1}"#.utf8)
        XCTAssertEqual(
            ClaudeRemoteModWire.requestProof(key: key, body: body),
            "c32d4043464e45b4bfea427d675b52d1f1a9128f8b1d1a3743e915343d4de5e4"
        )
        XCTAssertEqual(
            ClaudeRemoteModWire.answerProof(key: key, nonce: String(repeating: "0", count: 32), body: body),
            "7dbc754e5a775a96107f4e869de08792b7e943498144df60a7ecc9aa1a10e6e8"
        )
        XCTAssertEqual(
            ClaudeRemoteModWire.channelKey(tokenHash: "hash"),
            "2a7b014256677c1b0ec8ebd0fd02d09bf5fdc8535745e6ff9886d35f01ee31dd"
        )
    }

    func testAPollWithAMalformedIdDoesNotDecode() {
        func poll(
            _ session: String, instance: String = String(repeating: "1", count: 32), challenge: String = "", acked: Int = 0
        ) -> Data {
            Data(#"{"mod_poll":1,"session_id":"\#(session)","instance":"\#(instance)","nonce":"\#(String(repeating: "2", count: 32))","challenge":"\#(challenge)","attach":7,"acked":\#(acked)}"#.utf8)
        }
        XCTAssertNotNil(ClaudeRemoteModWire.decodePoll(poll("0b2c-uuid")))
        XCTAssertNotNil(ClaudeRemoteModWire.decodePoll(poll("ok", challenge: String(repeating: "a", count: 32))))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", challenge: "short")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("../x")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("a:b")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", instance: "short")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", acked: -1)))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", acked: Int.max)))
    }

    func testTheAnswerCarriesEachLineAsAStringWithoutItsNewline() throws {
        let body = ClaudeRemoteModWire.answerBody(
            attach: 7, first: 3, lines: [Data("{\"a\":1}\n".utf8)], next: String(repeating: "c", count: 32)
        )
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["next"] as? String, String(repeating: "c", count: 32))
        XCTAssertEqual(decoded["attach"] as? Int, 7)
        XCTAssertEqual(decoded["first"] as? Int, 3)
        XCTAssertEqual(decoded["lines"] as? [String], ["{\"a\":1}"])
    }
}

#if canImport(Darwin) || canImport(Glibc)

/// The routes on the real listener, over a socket, as the remote plugin's
/// mod reaches them through the forward.
final class ClaudeRemoteModRouteTests: XCTestCase {
    private var listener: ClaudeRemoteContextListener!

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    /// One enrolled host whose hook named `sess-1`, and a listener with one
    /// slot for one-shot requests: a held poll must give it back.
    private struct Route {
        let clock = ManualSessionClock()
        let hosts: ClaudeRemoteHostRegistry
        let enrollment: ClaudeRemoteEnrollment
        let key: String
        let hub = ClaudeModChannelHub()
        let port: UInt16
        let scoped: String

        var hostID: String { enrollment.host.id }

        func poll(challenge: String = "", attach: UInt64 = 0, acked: Int = 0) -> (body: Data, nonce: String) {
            let nonce = ClaudeRemoteModWire.randomChallenge()
            let body = Data(
                #"{"mod_poll":1,"session_id":"sess-1","instance":"\#(String(repeating: "5", count: 32))","nonce":"\#(nonce)","challenge":"\#(challenge)","attach":\#(attach),"acked":\#(acked)}"#.utf8
            )
            return (body, nonce)
        }

        func post(_ body: Data, path: String = ClaudeRemoteModWire.pollPath, proof: String? = nil) throws
            -> RemoteListenerResponse {
            try postToRemoteListener(
                port: port, path: path,
                headers: [
                    "Authorization": "Bearer \(enrollment.token)",
                    ClaudeRemoteModWire.proofHeaderName: proof ?? ClaudeRemoteModWire.requestProof(key: key, body: body),
                ],
                body: body
            )
        }
    }

    private func start() throws -> Route {
        let sessions = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-mod-route-\(UUID().uuidString)/hosts.json"),
            io: MemoryRemoteHostStoreIO()
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: enrollment.host.id, sessionID: "sess-1")
        _ = sessions.ingest(
            ClaudeHookRecord(event: .sessionStart, sessionID: scoped, timestamp: 1, rawCwd: "/srv/repo"),
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: enrollment.host.id))
        )
        let route = Route(
            hosts: hosts, enrollment: enrollment,
            key: try XCTUnwrap(hosts.modChannelKey(hostID: enrollment.host.id)),
            port: try unusedLoopbackPort(), scoped: scoped
        )
        listener = ClaudeRemoteContextListener(
            registry: sessions, hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: route.port, maxConcurrentConnections: 1),
            modChannels: ClaudeRemoteModChannels(
                hub: route.hub, registry: sessions,
                sleep: { [clock = route.clock] in await clock.sleep($0) }, now: { [clock = route.clock] in clock.now }
            )
        )
        try listener.start()
        return route
    }

    private func answer(_ response: RemoteListenerResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testOnlyAProvenPollAttachesAndItsAnswerCarriesTheProof() async throws {
        let route = try start()

        let unproven = try route.post(route.poll().body, proof: String(repeating: "0", count: 64))
        XCTAssertEqual(unproven.status, 403)
        XCTAssertFalse(route.hub.isAttached(route.scoped))

        // The first poll gets a challenge and nothing else.
        let (bare, bareNonce) = route.poll()
        let challenged = try route.post(bare)
        XCTAssertEqual(challenged.status, 200)
        XCTAssertEqual(
            challenged.headers[ClaudeRemoteModWire.proofHeaderName.lowercased()],
            ClaudeRemoteModWire.answerProof(key: route.key, nonce: bareNonce, body: challenged.body)
        )
        XCTAssertEqual(try answer(challenged)["lines"] as? [String], [])
        let challenge = try XCTUnwrap(try answer(challenged)["next"] as? String)
        XCTAssertFalse(route.hub.isAttached(route.scoped))

        let (body, nonce) = route.poll(challenge: challenge)
        let held = Task.detached { try route.post(body) }
        await route.clock.waitForSleepers(1)
        XCTAssertTrue(route.hub.isAttached(route.scoped))

        // While the poll holds, a one-shot request still finds its slot.
        let meanwhile = try route.post(
            Data("{}".utf8), path: ClaudeRemoteModWire.replyPath, proof: String(repeating: "0", count: 64)
        )
        XCTAssertEqual(meanwhile.status, 403)

        XCTAssertTrue(route.hub.post(.init(kind: .state, phase: .listening), to: route.scoped))
        let lines = try await held.value
        XCTAssertEqual(lines.status, 200)
        XCTAssertEqual(
            lines.headers[ClaudeRemoteModWire.proofHeaderName.lowercased()],
            ClaudeRemoteModWire.answerProof(key: route.key, nonce: nonce, body: lines.body)
        )
        XCTAssertEqual((try answer(lines)["lines"] as? [String])?.count, 1)

        // A rotated token is a new key: the old proof no longer opens it.
        _ = try route.hosts.rotateToken(hostID: route.hostID)
        let afterRotation = try route.post(body)
        XCTAssertEqual(afterRotation.status, 401)
    }

    /// Codex review, 2026-10-04: a squatter on the forward port replays a
    /// poll it captured once the forward is back. It gets the line nobody
    /// acked yet only if the listener serves the same poll twice.
    func testAReplayedPollGetsNoLine() async throws {
        let route = try start()
        let challenge = try XCTUnwrap(try answer(route.post(route.poll().body))["next"] as? String)
        let (body, _) = route.poll(challenge: challenge)
        let held = Task.detached { try route.post(body) }
        await route.clock.waitForSleepers(1)
        XCTAssertTrue(route.hub.post(.init(kind: .fill, id: "f", text: "the dictation"), to: route.scoped))
        let delivered = try await held.value
        XCTAssertEqual((try answer(delivered)["lines"] as? [String])?.count, 1)

        let replayed = try route.post(body)

        XCTAssertEqual(replayed.status, 200)
        XCTAssertEqual(try answer(replayed)["lines"] as? [String], [])
    }

    /// Codex review, 2026-10-04: a host revoked while its poll holds gets
    /// nothing the app writes afterwards.
    func testAHostRevokedWhileItsPollHoldsGetsNoAnswer() async throws {
        let route = try start()
        let challenge = try XCTUnwrap(try answer(route.post(route.poll().body))["next"] as? String)
        let held = Task.detached { try route.post(route.poll(challenge: challenge).body) }
        await route.clock.waitForSleepers(1)

        try route.hosts.revoke(hostID: route.hostID)
        XCTAssertTrue(route.hub.post(.init(kind: .state, waiting: ["payments"]), to: route.scoped))

        let response = try await held.value
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(response.body.isEmpty)
    }
}

#endif
