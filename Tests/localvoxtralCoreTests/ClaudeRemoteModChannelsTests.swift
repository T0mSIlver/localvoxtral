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

        init() {
            registry = ClaudeSessionRegistry(now: { ClaudeRemoteModChannelsTests.epoch }, isProcessAlive: { _ in true })
            hub = ClaudeModChannelHub(sleep: { [hubClock] in await hubClock.sleep($0) })
            channels = ClaudeRemoteModChannels(
                hub: hub, registry: registry, hold: .seconds(25), grace: .seconds(10),
                maxQueuedLines: 3, sleep: { [clock] in await clock.sleep($0) }
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

    private func poll(
        _ fixture: Fixture, host: String = "h1", session: String = "sess-1", instance: String? = nil, acked: Int = 0
    ) -> Task<ClaudeRemoteModChannels.PollOutcome, Never> {
        let request = ClaudeRemoteModWire.PollRequest(
            sessionID: session, instance: instance ?? self.instance, nonce: nonce, acked: acked
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
        let acked = poll(fixture, acked: 1)
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
        func poll(_ session: String, instance: String = String(repeating: "1", count: 32), acked: Int = 0) -> Data {
            Data(#"{"mod_poll":1,"session_id":"\#(session)","instance":"\#(instance)","nonce":"\#(String(repeating: "2", count: 32))","acked":\#(acked)}"#.utf8)
        }
        XCTAssertNotNil(ClaudeRemoteModWire.decodePoll(poll("0b2c-uuid")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("../x")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("a:b")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", instance: "short")))
        XCTAssertNil(ClaudeRemoteModWire.decodePoll(poll("ok", acked: -1)))
    }

    func testTheAnswerCarriesEachLineAsAStringWithoutItsNewline() throws {
        let body = ClaudeRemoteModWire.answerBody(attach: 7, first: 3, lines: [Data("{\"a\":1}\n".utf8)])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
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

    func testOnlyAProvenPollAttachesAndItsAnswerCarriesTheProof() async throws {
        let clock = ManualSessionClock()
        let sessions = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-mod-route-\(UUID().uuidString)/hosts.json"),
            io: MemoryRemoteHostStoreIO()
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        let hostID = enrollment.host.id
        let key = try XCTUnwrap(hosts.modChannelKey(hostID: hostID))
        let hub = ClaudeModChannelHub()
        let port = try unusedLoopbackPort()
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "sess-1")
        _ = sessions.ingest(
            ClaudeHookRecord(event: .sessionStart, sessionID: scoped, timestamp: 1, rawCwd: "/srv/repo"),
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
        )
        // One slot for one-shot requests: a held poll must give it back.
        listener = ClaudeRemoteContextListener(
            registry: sessions, hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port, maxConcurrentConnections: 1),
            modChannels: ClaudeRemoteModChannels(hub: hub, registry: sessions, sleep: { await clock.sleep($0) })
        )
        try listener.start()

        let nonce = String(repeating: "4", count: 32)
        let body = Data(
            #"{"mod_poll":1,"session_id":"sess-1","instance":"\#(String(repeating: "5", count: 32))","nonce":"\#(nonce)","acked":0}"#.utf8
        )
        func headers(proof: String) -> [String: String] {
            ["Authorization": "Bearer \(enrollment.token)", ClaudeRemoteModWire.proofHeaderName: proof]
        }

        let unproven = try postToRemoteListener(
            port: port, path: ClaudeRemoteModWire.pollPath,
            headers: headers(proof: String(repeating: "0", count: 64)), body: body
        )
        XCTAssertEqual(unproven.status, 403)
        XCTAssertFalse(hub.isAttached(scoped))

        let proof = ClaudeRemoteModWire.requestProof(key: key, body: body)
        let held = Task.detached {
            try postToRemoteListener(
                port: port, path: ClaudeRemoteModWire.pollPath, headers: headers(proof: proof), body: body
            )
        }
        await clock.waitForSleepers(1)
        XCTAssertTrue(hub.isAttached(scoped))

        // While the poll holds, a one-shot request still finds its slot.
        let meanwhile = try postToRemoteListener(
            port: port, path: ClaudeRemoteModWire.replyPath,
            headers: headers(proof: String(repeating: "0", count: 64)), body: Data("{}".utf8)
        )
        XCTAssertEqual(meanwhile.status, 403)

        XCTAssertTrue(hub.post(.init(kind: .state, phase: .listening), to: scoped))
        let answer = try await held.value
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(
            answer.headers[ClaudeRemoteModWire.proofHeaderName.lowercased()],
            ClaudeRemoteModWire.answerProof(key: key, nonce: nonce, body: answer.body)
        )
        let lines = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: answer.body) as? [String: Any])?["lines"] as? [String]
        )
        XCTAssertEqual(lines.count, 1)

        // A rotated token is a new key: the old proof no longer opens it.
        _ = try hosts.rotateToken(hostID: hostID)
        let afterRotation = try postToRemoteListener(
            port: port, path: ClaudeRemoteModWire.pollPath, headers: headers(proof: proof), body: body
        )
        XCTAssertEqual(afterRotation.status, 401)
    }
}

#endif
