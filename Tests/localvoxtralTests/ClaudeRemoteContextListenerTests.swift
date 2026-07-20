import ClaudeContextWire
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The listener, driven over a real loopback socket with real HTTP bytes.
///
/// A unit test over the parser proves the parser; this proves the thing that
/// actually binds a port — the ordering of auth against body reads, the caps, the
/// deadline, and the marker coming back out. The client below is deliberately a
/// raw POSIX socket rather than URLSession: half these cases are requests
/// URLSession would refuse to send.
final class ClaudeRemoteContextListenerTests: XCTestCase {
    private var listener: ClaudeRemoteContextListener!
    private var sessions: ClaudeSessionRegistry!
    private var hosts: ClaudeRemoteHostRegistry!
    private var token: String!
    private var hostID: String!
    private var port: UInt16!

    /// Each test gets its own port: a shared one would make a leaked listener
    /// from a previous test look like a failure in the next.
    private static let portCounter = Mutex<UInt16>(45_871)

    private func nextPort() -> UInt16 {
        Self.portCounter.withLock { port in
            port += 1
            return port
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sessions = ClaudeSessionRegistry(
            isProcessAlive: { _ in true },
            allocateMarkerValue: { "lvx-abcd1234" }
        )
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-listener-test/hosts.json"),
            io: EphemeralStoreIO()
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        token = enrollment.token
        hostID = enrollment.host.id
        port = nextPort()
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    /// - Parameter uptimeNanos: injected monotonic clock. Nothing here sleeps
    ///   or polls a wall clock to observe a deadline (AGENTS: no wall-clock in
    ///   tests) — a test that needs expiry advances this seam immediately.
    private func startListener(
        limits: ClaudeRemoteListenerLimits? = nil,
        uptimeNanos: (@Sendable () -> UInt64)? = nil
    ) throws {
        listener = ClaudeRemoteContextListener(
            registry: sessions,
            hosts: hosts,
            limits: limits ?? ClaudeRemoteListenerLimits(port: port),
            uptimeNanos: uptimeNanos ?? { DispatchTime.now().uptimeNanoseconds }
        )
        try listener.start()
    }

    // MARK: - Raw client

    private struct Response {
        var status: Int
        var body: String
    }

    /// Connect, write `raw` verbatim, read to EOF. No framing help, no retries.
    private func send(_ raw: Data, timeout: TimeInterval = 5) throws -> Response? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)
        )
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        _ = raw.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(fd, base.advanced(by: offset), buffer.count - offset, 0)
                if written <= 0 { return offset }
                offset += written
            }
            return offset
        }
        // Half-close: the request is complete, so a listener that goes looking
        // for more bytes gets EOF at once rather than blocking on a deadline.
        // This is what makes `testTheBodyIsNeverReadWhenAuthFails` a behavioural
        // assertion instead of a stopwatch.
        shutdown(fd, SHUT_WR)

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
        }
        guard !received.isEmpty else { return nil }
        return parse(received)
    }

    private func parse(_ raw: Data) -> Response? {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
        let body = String(decoding: raw[separator.upperBound...], as: UTF8.self)
        let statusLine = head.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        return Response(status: status, body: body)
    }

    private func hookRequest(
        event: String = "SessionStart",
        token: String?,
        payload: [String: Any] = ["session_id": "s-1", "cwd": "/srv/app"],
        contentLengthOverride: Int? = nil,
        extraHeaders: [String] = []
    ) -> Data {
        var body = try! JSONSerialization.data(withJSONObject: payload)
        var text = "POST /v1/hook/\(event) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let token { text += "Authorization: Bearer \(token)\r\n" }
        for header in extraHeaders { text += header + "\r\n" }
        text += "Content-Type: application/json\r\n"
        text += "Content-Length: \(contentLengthOverride ?? body.count)\r\n\r\n"
        if contentLengthOverride != nil { body = Data() }
        return Data(text.utf8) + body
    }

    // MARK: - Happy path

    func testAnAuthenticatedHookIsIngestedAndGetsItsMarkerBack() throws {
        try startListener()
        let response = try XCTUnwrap(try send(hookRequest(token: token)))
        XCTAssertEqual(response.status, 200)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        // The marker rides this response down the SSH PTY and into the title.
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-abcd1234\u{07}")
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
        XCTAssertTrue(
            Set(object.keys).isSubset(of: ["terminalSequence", "suppressOutput"]),
            "the response is executed by Claude Code; only these two keys may appear"
        )

        let snapshot = try XCTUnwrap(sessions.liveSessions().first)
        XCTAssertEqual(
            snapshot.sessionID,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "s-1")
        )
    }

    /// The property that makes the whole design safe.
    func testEveryAcceptedSessionIsTaggedRemoteRegardlessOfPayload() throws {
        try startListener()
        // The payload tries every way it can to claim it is local. It is being
        // delivered by a process running as this very user, over this machine's
        // own loopback — the transport itself cannot tell it apart from a local
        // one. That is exactly why the ANSWER does not come from the transport's
        // address or the payload: it comes from the fact that this listener
        // exists at all.
        _ = try send(hookRequest(token: token, payload: [
            "session_id": "s-1",
            "cwd": "/home/dev/work/service",
            "origin": "localAuthenticated",
            "trusted": true,
            "peer_uid": 501,
            "local": true,
            "transport": "unix",
        ]))

        let snapshot = try XCTUnwrap(sessions.liveSessions().first)
        XCTAssertEqual(
            snapshot.origin,
            .remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
        )
        XCTAssertFalse(snapshot.origin.isLocalAuthenticated)
        XCTAssertNil(snapshot.localWorkspacePath, "a local process here can only downgrade itself")
        XCTAssertEqual(snapshot.workspace, .remoteOpaque(label: "service"))
    }

    func testTheEventPathSuppliesTheEventWhenThePayloadOmitsIt() throws {
        try startListener()
        _ = try send(hookRequest(event: "UserPromptSubmit", token: token, payload: [
            "session_id": "s-1", "prompt": "fix the retry loop",
        ]))
        let snapshot = try XCTUnwrap(sessions.liveSessions().first)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "fix the retry loop")
        XCTAssertEqual(snapshot.activity, .working)
    }

    func testToolSnippetsSurviveTheRoundTrip() throws {
        try startListener()
        _ = try send(hookRequest(event: "PostToolUse", token: token, payload: [
            "session_id": "s-1",
            "cwd": "/srv/app",
            "tool_name": "Edit",
            "tool_input": [
                "file_path": "/srv/app/RetryPolicy.swift",
                "new_string": "maxAttempts = 5\u{1B}]2;pwned\u{07}",
            ],
        ]))
        let snapshot = try XCTUnwrap(sessions.liveSessions().first)
        XCTAssertEqual(
            snapshot.recentSnippets,
            [ClaudeContentSnippet(label: "Edit new_string", kind: .toolInput, text: "maxAttempts = 5]2;pwned")]
        )
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["/srv/app/RetryPolicy.swift"])
        XCTAssertEqual(snapshot.localRecentFiles, [], "a remote path is not a path on this machine")
    }

    // MARK: - Authentication

    func testNoTokenIsRejectedAndNothingIsIngested() throws {
        try startListener()
        let response = try XCTUnwrap(try send(hookRequest(token: nil)))
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.body, "", "a rejection must say nothing at all")
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    func testAWrongTokenIsRejected() throws {
        try startListener()
        let response = try XCTUnwrap(try send(hookRequest(token: ClaudeRemoteTokenDigest.makeToken())))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    func testARevokedTokenStopsWorkingImmediately() throws {
        try startListener()
        XCTAssertEqual(try send(hookRequest(token: token))?.status, 200)

        try hosts.revoke(hostID: hostID)
        sessions.removeAll()

        XCTAssertEqual(try send(hookRequest(token: token))?.status, 401)
        XCTAssertTrue(sessions.liveSessions().isEmpty, "revocation needs no restart to take effect")
    }

    func testARotatedTokenSwapsWhichCredentialWorks() throws {
        try startListener()
        let rotated = try hosts.rotateToken(hostID: hostID)
        XCTAssertEqual(try send(hookRequest(token: token))?.status, 401, "the old token is dead")
        XCTAssertEqual(try send(hookRequest(token: rotated.token))?.status, 200)
    }

    func testAnUninterpolatedPlaceholderIsRejectedNotHashed() throws {
        // What ships if `allowedEnvVars` is ever dropped from the manifest.
        try startListener()
        XCTAssertEqual(
            try send(hookRequest(token: "${CLAUDE_PLUGIN_OPTION_TOKEN}"))?.status,
            401
        )
    }

    /// The ordering that matters most: an unauthenticated peer never gets to
    /// hand us a body — not to parse, not to buffer, not to log.
    func testTheBodyIsNeverReadWhenAuthFails() throws {
        try startListener()
        // Declare a 4 KB body, send none of it, and half-close. The two possible
        // orderings give two different answers, which is what makes this a
        // behavioural assertion rather than a stopwatch:
        //
        //   * body first  → the read hits EOF → 400 Bad Request
        //   * auth first  → decided on the head alone → 401 Unauthorized
        let head = Data(
            "POST /v1/hook/SessionStart HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4096\r\n\r\n".utf8
        )
        let response = try XCTUnwrap(try send(head))
        XCTAssertEqual(
            response.status,
            401,
            "a 400 here would mean the body was read before the token was checked"
        )
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    // MARK: - Routing and bounds

    func testAnUnknownPathIsNotFound() throws {
        try startListener()
        var raw = hookRequest(token: token)
        raw = Data(String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "/v1/hook/SessionStart", with: "/admin").utf8)
        XCTAssertEqual(try send(raw)?.status, 404)
    }

    func testUnknownPathDoesNotRevealRoutingBeforeAuthentication() throws {
        try startListener()
        let raw = Data("POST /admin HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(try send(raw)?.status, 401)
    }

    func testNonPOSTIsRejected() throws {
        try startListener()
        let raw = Data("GET /v1/hook/SessionStart HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(try send(raw)?.status, 405)
    }

    func testAnOversizedDeclaredBodyIsRejectedBeforeItIsSent() throws {
        try startListener()
        let response = try XCTUnwrap(try send(hookRequest(
            token: token, contentLengthOverride: 10 * 1024 * 1024
        )))
        XCTAssertEqual(response.status, 413)
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    func testAnOversizedHeadIsRejected() throws {
        try startListener()
        let response = try XCTUnwrap(try send(hookRequest(
            token: token, extraHeaders: ["X-Pad: \(String(repeating: "x", count: 16 * 1024))"]
        )))
        XCTAssertEqual(response.status, 431)
    }

    func testChunkedIsRejected() throws {
        try startListener()
        let raw = Data("""
        POST /v1/hook/SessionStart HTTP/1.1\r
        Transfer-Encoding: chunked\r
        \r

        """.utf8)
        XCTAssertEqual(try send(raw)?.status, 400)
    }

    func testAMissingContentLengthIsRejected() throws {
        try startListener()
        let raw = Data("POST /v1/hook/SessionStart HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        XCTAssertEqual(try send(raw)?.status, 411)
    }

    func testAnUnparseablePayloadIsAcceptedButIngestsNothing() throws {
        // Authenticated, so we answer 200 — but there is no session to make and
        // no marker to hand back. The hook prints nothing and the turn goes on.
        try startListener()
        let body = Data("not json at all".utf8)
        var text = "POST /v1/hook/SessionStart HTTP/1.1\r\nAuthorization: Bearer \(token!)\r\n"
        text += "Content-Length: \(body.count)\r\n\r\n"
        let response = try XCTUnwrap(try send(Data(text.utf8) + body))
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        XCTAssertNil(object["terminalSequence"], "no session, no marker, nothing to write")
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    // MARK: - Deadlines

    /// A peer that connects and dribbles — the slowloris shape — must lose its
    /// slot, not hold a thread until it feels like finishing.
    ///
    /// The deadline is proven by handing the listener a clock that has already
    /// passed it, rather than by sleeping: `uptimeNanos()` answers `T` once (when the
    /// connection's deadline is computed) and `T + 100 s` forever after, so the
    /// first read finds no budget left and the connection is dropped. Same code
    /// path, no wall clock, no flake under load.
    func testAPeerThatOutlastsTheDeadlineIsDropped() throws {
        let calls = Mutex(0)
        let base: UInt64 = 1_000_000_000
        try startListener(uptimeNanos: {
            calls.withLock { count in
                count += 1
                return count == 1 ? base : base + 100_000_000_000
            }
        })

        // A complete, valid, authenticated request. It still gets nothing: by
        // the time the listener would read it, the budget is gone.
        XCTAssertNil(
            try send(hookRequest(token: token), timeout: 5),
            "the listener must hang up on a connection that has outlived its deadline"
        )
        XCTAssertTrue(sessions.liveSessions().isEmpty)
    }

    // MARK: - Lifecycle

    func testNoEnrolledHostsMeansNoOpenPort() throws {
        try hosts.revoke(hostID: hostID)
        listener = ClaudeRemoteContextListener(
            registry: sessions, hosts: hosts, limits: ClaudeRemoteListenerLimits(port: port)
        )
        XCTAssertThrowsError(try listener.start()) { error in
            XCTAssertEqual(error as? ClaudeRemoteContextListener.StartFailure, .noEnrolledHosts)
        }
        XCTAssertFalse(listener.isRunning)
        // Nothing is listening, so the tunnel's local end refuses — which is
        // exactly the fail-open case the hooks are built for.
        XCTAssertNil(try send(hookRequest(token: token)))
    }

    func testStartingTwiceIsRefused() throws {
        try startListener()
        XCTAssertThrowsError(try listener.start()) { error in
            XCTAssertEqual(error as? ClaudeRemoteContextListener.StartFailure, .alreadyRunning)
        }
    }

    func testStopClosesThePortSoAHookFailsOpen() throws {
        try startListener()
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(try send(hookRequest(token: token))?.status, 200)

        listener.stop()
        XCTAssertFalse(listener.isRunning)
        // Connection refused: the hook gets nothing, prints nothing, exits 0.
        XCTAssertNil(try send(hookRequest(token: token)), "a stopped listener must refuse, not hang")
    }

    // Loopback-only binding has no portable behavioural probe (whether a second
    // bind on 0.0.0.0 succeeds alongside 127.0.0.1 is a BSD/SO_REUSEADDR
    // question, so a test of it would assert the OS's semantics, not ours). The
    // rule is stated twice in code instead: the socket is bound to
    // INADDR_LOOPBACK explicitly, and every accepted peer's address is re-checked
    // against `ClaudeRemotePeerPolicy.isLoopbackIPv4`, which has its own tests in
    // ClaudeRemoteHTTPTests.

    // MARK: - Host isolation, end to end

    func testTwoHostsSharingASessionIDStayIsolated() throws {
        let second = try hosts.enroll(label: "otherhost")
        let counter = Mutex(0)
        sessions = ClaudeSessionRegistry(
            isProcessAlive: { _ in true },
            allocateMarkerValue: {
                counter.withLock { value in
                    value += 1
                    return "lvx-0000000\(value)"
                }
            }
        )
        try startListener()

        // Both hosts report the same Claude session id.
        _ = try send(hookRequest(token: token, payload: ["session_id": "same-id", "cwd": "/srv/alpha"]))
        _ = try send(hookRequest(token: second.token, payload: ["session_id": "same-id", "cwd": "/srv/beta"]))

        let live = sessions.liveSessions()
        XCTAssertEqual(live.count, 2, "one session per host, never one shared by both")
        XCTAssertEqual(
            Set(live.map(\.sessionID)),
            [
                ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: "same-id"),
                ClaudeRemoteSessionScope.scopedSessionID(hostID: second.host.id, sessionID: "same-id"),
            ]
        )
        XCTAssertEqual(Set(live.map(\.marker.value)).count, 2, "and never one shared marker")
        XCTAssertEqual(Set(live.compactMap(\.workspace)), [
            .remoteOpaque(label: "alpha"), .remoteOpaque(label: "beta"),
        ])
    }

    func testOneHostCannotForgeAnothersScopedSessionID() throws {
        let second = try hosts.enroll(label: "otherhost")
        try startListener()
        let victim = ClaudeRemoteSessionScope.scopedSessionID(hostID: second.host.id, sessionID: "victim")

        _ = try send(hookRequest(token: second.token, payload: [
            "session_id": "victim", "cwd": "/srv/real",
        ]))
        // Host A spells host B's scoped id verbatim. It gets scoped again under
        // A, so it lands in A's namespace and touches nothing of B's.
        _ = try send(hookRequest(token: token, payload: [
            "session_id": victim, "cwd": "/srv/forged",
        ]))

        XCTAssertEqual(sessions.snapshot(sessionID: victim)?.workspace, .remoteOpaque(label: "real"))
        XCTAssertEqual(
            sessions.snapshot(
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: victim)
            )?.workspace,
            .remoteOpaque(label: "forged")
        )
    }
}

/// The host store, in memory. This suite is about the listener; a real file
/// would only add a cleanup step that could fail for unrelated reasons.
private final class EphemeralStoreIO: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<Data?>(nil)

    func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
}
