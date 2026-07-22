import Darwin
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

/// One real AF_UNIX connection per fixture, matching herdr's protocol rather
/// than hiding framing or lifecycle behavior behind a mock transport.
private final class HerdrOneShotServer: @unchecked Sendable {
    private struct State {
        var listenerFD: Int32
    }

    private let state: Mutex<State>
    private let response: @Sendable (Data) -> Data?
    private let finished = DispatchSemaphore(value: 0)
    private let receivedLine = Mutex<Data?>(nil)
    private let directory: URL
    let socketPath: String

    init(response: @escaping @Sendable (Data) -> Data?) throws {
        self.response = response
        let createdDirectory = URL(
            fileURLWithPath: "/tmp/lvx-herdr-\(UUID().uuidString.prefix(8))"
        )
        let createdSocketPath = createdDirectory.appendingPathComponent("herdr.sock").path
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
        guard bound == 0, listen(listener, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(listener)
            try? FileManager.default.removeItem(at: createdDirectory)
            throw POSIXError(code)
        }
        _ = chmod(createdSocketPath, 0o600)
        state = Mutex(State(listenerFD: listener))

        Thread.detachNewThread { [self] in serve(listener: listener) }
    }

    var requestLine: Data? { receivedLine.withLock { $0 } }

    func stop() {
        state.withLock { state in
            if state.listenerFD >= 0 {
                shutdown(state.listenerFD, SHUT_RDWR)
            }
        }
        // Cleanup-only wall clock, same precedent as the broker tests: no
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

        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while line.count <= 64 * 1024 {
            let count = Darwin.read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            line.append(contentsOf: chunk[0..<count])
            if let newline = line.firstIndex(of: 0x0A) {
                line = Data(line[line.startIndex..<newline])
                break
            }
        }
        receivedLine.withLock { $0 = line }
        guard let reply = response(line) else { return }

        reply.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(client, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
        shutdown(client, SHUT_WR)
    }
}

private func herdrRequest(_ data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return object as? [String: Any]
}

private func paneReadResult(
    paneID: String = "pane-a",
    text: String = "swift build\nerror: FooBar.swift:12",
    type: String = "pane_read"
) -> [String: Any] {
    [
        "type": type,
        "read": [
            "pane_id": paneID,
            "workspace_id": "ws-1",
            "tab_id": "tab-1",
            "source": "visible",
            "format": "text",
            "text": text,
            "revision": 3,
            "truncated": false,
        ],
    ]
}

private func herdrResponse(
    for request: Data,
    result: [String: Any]? = nil,
    error: [String: Any]? = nil
) -> Data? {
    guard let id = herdrRequest(request)?["id"] as? String else { return nil }
    var object: [String: Any] = ["id": id]
    if let result { object["result"] = result }
    if let error { object["error"] = error }
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    data.append(0x0A)
    return data
}

@MainActor
final class HerdrSocketClientTests: XCTestCase {
    func testFocusedPaneHappyPathUsesStringIDAndRequiredEmptyParams() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_current",
                    "pane": [
                        "pane_id": "pane-a",
                        "focused": true,
                        "workspace_id": "ignored",
                        "agent_session": [
                            "source": "hook",
                            "agent": "claude",
                            "kind": "id",
                            "value": "session-a",
                        ],
                    ],
                ]
            )
        }
        defer { server.stop() }

        let pane = await HerdrSocketClient().focusedPane(socketPath: server.socketPath)

        XCTAssertEqual(
            pane,
            HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: "session-a")
        )
        let request = try XCTUnwrap(server.requestLine.flatMap(herdrRequest))
        XCTAssertTrue(request["id"] is String)
        XCTAssertTrue((request["id"] as? String)?.hasPrefix("lvx-") == true)
        XCTAssertEqual(request["method"] as? String, "pane.current")
        XCTAssertEqual((request["params"] as? [String: Any])?.count, 0)
    }

    func testErrorEnvelopeAbstains() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                error: ["code": "pane_not_found", "message": "not found"]
            )
        }
        defer { server.stop() }

        let pane = await HerdrSocketClient().focusedPane(socketPath: server.socketPath)
        XCTAssertNil(pane)
    }

    func testWrongResultTypeAbstains() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_process_info",
                    "pane": ["pane_id": "pane-a", "focused": true],
                ]
            )
        }
        defer { server.stop() }

        let pane = await HerdrSocketClient().focusedPane(socketPath: server.socketPath)
        XCTAssertNil(pane)
    }

    func testOversizedResponseLineAbstains() async throws {
        let server = try HerdrOneShotServer { _ in
            var data = Data(repeating: 0x61, count: 1024 * 1024 + 1)
            data.append(0x0A)
            return data
        }
        defer { server.stop() }

        let pane = await HerdrSocketClient().focusedPane(socketPath: server.socketPath)
        XCTAssertNil(pane)
    }

    func testShortInjectedDeadlineExpiresWhenServerDoesNotReply() async throws {
        let release = DispatchSemaphore(value: 0)
        let server = try HerdrOneShotServer { _ in
            release.wait()
            return nil
        }
        defer {
            release.signal()
            server.stop()
        }

        let pane = await HerdrSocketClient(timeout: 0.01).focusedPane(
            socketPath: server.socketPath
        )
        XCTAssertNil(pane)
    }

    func testNonSocketPathIsRefused() async throws {
        let directory = URL(fileURLWithPath: "/tmp/lvx-herdr-file-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("not-a-socket")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = await HerdrSocketClient().focusedPane(socketPath: file.path)
        XCTAssertNil(pane)
    }

    func testEmptySocketPathIsRefused() async {
        let pane = await HerdrSocketClient().focusedPane(socketPath: "")
        XCTAssertNil(pane)
    }

    func testForeignOwnerSocketIsRefused() async throws {
        // A real foreign-uid socket cannot be created from a single-user test
        // process, so ownership refusal is exercised through the injected
        // metadata seam: a live server whose stat lies about the owner must
        // never be queried.
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_current",
                    "pane": ["pane_id": "pane-a", "focused": true],
                ]
            )
        }
        defer { server.stop() }

        let client = HerdrSocketClient(socketMetadata: { _ in
            ClaudeSocketGuard.PathMetadata(
                isDirectory: false,
                isSymlink: false,
                isSocket: true,
                ownerUID: UInt32(getuid()) &+ 1,
                mode: 0o600
            )
        })
        let pane = await client.focusedPane(socketPath: server.socketPath)
        XCTAssertNil(pane)
        XCTAssertNil(server.requestLine, "a refused socket must never receive a request")
    }

    func testPathAgentSessionDoesNotBecomeSessionIDClaim() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_current",
                    "pane": [
                        "pane_id": "pane-a",
                        "focused": true,
                        "agent_session": [
                            "source": "hook",
                            "agent": "claude",
                            "kind": "path",
                            "value": "/tmp/session.json",
                        ],
                    ],
                ]
            )
        }
        defer { server.stop() }

        let pane = await HerdrSocketClient().focusedPane(socketPath: server.socketPath)
        XCTAssertEqual(pane?.paneID, "pane-a")
        XCTAssertNil(pane?.claimedClaudeSessionID)
    }

    func testForegroundProcessesAbsentRemainsNil() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_process_info",
                    "process_info": [
                        "pane_id": "pane-a",
                        "shell_pid": 7001,
                        "tty": NSNull(),
                    ],
                ]
            )
        }
        defer { server.stop() }

        let info = await HerdrSocketClient().paneForegroundInfo(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertEqual(info?.shellPID, 7001)
        XCTAssertNil(info?.foregroundPIDs)
        let request = try XCTUnwrap(server.requestLine.flatMap(herdrRequest))
        XCTAssertEqual(request["method"] as? String, "pane.process_info")
        XCTAssertEqual((request["params"] as? [String: Any])?["pane_id"] as? String, "pane-a")
    }

    // MARK: - pane.read

    /// The exact wire shape herdr c234f221 accepts: `pane.read` with required
    /// `pane_id` + `source`, and `strip_ansi` as a real JSON bool — a string
    /// "true" would fail herdr's serde decoding.
    func testPaneVisibleTextHappyPathSendsPaneReadWireShape() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(for: request, result: paneReadResult())
        }
        defer { server.stop() }

        let text = await HerdrSocketClient().paneVisibleText(
            socketPath: server.socketPath, paneID: "pane-a"
        )

        XCTAssertEqual(text, "swift build\nerror: FooBar.swift:12")
        let request = try XCTUnwrap(server.requestLine.flatMap(herdrRequest))
        XCTAssertTrue((request["id"] as? String)?.hasPrefix("lvx-") == true)
        XCTAssertEqual(request["method"] as? String, "pane.read")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["pane_id"] as? String, "pane-a")
        XCTAssertEqual(params["source"] as? String, "visible")
        XCTAssertEqual(params["format"] as? String, "text")
        XCTAssertEqual(params["strip_ansi"] as? Bool, true)
    }

    func testPaneVisibleTextMismatchedResponsePaneIDAbstains() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(for: request, result: paneReadResult(paneID: "pane-OTHER"))
        }
        defer { server.stop() }

        let text = await HerdrSocketClient().paneVisibleText(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertNil(text, "another pane's text must never be attributed to the joined pane")
    }

    func testPaneVisibleTextWrongResultTypeAbstains() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(for: request, result: paneReadResult(type: "pane_current"))
        }
        defer { server.stop() }

        let text = await HerdrSocketClient().paneVisibleText(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertNil(text)
    }

    func testPaneVisibleTextErrorEnvelopeAbstains() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                error: ["code": "pane_not_found", "message": "not found"]
            )
        }
        defer { server.stop() }

        let text = await HerdrSocketClient().paneVisibleText(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertNil(text)
    }

    func testPaneVisibleTextShortInjectedDeadlineExpiresWhenServerDoesNotReply() async throws {
        let release = DispatchSemaphore(value: 0)
        let server = try HerdrOneShotServer { _ in
            release.wait()
            return nil
        }
        defer {
            release.signal()
            server.stop()
        }

        let text = await HerdrSocketClient(timeout: 0.01).paneVisibleText(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertNil(text)
    }

    func testForegroundProcessesPresentDecodePIDs() async throws {
        let server = try HerdrOneShotServer { request in
            herdrResponse(
                for: request,
                result: [
                    "type": "pane_process_info",
                    "process_info": [
                        "pane_id": "pane-a",
                        "tty": NSNull(),
                        "foreground_processes": [
                            ["pid": 9001, "name": "claude", "argv0": "ignored"],
                            ["pid": 9002, "name": "helper"],
                        ],
                    ],
                ]
            )
        }
        defer { server.stop() }

        let info = await HerdrSocketClient().paneForegroundInfo(
            socketPath: server.socketPath, paneID: "pane-a"
        )
        XCTAssertNil(info?.shellPID)
        XCTAssertEqual(info?.foregroundPIDs, [9001, 9002])
    }
}
#endif
