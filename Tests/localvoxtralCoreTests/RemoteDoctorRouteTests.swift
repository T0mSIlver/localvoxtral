import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// `/v1/doctor` on the remote listener (#910): a host's `localvoxtral
/// doctor` gets the Mac's host-safe checks for itself, and only with its
/// token.
final class RemoteDoctorRouteTests: XCTestCase {
    private var hosts: ClaudeRemoteHostRegistry!
    private var listener: ClaudeRemoteContextListener!
    private var port: UInt16 = 0
    private var token = ""
    private var hostID = ""
    private final class Asked: Sendable {
        let ids = Mutex<[String]>([])
    }

    private let asked = Asked()

    private func start(doctor: RemoteDoctorRoute?) throws {
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-remote-doctor-hosts-\(UUID().uuidString).json"),
            io: MemoryRemoteHostStoreIO()
        )
        let enrollment = try hosts.enroll(label: "devbox")
        token = enrollment.token
        hostID = enrollment.host.id
        port = try unusedLoopbackPort()
        listener = ClaudeRemoteContextListener(
            registry: ClaudeSessionRegistry(isProcessAlive: { _ in true }),
            hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port),
            doctor: doctor
        )
        try listener.start()
    }

    private func route() -> RemoteDoctorRoute {
        RemoteDoctorRoute { [asked] hostID in
            asked.ids.withLock { $0.append(hostID) }
            return [
                AgentCLICheck(id: "app", title: "App", state: .ok, detail: "localvoxtral 1.4.0."),
                AgentCLICheck(id: "accessibility", title: "Accessibility", state: .failed, detail: "Not allowed.",
                              fix: "Turn it on."),
            ]
        }
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    private func post(headers: [String: String]) throws -> RemoteListenerResponse {
        try postToRemoteListener(port: port, path: RemoteDoctorRoute.path, headers: headers, body: Data())
    }

    func testWithoutTheTokenTheRouteIsA401LikeEveryOther() throws {
        try start(doctor: route())
        XCTAssertEqual(try post(headers: [:]).status, 401)
        XCTAssertEqual(try post(headers: ["Authorization": "Bearer not-a-token"]).status, 401)
        XCTAssertEqual(asked.ids.withLock { $0 }, [])
    }

    func testTheHostGetsTheNumberedChecksForItselfAsText() throws {
        try start(doctor: route())
        let response = try post(headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(response.headers["x-lvx-doctor-failed"], "1")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), """
            1. [ok  ] App: localvoxtral 1.4.0.
            2. [FAIL] Accessibility: Not allowed.
               fix: Turn it on.

            1 failed, 0 to look at.

            """)
        XCTAssertEqual(asked.ids.withLock { $0 }, [hostID])
        // Running doctor is not the host sending context.
        XCTAssertNil(hosts.host(id: hostID)?.lastSeenAt)
    }

    func testAcceptJSONGetsTheResponseTheMacsOwnDoctorPrints() throws {
        try start(doctor: route())
        let response = try post(headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
        XCTAssertEqual(response.status, 200)
        let decoded = try XCTUnwrap(AgentCLIWire.decodeResponse(response.body))
        XCTAssertEqual(decoded.doctor?.checks.map(\.id), ["app", "accessibility"])
        XCTAssertEqual(response.headers["x-lvx-doctor-failed"], "1")
    }

    /// The host's exit status reads this count, so a clean Mac says 0 rather
    /// than leaving the header out, which means a Mac too old to count.
    func testNoFailedCheckSendsAFailedCountOfZero() throws {
        try start(doctor: RemoteDoctorRoute { _ in
            [AgentCLICheck(id: "accessibility", title: "Accessibility", state: .warning, detail: "Not checked.")]
        })
        let response = try post(headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["x-lvx-doctor-failed"], "0")
    }

    func testARevokedHostGetsNothing() throws {
        try start(doctor: route())
        try hosts.revoke(hostID: hostID)
        XCTAssertEqual(try post(headers: ["Authorization": "Bearer \(token)"]).status, 401)
        XCTAssertEqual(asked.ids.withLock { $0 }, [])
    }

    func testAnAppWithoutTheRouteAnswers404AfterTheToken() throws {
        try start(doctor: nil)
        XCTAssertEqual(try post(headers: [:]).status, 401)
        XCTAssertEqual(try post(headers: ["Authorization": "Bearer \(token)"]).status, 404)
    }

    /// The app holds the answer until the test has seen the 503.
    func testAnAppThatDoesNotAnswerInTimeGetsA503() throws {
        let release = DispatchSemaphore(value: 0)
        try start(doctor: RemoteDoctorRoute(timeout: 0.05) { _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return []
        })
        XCTAssertEqual(try post(headers: ["Authorization": "Bearer \(token)"]).status, 503)
        release.signal()
    }
}
