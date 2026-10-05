import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The other waiting sessions in each attached mod's band (#1695): what the
/// app posts on a wait, on its clear, and when a mod attaches.
final class AgentWaitingBandTests: XCTestCase {
    nonisolated private static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    /// The `state` lines each session's channel received.
    private final class Posted: Sendable {
        private let lines = Mutex<[String: [ClaudeModChannelWire.Message]]>([:])

        func channel(_ sessionID: String) -> ClaudeModChannelHub.Channel {
            .init(
                write: { [self] line in
                    let message = ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: line.dropLast())
                    self.lines.withLock { $0[sessionID, default: []].append(message!) }
                    return true
                },
                close: {}
            )
        }

        func waiting(_ sessionID: String) -> [[String]?] {
            lines.withLock { $0[sessionID, default: []] }.map(\.waiting)
        }

        func all(_ sessionID: String) -> [ClaudeModChannelWire.Message] {
            lines.withLock { $0[sessionID, default: []] }
        }
    }

    private struct Harness {
        let registry: ClaudeSessionRegistry
        let hub: ClaudeModChannelHub
        let band: AgentWaitingBand
        let posted: Posted
    }

    @MainActor
    private func harness(attached: [String]) -> Harness {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        let hub = ClaudeModChannelHub(sleep: { _ in }, makeID: { "id" })
        let posted = Posted()
        for sessionID in attached { _ = hub.attach(sessionID: sessionID, channel: posted.channel(sessionID)) }
        let band = AgentWaitingBand(hub: hub)
        let tracker = AgentAttentionTracker(
            isEnabled: { true },
            isWatching: { _ in false },
            liveSessionIDs: { Set(registry.liveSessions().map(\.sessionID)) },
            now: { Self.epoch }
        )
        tracker.onChange = { [weak tracker] in if let tracker { band.update(tracker.queue) } }
        registry.setTurnObserver { event, session, sequence in
            MainActor.assumeIsolated { _ = tracker.receive(event, session: session, sequence: sequence) }
        }
        return Harness(registry: registry, hub: hub, band: band, posted: posted)
    }

    private func record(_ json: String) throws -> ClaudeHookRecord {
        var record = try XCTUnwrap(ClaudeHookInputParser.parse(data: Data(json.utf8), fallbackEvent: nil, timestamp: 0))
        record.process = ClaudeHookProcessInfo(hookPID: 10, claudePID: 11, tty: "/dev/ttys004")
        return record
    }

    private func wait(_ sessionID: String, in cwd: String) throws -> ClaudeHookRecord {
        try record(#"{"hook_event_name":"Notification","session_id":"\#(sessionID)","cwd":"\#(cwd)","notification_type":"permission_prompt"}"#)
    }

    private func prompt(_ sessionID: String, in cwd: String) throws -> ClaudeHookRecord {
        try record(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sessionID)","cwd":"\#(cwd)","prompt":"go on"}"#)
    }

    @MainActor
    func testAWaitReachesTheOtherSessionsBandAndItsClearEmptiesIt() async throws {
        let h = harness(attached: ["s1", "s2"])

        h.registry.ingest(try wait("s2", in: "/work/payments"), origin: local)
        XCTAssertEqual(h.posted.waiting("s1"), [["payments"]])
        XCTAssertEqual(h.posted.all("s1").map(\.kind), [.state])
        XCTAssertEqual(h.posted.all("s1").map(\.phase), [nil], "a waiting line never touches the dictation's band")
        XCTAssertEqual(h.posted.waiting("s2"), [], "a session is never told about itself")

        h.registry.ingest(try prompt("s2", in: "/work/payments"), origin: local)
        XCTAssertEqual(h.posted.waiting("s1"), [["payments"], []])
        XCTAssertEqual(h.posted.waiting("s2"), [])
    }

    @MainActor
    func testOnlyAChangeIsSentAndTheOldestWaitComesFirst() async throws {
        let h = harness(attached: ["s1"])
        h.registry.ingest(try wait("s2", in: "/work/payments"), origin: local)
        h.registry.ingest(try wait("s2", in: "/work/payments"), origin: local)
        h.registry.ingest(try wait("s3", in: "/work/api"), origin: local)
        XCTAssertEqual(h.posted.waiting("s1"), [["payments"], ["payments", "api"]])
    }

    @MainActor
    func testAnotherHarnessWaitingIsNotNamed() async throws {
        let h = harness(attached: ["s1"])
        let codex = try XCTUnwrap(CodexHookInputParser.parse(
            data: Data(#"{"session_id":"c1","hook_event_name":"PermissionRequest","cwd":"/work/api","tool_name":"Bash","tool_input":{"command":"make"}}"#.utf8),
            timestamp: 0
        ))
        h.registry.ingest(codex, origin: local)
        XCTAssertEqual(h.posted.waiting("s1"), [])
    }

    @MainActor
    func testAModThatAttachesHearsWhoAlreadyWaits() async throws {
        let h = harness(attached: ["s1"])
        h.registry.ingest(try wait("s2", in: "/work/payments"), origin: local)

        _ = h.hub.attach(sessionID: "s3", channel: h.posted.channel("s3"))
        h.band.attached(sessionID: "s3")
        XCTAssertEqual(h.posted.waiting("s3"), [["payments"]])

        // A reloaded mod starts blank, so it hears the same list again.
        h.band.attached(sessionID: "s1")
        XCTAssertEqual(h.posted.waiting("s1"), [["payments"], ["payments"]])
    }

    @MainActor
    func testAModThatAttachesWhileNobodyWaitsHearsNothing() async {
        let h = harness(attached: [])
        _ = h.hub.attach(sessionID: "s1", channel: h.posted.channel("s1"))
        h.band.attached(sessionID: "s1")
        XCTAssertEqual(h.posted.waiting("s1"), [])
    }

    func testTheHubTellsItsObserverAboutEachAttach() {
        let hub = ClaudeModChannelHub(sleep: { _ in })
        let seen = Mutex<[String]>([])
        hub.observeAttach { id in seen.withLock { $0.append(id) } }
        _ = hub.attach(sessionID: "s1", channel: .init(write: { _ in true }, close: {}))
        _ = hub.attach(sessionID: "s1", channel: .init(write: { _ in true }, close: {}))
        XCTAssertEqual(seen.withLock { $0 }, ["s1"], "a refused attach is not one")
        XCTAssertEqual(hub.attachedSessionIDs(), ["s1"])
    }
}
