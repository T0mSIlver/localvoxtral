#if LOCALVOXTRAL_DOGFOOD

import Darwin
import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// The socket itself: a real bind, a real connect, real peer credentials.
///
/// Every assertion here is about the transport — permissions, credentials,
/// framing, lifetime. What the app says back is `DogfoodControlServiceTests`.
final class DogfoodControlSocketTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Under /tmp, not the test bundle's temporary directory: `sun_path` is
        // 104 bytes on Darwin and xctest's /var/folders/… prefix alone spends
        // most of that, so a socket there fails to bind for a reason that has
        // nothing to do with what is being tested.
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("lvxctl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        socketPath = directory.appendingPathComponent("control.sock").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Round trip

    func testOneLineInOneLineOut() throws {
        let socket = makeSocket { line in "echo:\(line)" }
        try socket.start()
        defer { socket.stop() }

        XCTAssertEqual(try request("join report"), "echo:join report")
    }

    /// A client that writes without a trailing newline and closes its write end
    /// still gets an answer — `printf 'join report' | nc -U …` is the shape an
    /// operator actually types.
    func testARequestTerminatedByEOFIsStillAnswered() throws {
        let socket = makeSocket { line in "echo:\(line)" }
        try socket.start()
        defer { socket.stop() }

        XCTAssertEqual(try request("registry list", terminator: "", halfClose: true), "echo:registry list")
    }

    func testATrailingCarriageReturnIsNotPartOfTheCommand() throws {
        let socket = makeSocket { line in "echo:\(line)" }
        try socket.start()
        defer { socket.stop() }

        XCTAssertEqual(try request("join report", terminator: "\r\n"), "echo:join report")
    }

    func testAnOversizedRequestIsRefusedWithoutReachingTheHandler() throws {
        let reached = Mutex(false)
        let socket = makeSocket { _ in
            reached.withLock { $0 = true }
            return "handled"
        }
        try socket.start()
        defer { socket.stop() }

        let reply = try request(String(repeating: "j", count: 4_096))

        XCTAssertTrue(reply.contains("request exceeds the byte cap"))
        XCTAssertFalse(reached.withLock { $0 }, "an oversized line must never reach the app")
    }

    // MARK: - Permissions and credentials

    func testTheSocketFileIsPrivateToItsOwner() throws {
        let socket = makeSocket { _ in "ok" }
        try socket.start()
        defer { socket.stop() }

        let metadata = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: socketPath))
        XCTAssertTrue(metadata.isSocket)
        XCTAssertEqual(metadata.mode & 0o777, 0o600, "the socket must not be reachable by anyone else")

        let directoryMetadata = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: directory.path))
        XCTAssertEqual(directoryMetadata.mode & 0o077, 0, "the directory must be 0700")
    }

    func testStartRefusesAGroupWritableDirectory() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o770))],
            ofItemAtPath: directory.path
        )
        let socket = makeSocket { _ in "ok" }

        XCTAssertThrowsError(try socket.start()) { error in
            guard case ClaudeSocketGuard.PreconditionFailure.permissive = error else {
                return XCTFail("expected a permissions refusal, got \(error)")
            }
        }
        XCTAssertFalse(socket.isRunning)
    }

    /// The permissions above should already make this unreachable. It is
    /// checked anyway, before a single byte is read, because this is the
    /// surface the owner accepted on a recommendation — and because "the
    /// directory should stop them" is a claim about the filesystem, not about
    /// this process.
    func testAConnectionFromAnotherUIDIsClosedWithoutBeingRead() throws {
        let reached = Mutex(false)
        let socket = makeSocket(
            handler: { _ in
                reached.withLock { $0 = true }
                return "handled"
            },
            // The kernel's answer, replaced by a uid that is not ours.
            peerUID: { _ in UInt32(geteuid()) &+ 1 }
        )
        try socket.start()
        defer { socket.stop() }

        let reply = try? request("join report")

        XCTAssertNil(reply, "a foreign peer must receive nothing at all")
        XCTAssertFalse(reached.withLock { $0 }, "a foreign peer must not reach the app")
    }

    func testAPeerWhoseCredentialsCannotBeReadIsRejected() throws {
        let reached = Mutex(false)
        let socket = makeSocket(
            handler: { _ in
                reached.withLock { $0 = true }
                return "handled"
            },
            peerUID: { _ in nil }
        )
        try socket.start()
        defer { socket.stop() }

        XCTAssertNil(try? request("join report"))
        XCTAssertFalse(reached.withLock { $0 })
    }

    func testTheOwnUIDIsAccepted() throws {
        let socket = makeSocket(
            handler: { _ in "ok" },
            peerUID: { _ in UInt32(geteuid()) }
        )
        try socket.start()
        defer { socket.stop() }

        XCTAssertEqual(try request("join report"), "ok")
    }

    // MARK: - Lifetime

    func testStopUnlinksTheSocketSoNoListenerOutlivesTheProcess() throws {
        let socket = makeSocket { _ in "ok" }
        try socket.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        socket.stop()

        XCTAssertFalse(socket.isRunning)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "stop() must not return before the accept loop unlinked the socket"
        )
    }

    /// A crash leaves the socket file behind. The next launch must replace it
    /// rather than refuse forever — the corpse refuses connections, which is
    /// exactly how it is told apart from a live second instance.
    func testAStaleSocketFromACrashedRunIsReplaced() throws {
        let first = makeSocket { _ in "first" }
        try first.start()
        // Leak the file the way a SIGKILL would: copy the inode aside, stop the
        // owner, put it back.
        let stale = directory.appendingPathComponent("stale.sock").path
        XCTAssertEqual(rename(socketPath, stale), 0)
        first.stop()
        XCTAssertEqual(rename(stale, socketPath), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let second = makeSocket { _ in "second" }
        try second.start()
        defer { second.stop() }

        XCTAssertEqual(try request("join report"), "second")
    }

    func testASecondListenerOnALiveSocketIsRefusedRatherThanStealingIt() throws {
        let first = makeSocket { _ in "first" }
        try first.start()
        defer { first.stop() }

        let second = makeSocket { _ in "second" }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(
                error as? DogfoodControlSocket.StartFailure,
                .socketOwnedByLiveInstance
            )
        }
        XCTAssertEqual(
            try request("join report"), "first",
            "the live instance must keep its socket"
        )
    }

    func testStartingTwiceOnOneInstanceIsRefused() throws {
        let socket = makeSocket { _ in "ok" }
        try socket.start()
        defer { socket.stop() }

        XCTAssertThrowsError(try socket.start()) { error in
            XCTAssertEqual(error as? DogfoodControlSocket.StartFailure, .alreadyRunning)
        }
    }

    // MARK: - Helpers

    private func makeSocket(
        handler: @escaping DogfoodControlSocket.Handler,
        peerUID: (@Sendable (Int32) -> UInt32?)? = nil
    ) -> DogfoodControlSocket {
        if let peerUID {
            return DogfoodControlSocket(
                socketPath: socketPath,
                handler: handler,
                peerUID: peerUID,
                readTimeoutMillis: 2_000
            )
        }
        return DogfoodControlSocket(
            socketPath: socketPath,
            handler: handler,
            readTimeoutMillis: 2_000
        )
    }

    /// Connect, write, read to EOF. Returns nil when the server closed without
    /// answering, which is what a rejected peer must see.
    private func request(
        _ line: String,
        terminator: String = "\n",
        halfClose: Bool = false
    ) throws -> String {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectFailed(errno) }

        var payload = Array((line + terminator).utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        if halfClose { shutdown(fd, SHUT_WR) }

        // Bounded by the socket's own read timeout plus slack; a hung server
        // fails the test rather than hanging the suite.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var received = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
            if received.contains(0x0A) { break }
        }
        guard !received.isEmpty else { throw ClientError.noReply }
        return String(decoding: received, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    private enum ClientError: Error {
        case connectFailed(Int32)
        case noReply
    }
}

#endif
