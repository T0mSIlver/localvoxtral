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

@MainActor
final class ClaudeRemoteListenerCoordinatorTests: XCTestCase {
    func testFirstEnrollmentBindsAndLastRevocationStopsARealListener() throws {
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-coordinator-hosts.json"),
            io: CoordinatorMemoryStore()
        )
        let sessions = ClaudeSessionRegistry()
        let coordinator = ClaudeRemoteListenerCoordinator(hosts: hosts) { registry in
            // Port zero asks the kernel for an unused ephemeral port, so this
            // proves the production coordinator/listener transition without
            // racing a developer's app on 8473.
            ClaudeRemoteContextListener(
                registry: sessions,
                hosts: registry,
                limits: ClaudeRemoteListenerLimits(port: 0)
            )
        }

        try coordinator.reconcile()
        XCTAssertFalse(coordinator.isListening)

        let enrollment = try hosts.enroll(label: "builder")
        try coordinator.reconcile()
        XCTAssertTrue(coordinator.isListening)

        try hosts.revoke(hostID: enrollment.host.id)
        try coordinator.reconcile()
        XCTAssertFalse(coordinator.isListening)
    }
}

#endif
