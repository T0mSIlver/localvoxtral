import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

private final class CoordinatorMemoryStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<Data?>(nil)

    func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
}

private final class CoordinatorMarkerQueue: Sendable {
    private let values: Mutex<[String]>

    init(_ values: [String]) {
        self.values = Mutex(values)
    }

    func next() -> String {
        values.withLock {
            $0.isEmpty ? ClaudeSessionRegistry.defaultMarkerValue() : $0.removeFirst()
        }
    }
}

@MainActor
final class ClaudeRemoteListenerCoordinatorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 3_000_000)

    private func makeHosts() throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-coordinator-hosts.json"),
            io: CoordinatorMemoryStore(),
            now: { [epoch] in epoch }
        )
    }

    private func makeSessions(markers: [String]) -> ClaudeSessionRegistry {
        let queue = CoordinatorMarkerQueue(markers)
        return ClaudeSessionRegistry(
            now: { [epoch] in epoch },
            isProcessAlive: { _ in true },
            allocateMarkerValue: { queue.next() }
        )
    }

    /// A coordinator whose listener binds an ephemeral port rather than 8473 —
    /// see the note in the first test on why.
    private func makeCoordinator(
        hosts: ClaudeRemoteHostRegistry,
        sessions: ClaudeSessionRegistry
    ) -> ClaudeRemoteListenerCoordinator {
        ClaudeRemoteListenerCoordinator(hosts: hosts, sessions: sessions) { registry in
            ClaudeRemoteContextListener(
                registry: sessions,
                hosts: registry,
                limits: ClaudeRemoteListenerLimits(port: 0)
            )
        }
    }

    private func record(session: String) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: epoch.timeIntervalSince1970,
            rawCwd: "/home/dev/work/service",
            prompt: nil,
            files: [],
            process: nil
        )
    }

    func testFirstEnrollmentBindsAndLastRevocationStopsARealListener() throws {
        let hosts = try makeHosts()
        let sessions = ClaudeSessionRegistry()
        // Port zero asks the kernel for an unused ephemeral port, so this proves
        // the production coordinator/listener transition without racing a
        // developer's app on 8473.
        let coordinator = makeCoordinator(hosts: hosts, sessions: sessions)
        defer { coordinator.shutdown() }

        try coordinator.reconcile()
        XCTAssertFalse(coordinator.isListening)

        let enrollment = try hosts.enroll(label: "builder")
        try coordinator.reconcile()
        XCTAssertTrue(coordinator.isListening)

        try hosts.revoke(hostID: enrollment.host.id)
        try coordinator.reconcile()
        XCTAssertFalse(coordinator.isListening)
    }

    func testRevokingAHostEvictsItsCachedSessionsAndMarkers() throws {
        let hosts = try makeHosts()
        let sessions = makeSessions(markers: ["lvx-gone", "lvx-kept"])
        let coordinator = makeCoordinator(hosts: hosts, sessions: sessions)
        defer { coordinator.shutdown() }

        let doomed = try hosts.enroll(label: "laptop")
        let kept = try hosts.enroll(label: "builder")
        // Exactly what the listener does on an authenticated request: scope the
        // id under the host whose token opened the connection, and take the
        // origin from that same answer.
        for host in [doomed.host, kept.host] {
            sessions.ingest(
                record(session: ClaudeRemoteSessionScope.scopedSessionID(hostID: host.id, sessionID: "s1")),
                origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: host.id))
            )
        }
        try coordinator.reconcile()
        XCTAssertEqual(sessions.liveSessions().count, 2)

        try hosts.revoke(hostID: doomed.host.id)
        try coordinator.reconcile()

        // Refusing the revoked host's next request is only half of revocation.
        // What it already published is cached here, joinable by its marker, and
        // would otherwise sit for the TTL — four hours of context from a machine
        // the user just disowned.
        let doomedID = ClaudeRemoteSessionScope.scopedSessionID(hostID: doomed.host.id, sessionID: "s1")
        XCTAssertNil(sessions.snapshot(sessionID: doomedID))
        XCTAssertEqual(sessions.resolve(marker: ClaudeSessionMarker(value: "lvx-gone")), .unknown)

        let keptID = ClaudeRemoteSessionScope.scopedSessionID(hostID: kept.host.id, sessionID: "s1")
        XCTAssertNotNil(sessions.snapshot(sessionID: keptID), "the sibling host was not revoked")
        XCTAssertTrue(coordinator.isListening, "and it still has a host to listen for")
    }

    func testRemovingAHostEvictsItsCachedSessionsAndMarkers() throws {
        let hosts = try makeHosts()
        let sessions = makeSessions(markers: ["lvx-gone", "lvx-kept"])
        let coordinator = makeCoordinator(hosts: hosts, sessions: sessions)
        defer { coordinator.shutdown() }

        let doomed = try hosts.enroll(label: "laptop")
        let kept = try hosts.enroll(label: "builder")
        for host in [doomed.host, kept.host] {
            sessions.ingest(
                record(session: ClaudeRemoteSessionScope.scopedSessionID(hostID: host.id, sessionID: "s1")),
                origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: host.id))
            )
        }

        try hosts.remove(hostID: doomed.host.id)
        try coordinator.reconcile()

        XCTAssertEqual(sessions.liveSessions().map(\.sessionID), [
            ClaudeRemoteSessionScope.scopedSessionID(hostID: kept.host.id, sessionID: "s1"),
        ])
        XCTAssertEqual(sessions.resolve(marker: ClaudeSessionMarker(value: "lvx-gone")), .unknown)
        XCTAssertEqual(
            sessions.resolve(marker: ClaudeSessionMarker(value: "lvx-kept")),
            .resolved(try XCTUnwrap(sessions.liveSessions().first))
        )
    }

    func testReconcileNeverEvictsLocalSessions() throws {
        // A local session's trust comes from peer credentials on our own socket.
        // It must survive every enrollment state, including "no hosts at all",
        // which is the state of every user who never set the remote half up.
        let hosts = try makeHosts()
        let sessions = makeSessions(markers: ["lvx-local"])
        let coordinator = makeCoordinator(hosts: hosts, sessions: sessions)
        defer { coordinator.shutdown() }

        sessions.ingest(record(session: "local-1"), origin: .localAuthenticated(peerUID: 501))

        try coordinator.reconcile()
        XCTAssertFalse(coordinator.isListening, "no host is enrolled")
        XCTAssertNotNil(sessions.snapshot(sessionID: "local-1"))

        let enrollment = try hosts.enroll(label: "builder")
        try coordinator.reconcile()
        try hosts.revoke(hostID: enrollment.host.id)
        try coordinator.reconcile()

        XCTAssertEqual(sessions.liveSessions().map(\.sessionID), ["local-1"])
        XCTAssertNotEqual(sessions.resolve(marker: ClaudeSessionMarker(value: "lvx-local")), .unknown)
    }

    func testEnrollingASecondHostEvictsNothing() throws {
        // The listener authenticates live, so adding a host rebinds nothing —
        // and it must not disturb the first host's cached context either.
        let hosts = try makeHosts()
        let sessions = makeSessions(markers: ["lvx-first"])
        let coordinator = makeCoordinator(hosts: hosts, sessions: sessions)
        defer { coordinator.shutdown() }

        let first = try hosts.enroll(label: "builder")
        try coordinator.reconcile()
        sessions.ingest(
            record(session: ClaudeRemoteSessionScope.scopedSessionID(hostID: first.host.id, sessionID: "s1")),
            origin: .remote(channel: ClaudeRemoteSessionScope.channel(hostID: first.host.id))
        )

        _ = try hosts.enroll(label: "laptop")
        try coordinator.reconcile()

        XCTAssertEqual(sessions.liveSessions().count, 1)
        XCTAssertNotEqual(sessions.resolve(marker: ClaudeSessionMarker(value: "lvx-first")), .unknown)
    }
}

#endif
