import Darwin
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

/// A real AF_UNIX server speaking cmux's line protocol.
///
/// Multi-line by necessity, unlike the herdr fixture: cmux authorizes the
/// CONNECTION, so the login and the query share one, and half of what these
/// tests assert is the ORDER and CONTENT of those two lines.
private final class CmuxTestServer: @unchecked Sendable {
    private struct State {
        var listenerFD: Int32
    }

    private let state: Mutex<State>
    private let respond: @Sendable (Data, Int) -> Data?
    private let finished = DispatchSemaphore(value: 0)
    private let receivedLines = Mutex<[Data]>([])
    private let directory: URL
    let socketPath: String

    /// - Parameter respond: called with each received line and its 0-based
    ///   index on the connection. Returning nil closes without answering.
    init(respond: @escaping @Sendable (Data, Int) -> Data?) throws {
        self.respond = respond
        let createdDirectory = URL(
            fileURLWithPath: "/tmp/lvx-cmux-\(UUID().uuidString.prefix(8))"
        )
        let createdSocketPath = createdDirectory.appendingPathComponent("cmux.sock").path
        directory = createdDirectory
        socketPath = createdSocketPath
        try FileManager.default.createDirectory(
            at: createdDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(createdSocketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(listener)
            try? FileManager.default.removeItem(at: createdDirectory)
            throw POSIXError(code)
        }
        _ = chmod(createdSocketPath, 0o600)
        state = Mutex(State(listenerFD: listener))

        Thread.detachNewThread { [self] in serve(listener: listener) }
    }

    var requestLines: [Data] { receivedLines.withLock { $0 } }

    func stop() {
        state.withLock { state in
            if state.listenerFD >= 0 {
                shutdown(state.listenerFD, SHUT_RDWR)
            }
        }
        // Cleanup-only wall clock, same precedent as the herdr fixture: no
        // assertion depends on it, it just bounds a hung serve thread so one
        // broken fixture cannot wedge the suite.
        _ = finished.wait(timeout: .now() + 2)
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve(listener: Int32) {
        defer {
            state.withLock { state in
                if state.listenerFD >= 0 {
                    close(state.listenerFD)
                    state.listenerFD = -1
                }
            }
            finished.signal()
        }

        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var index = 0
        while buffer.count <= 256 * 1024 {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                receivedLines.withLock { $0.append(line) }
                guard let reply = respond(line, index) else { return }
                index += 1
                guard write(client: client, data: reply) else { return }
                continue
            }
            let count = Darwin.read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func write(client: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(client, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private let testSurfaceID = "22222222-2222-2222-2222-222222222222"

/// The pid the tests pretend cmux is running as. The peer seams are injected
/// because a test process cannot arrange to be a DIFFERENT pid on the other end
/// of its own socket, and the impostor cases are the whole point.
private let testCmuxPID: pid_t = 4242

private func cmuxRequest(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func cmuxLine(_ object: [String: Any]) -> Data? {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    data.append(0x0A)
    return data
}

private func cmuxOK(for request: Data, result: Any) -> Data? {
    guard let id = cmuxRequest(request)?["id"] as? String else { return nil }
    return cmuxLine(["id": id, "ok": true, "result": result])
}

private func cmuxError(for request: Data, code: String, message: String = "no") -> Data? {
    guard let id = cmuxRequest(request)?["id"] as? String else { return nil }
    return cmuxLine(["id": id, "ok": false, "error": ["code": code, "message": message]])
}

/// A `system.tree` result with one window, one workspace, one pane, two
/// surfaces — the focused one second, so a client that just takes the first
/// surface it sees fails.
private func treeResult(
    activeSurfaceID: String?,
    focusedTTY: String? = "/dev/ttys004",
    activeWorkspaceID: String? = nil
) -> [String: Any] {
    var focusedSurface: [String: Any] = [
        "id": activeSurfaceID ?? "unused",
        "ref": "surface:2",
        "index": 1,
        "type": "terminal",
        "title": "claude",
        "focused": true,
    ]
    focusedSurface["tty"] = focusedTTY ?? NSNull()
    var result: [String: Any] = [
        "windows": [
            [
                "id": "11111111-1111-1111-1111-111111111111",
                "ref": "window:1",
                "workspaces": [
                    [
                        "id": "33333333-3333-3333-3333-333333333333",
                        "ref": "workspace:1",
                        "panes": [
                            [
                                "id": "44444444-4444-4444-4444-444444444444",
                                "ref": "pane:1",
                                "focused": true,
                                "surfaces": [
                                    [
                                        "id": "99999999-9999-9999-9999-999999999999",
                                        "ref": "surface:1",
                                        "index": 0,
                                        "type": "browser",
                                        "title": "docs",
                                        "focused": false,
                                        "tty": NSNull(),
                                    ],
                                    focusedSurface,
                                ],
                            ]
                        ],
                    ]
                ],
            ]
        ],
        "caller": NSNull(),
    ]
    if let activeSurfaceID {
        var active: [String: Any] = ["surface_id": activeSurfaceID]
        // Only present when the test wants the remote-hosting question asked:
        // without a workspace id there is nothing to ask about, and the client
        // sends no second request.
        if let activeWorkspaceID { active["workspace_id"] = activeWorkspaceID }
        result["active"] = active
    } else {
        result["active"] = NSNull()
    }
    return result
}

/// The cmux control-socket client, against a real socket speaking cmux's real
/// wire shapes (manaflow-ai/cmux, `CmuxControlSocket` + `TerminalController`).
@MainActor
final class CmuxSocketClientTests: XCTestCase {
    private let surfaceID = testSurfaceID

    private func client(
        server: CmuxTestServer,
        password: String? = nil,
        peerPID: pid_t? = testCmuxPID,
        peerBundleID: String? = TerminalScreenAllowlist.cmuxBundleID
    ) -> CmuxSocketClient {
        CmuxSocketClient(
            socketPaths: [server.socketPath],
            password: { password },
            timeout: 5,
            peerPID: { _ in peerPID },
            bundleIDOfRunningPID: { _ in peerBundleID }
        )
    }

    // MARK: - Framing and envelope

    func testFocusedSurfaceSendsOneSystemTreeLineAndReadsTheActiveSurface() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(CmuxFocusedSurface(surfaceID: surfaceID, tty: "/dev/ttys004"))
        )
        XCTAssertEqual(server.requestLines.count, 1, "no password ⇒ no login line")
        let request = try XCTUnwrap(server.requestLines.first.flatMap(cmuxRequest))
        XCTAssertEqual(request["method"] as? String, "system.tree")
        XCTAssertTrue((request["id"] as? String)?.hasPrefix("lvx-") == true)
        XCTAssertEqual((request["params"] as? [String: Any])?.count, 0)
    }

    /// cmux's line reader skips a `\n` preceded by `\r`, so CRLF framing would
    /// never complete a request line and every query would hang to the
    /// deadline.
    func testRequestsAreFramedWithABareNewlineAndNoCarriageReturn() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { server.stop() }

        _ = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        let line = try XCTUnwrap(server.requestLines.first)
        XCTAssertFalse(line.contains(0x0D), "a CR anywhere in the line breaks cmux's framing")
        XCTAssertFalse(line.contains(0x0A), "the fixture strips exactly one terminating LF")
    }

    func testTTYIsOptionalAndItsAbsenceIsNotAFailure() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(
                for: request,
                result: treeResult(activeSurfaceID: testSurfaceID, focusedTTY: nil)
            )
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .value(CmuxFocusedSurface(surfaceID: surfaceID, tty: nil)))
    }

    func testNoFocusedSurfaceIsUnavailable() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: nil))
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    func testAResponseAnsweringADifferentRequestIDIsRefused() async throws {
        let server = try CmuxTestServer { _, _ in
            cmuxLine([
                "id": "lvx-someone-else",
                "ok": true,
                "result": treeResult(activeSurfaceID: "aaaa"),
            ])
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    func testAGarbageLineIsRefused() async throws {
        let server = try CmuxTestServer { _, _ in Data("not json\n".utf8) }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    func testAnOversizedResponseLineIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            guard let id = cmuxRequest(request)?["id"] as? String else { return nil }
            // One byte of text past the ceiling, never newline-terminated
            // within the cap.
            let filler = String(repeating: "x", count: CmuxSocketClient.maxResponseLineBytes)
            return cmuxLine([
                "id": id, "ok": true,
                "result": ["active": ["surface_id": filler]],
            ])
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    // MARK: - Password login

    func testPasswordModeLogsInFirstOnTheSameConnectionThenQueries() async throws {
        let server = try CmuxTestServer { request, index in
            switch index {
            case 0:
                return cmuxOK(for: request, result: ["authenticated": true])
            default:
                return cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
            }
        }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2").focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(CmuxFocusedSurface(surfaceID: surfaceID, tty: "/dev/ttys004"))
        )
        XCTAssertEqual(server.requestLines.count, 2)
        let login = try XCTUnwrap(server.requestLines.first.flatMap(cmuxRequest))
        XCTAssertEqual(login["method"] as? String, "auth.login")
        XCTAssertEqual(
            (login["params"] as? [String: Any])?["password"] as? String, "hunter2",
            "cmux compares the plaintext it was sent; nothing here may pre-hash it"
        )
        let query = try XCTUnwrap(server.requestLines.last.flatMap(cmuxRequest))
        XCTAssertEqual(query["method"] as? String, "system.tree")
        XCTAssertNotEqual(
            login["id"] as? String, query["id"] as? String,
            "each request carries its own id"
        )
    }

    func testARejectedPasswordStopsBeforeTheQuery() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxError(for: request, code: "auth_failed", message: "Invalid password")
        }
        defer { server.stop() }

        let result = await client(server: server, password: "wrong").focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .authenticationRequired)
        XCTAssertEqual(
            server.requestLines.count, 1,
            "a refused login must not be followed by the query"
        )
    }

    func testAServerThatDoesNotConfirmAuthenticationIsTreatedAsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: ["authenticated": false])
        }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2").focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .authenticationRequired)
    }

    /// Only an explicit `authenticated: true` may be read as a login. A
    /// success-shaped envelope that omits the field is not a confirmation, and
    /// must not become one by decoding loosely.
    func testALoginEnvelopeWithoutTheAuthenticatedFieldIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: [:])
        }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2")
            .focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .authenticationRequired)
        XCTAssertEqual(
            server.requestLines.count, 1,
            "an unconfirmed login must not be followed by the query"
        )
    }

    /// The same rule for a login answer that is not JSON at all, and for one
    /// that answers a different request id. Both used to abstain as
    /// `.unavailable`, which loses the actionable reason.
    func testAMalformedLoginResponseIsRefusedRatherThanAbstained() async throws {
        let server = try CmuxTestServer { _, _ in Data("{not json\n".utf8) }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2")
            .focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .authenticationRequired)
    }

    /// `ok: true` is REQUIRED in this fixture, and its absence is what made an
    /// earlier version of this test worthless: `Envelope.init` decodes `ok`
    /// non-optionally, so an envelope without it fails to decode and the strict
    /// id comparison is never reached. The test still went green — for the
    /// wrong reason, and it would have gone green with id matching deleted.
    /// With `ok` present the envelope decodes cleanly and a confirmed-looking
    /// `authenticated: true` is refused on the id alone, which is the claim.
    func testALoginResponseAnsweringAnotherRequestIsRefused() async throws {
        let server = try CmuxTestServer { _, _ in
            var line = try! JSONSerialization.data(
                withJSONObject: [
                    "id": "not-our-request",
                    "ok": true,
                    "result": ["authenticated": true],
                ]
            )
            line.append(0x0A)
            return line
        }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2")
            .focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .authenticationRequired)
    }

    func testPasswordModeWithNoPasswordSurfacesAuthRequired() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxError(
                for: request,
                code: "auth_required",
                message: "Authentication required. Send auth <password> first."
            )
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .authenticationRequired)    }

    func testAnUnconfiguredPasswordSurfacesAuthRequired() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxError(for: request, code: "auth_unconfigured")
        }
        defer { server.stop() }

        let result = await client(server: server, password: "hunter2").focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .authenticationRequired)
    }

    /// cmux's DEFAULT mode (`cmuxOnly`) rejects us with a plain-text line
    /// before any JSON is exchanged — and localizes it, so only the `ERROR:`
    /// prefix is contractual.
    func testAPlainTextAccessDenialSurfacesAuthRequired() async throws {
        let server = try CmuxTestServer { _, _ in
            Data("ERROR: Access denied - only processes started inside cmux can connect\n".utf8)
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .authenticationRequired)    }

    func testANonCredentialErrorIsAnAbstentionNotAPasswordProblem() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxError(for: request, code: "method_not_found", message: "Unknown method")
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    // MARK: - surface.read_text

    func testSurfaceReadAsksForTheViewportOfExactlyOneSurface() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(
                for: request,
                result: [
                    "text": "swift build\nerror: FooBar.swift:12",
                    "base64": "aWdub3JlZA==",
                    "surface_id": testSurfaceID,
                    "surface_ref": "surface:2",
                    "workspace_id": "33333333-3333-3333-3333-333333333333",
                ]
            )
        }
        defer { server.stop() }

        let result = await client(server: server).surfaceText(surfaceID: surfaceID, expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .value("swift build\nerror: FooBar.swift:12"))
        let request = try XCTUnwrap(server.requestLines.first.flatMap(cmuxRequest))
        XCTAssertEqual(request["method"] as? String, "surface.read_text")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["surface_id"] as? String, surfaceID)
        XCTAssertEqual(
            params["scrollback"] as? Bool, false,
            "the viewport is the screen; the history is not"
        )
        XCTAssertNil(
            params["lines"],
            "`lines` IMPLIES scrollback:true in cmux — the parameter that looks like a bound asks for more"
        )
    }

    func testTextAboutADifferentSurfaceIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(
                for: request,
                result: [
                    "text": "another pane's secrets",
                    "surface_id": "99999999-9999-9999-9999-999999999999",
                ]
            )
        }
        defer { server.stop() }

        let result = await client(server: server).surfaceText(surfaceID: surfaceID, expectedPeerPID: testCmuxPID)
        XCTAssertEqual(
            result, .unavailable,
            "text that does not name the requested surface must never be attributed to it"
        )
    }

    func testMissingSurfaceIDInTheReadResponseIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: ["text": "unattributed"])
        }
        defer { server.stop() }

        let result = await client(server: server).surfaceText(surfaceID: surfaceID, expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)
    }

    // MARK: - Remote-hosting evidence

    /// cmux exposes NO remote-ness on the surface node itself — a `cmux ssh`
    /// surface is an ordinary `type: "terminal"`, and the state lives on the
    /// workspace. So the client asks `workspace.remote.status` for the focused
    /// surface's workspace, ON THE SAME CONNECTION as the focus answer.
    func testRemoteHostingIsReadFromTheWorkspaceOnTheSameConnection() async throws {
        let server = try CmuxTestServer { request, index in
            switch index {
            case 0:
                return cmuxOK(
                    for: request,
                    result: treeResult(
                        activeSurfaceID: testSurfaceID,
                        activeWorkspaceID: "ws-1"
                    )
                )
            default:
                return cmuxOK(
                    for: request,
                    result: ["remote": ["enabled": true, "connected": true]]
                )
            }
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(
                CmuxFocusedSurface(
                    surfaceID: testSurfaceID, tty: "/dev/ttys004", workspaceIsRemote: true
                )
            )
        )
        XCTAssertEqual(server.requestLines.count, 2)
        let status = try XCTUnwrap(server.requestLines.last.flatMap(cmuxRequest))
        XCTAssertEqual(status["method"] as? String, "workspace.remote.status")
        XCTAssertEqual(
            (status["params"] as? [String: Any])?["workspace_id"] as? String, "ws-1"
        )
    }

    /// A remote workspace whose link is DOWN is not currently hosting anything,
    /// so it must not vouch for a remote claim either.
    func testARemoteWorkspaceThatIsNotConnectedDoesNotCountAsRemoteHosted() async throws {
        let server = try CmuxTestServer { request, index in
            index == 0
                ? cmuxOK(
                    for: request,
                    result: treeResult(activeSurfaceID: testSurfaceID, activeWorkspaceID: "ws-1")
                )
                : cmuxOK(for: request, result: ["remote": ["enabled": true, "connected": false]])
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(
                CmuxFocusedSurface(
                    surfaceID: testSurfaceID, tty: "/dev/ttys004", workspaceIsRemote: false
                )
            )
        )
    }

    func testALocalWorkspaceReportsNotRemoteHosted() async throws {
        let server = try CmuxTestServer { request, index in
            index == 0
                ? cmuxOK(
                    for: request,
                    result: treeResult(activeSurfaceID: testSurfaceID, activeWorkspaceID: "ws-1")
                )
                : cmuxOK(for: request, result: ["remote": ["enabled": false, "connected": false]])
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(
                CmuxFocusedSurface(
                    surfaceID: testSurfaceID, tty: "/dev/ttys004", workspaceIsRemote: false
                )
            )
        )
    }

    /// An older cmux without the method — "unknown", NOT "local". The resolver
    /// refuses remote claims on unknown, but the distinction is what lets it
    /// say why.
    func testAnUnsupportedRemoteStatusMethodLeavesRemoteHostingUnknown() async throws {
        let server = try CmuxTestServer { request, index in
            index == 0
                ? cmuxOK(
                    for: request,
                    result: treeResult(activeSurfaceID: testSurfaceID, activeWorkspaceID: "ws-1")
                )
                : cmuxError(for: request, code: "method_not_found")
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(
                CmuxFocusedSurface(
                    surfaceID: testSurfaceID, tty: "/dev/ttys004", workspaceIsRemote: nil
                )
            )
        )
    }

    /// A `remote` object that omits `connected` must not read as connected.
    func testAMissingConnectedFlagIsNotConnected() async throws {
        let server = try CmuxTestServer { request, index in
            index == 0
                ? cmuxOK(
                    for: request,
                    result: treeResult(activeSurfaceID: testSurfaceID, activeWorkspaceID: "ws-1")
                )
                : cmuxOK(for: request, result: ["remote": ["enabled": true]])
        }
        defer { server.stop() }

        let result = await client(server: server).focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(
                CmuxFocusedSurface(
                    surfaceID: testSurfaceID, tty: "/dev/ttys004", workspaceIsRemote: false
                )
            )
        )
    }

    // MARK: - Peer authentication (the password's precondition)

    /// The blocker this arm was rebuilt around: the path check proves only that
    /// a same-UID socket EXISTS at a name. Any process running as this user can
    /// bind one of the candidate paths — the legacy `/tmp` ones especially —
    /// pass that check trivially, and harvest the Keychain password. The
    /// connected peer's pid is what actually decides.
    func testAnImpostorSocketOwnedByThisUserNeverReceivesThePassword() async throws {
        let impostor = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: ["authenticated": true])
        }
        defer { impostor.stop() }
        // Same uid, same path shape, real socket — and a different process.
        let client = client(
            server: impostor,
            password: "hunter2",
            peerPID: testCmuxPID &+ 1
        )

        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(
            impostor.requestLines.isEmpty,
            "not one byte — and above all not the password — may reach a peer that is not the focused cmux app"
        )
    }

    /// The TOCTOU half: the path passed the guard, and by the time we are
    /// connected the peer is somebody else. Only the post-connect check can
    /// catch this, which is why it is the one that gates the password.
    func testAPeerThatCannotBeIdentifiedNeverReceivesThePassword() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: ["authenticated": true])
        }
        defer { server.stop() }
        let client = client(server: server, password: "hunter2", peerPID: nil)

        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(server.requestLines.isEmpty)
    }

    /// A pid that died and was recycled between the join resolving and this
    /// connection: right number, wrong process.
    func testAPeerPIDNoLongerRunningCmuxIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: ["authenticated": true])
        }
        defer { server.stop() }
        let client = client(
            server: server,
            password: "hunter2",
            peerBundleID: "com.example.something-else"
        )

        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(server.requestLines.isEmpty)
    }

    /// An impostor must not be able to manufacture the "multiple live sockets"
    /// ambiguity either — it is dropped, not counted, so the real cmux still
    /// answers.
    func testAnImpostorCandidateDoesNotBlockTheRealCmuxSocket() async throws {
        let real = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { real.stop() }
        let impostor = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: "impostor-surface"))
        }
        defer { impostor.stop() }
        let realPath = real.socketPath
        let client = CmuxSocketClient(
            // Impostor first in the candidate order, so a client that took the
            // first thing that connected would take the wrong one.
            socketPaths: [impostor.socketPath, real.socketPath],
            timeout: 5,
            peerPID: { fd in
                // Only the real server's connection reports the cmux pid.
                var address = sockaddr_un()
                var length = socklen_t(MemoryLayout<sockaddr_un>.size)
                let named = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getpeername(fd, $0, &length)
                    }
                }
                guard named == 0 else { return nil }
                let path = withUnsafeBytes(of: &address.sun_path) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                return path == realPath ? testCmuxPID : 9999
            },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )

        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(CmuxFocusedSurface(surfaceID: testSurfaceID, tty: "/dev/ttys004"))
        )
        XCTAssertTrue(impostor.requestLines.isEmpty)
    }

    // MARK: - The socket file guard

    func testAForeignOwnerSocketIsRefusedWithoutConnecting() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { server.stop() }
        let foreign = CmuxSocketClient(
            socketPaths: [server.socketPath],
            timeout: 5,
            socketMetadata: { _ in
                ClaudeSocketGuard.PathMetadata(
                    isDirectory: false,
                    isSymlink: false,
                    isSocket: true,
                    ownerUID: UInt32(getuid()) &+ 1,
                    mode: 0o600
                )
            },
            peerPID: { _ in testCmuxPID },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )

        let result = await foreign.focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(server.requestLines.isEmpty, "not one byte may reach a foreign-owned socket")
    }

    func testANonSocketPathIsRefused() async throws {
        let server = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { server.stop() }
        let regularFile = CmuxSocketClient(
            socketPaths: [server.socketPath],
            timeout: 5,
            socketMetadata: { _ in
                ClaudeSocketGuard.PathMetadata(
                    isDirectory: false,
                    isSymlink: false,
                    isSocket: false,
                    ownerUID: UInt32(getuid()),
                    mode: 0o600
                )
            },
            peerPID: { _ in testCmuxPID },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )

        let result = await regularFile.focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(server.requestLines.isEmpty)
    }

    func testARelativeSocketPathIsRefused() async {
        let client = CmuxSocketClient(
            socketPaths: ["relative/cmux.sock"],
            timeout: 5,
            peerPID: { _ in testCmuxPID },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )
        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    func testNoReachableSocketIsUnavailable() async throws {
        // A real socket FILE with nothing listening: the stale leftovers a
        // crashed cmux leaves behind must read as "not running", not as an
        // error worth telling the user about.
        let directory = URL(fileURLWithPath: "/tmp/lvx-cmux-stale-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Bound but never listening.
        defer { close(fd) }

        let client = CmuxSocketClient(
            socketPaths: [path],
            timeout: 5,
            peerPID: { _ in testCmuxPID },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )
        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)
        XCTAssertEqual(result, .unavailable)    }

    /// Two live sockets are no longer decided by COUNTING them.
    ///
    /// The earlier rule abstained on two reachable candidates because it had no
    /// way to tell the instances apart. Peer identity is a stronger answer to
    /// the same question: two candidates held by DIFFERENT processes cannot
    /// both be the frontmost cmux app, so at most one survives authentication
    /// (`testAnImpostorCandidateDoesNotBlockTheRealCmuxSocket` pins that). Two
    /// candidates held by the SAME process are one cmux listening on two paths,
    /// which is not ambiguous at all — either answers for the app the user is
    /// looking at, and the query proceeds.
    func testTwoSocketsHeldByTheSameCmuxProcessAreNotAmbiguous() async throws {
        let first = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { first.stop() }
        let second = try CmuxTestServer { request, _ in
            cmuxOK(for: request, result: treeResult(activeSurfaceID: testSurfaceID))
        }
        defer { second.stop() }

        let client = CmuxSocketClient(
            socketPaths: [first.socketPath, second.socketPath],
            timeout: 5,
            peerPID: { _ in testCmuxPID },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )

        let result = await client.focusedSurface(expectedPeerPID: testCmuxPID)

        XCTAssertEqual(
            result,
            .value(CmuxFocusedSurface(surfaceID: testSurfaceID, tty: "/dev/ttys004"))
        )
        XCTAssertEqual(
            first.requestLines.count + second.requestLines.count, 1,
            "exactly one of the two is used; the other is closed unquestioned"
        )
    }

    // MARK: - Default paths

    /// The public API docs still name `/tmp/cmux.sock`; the source says the
    /// release path lives under the state directory and `/tmp` is the legacy
    /// fallback. Both are candidates, in that order.
    func testDefaultSocketPathsPreferTheStateDirectoryOverTheLegacyTmpPath() {
        let paths = CmuxSocketClient.defaultSocketPaths()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(paths.first, "\(home)/.local/state/cmux/cmux.sock")
        XCTAssertTrue(paths.contains("/tmp/cmux.sock"))
        XCTAssertTrue(paths.contains("\(home)/.local/state/cmux/cmux-\(getuid()).sock"))
        XCTAssertFalse(
            paths.contains { $0.contains("debug") || $0.contains("nightly") },
            "a development build of someone else's terminal is not ours to join unasked"
        )
    }
}

#endif
