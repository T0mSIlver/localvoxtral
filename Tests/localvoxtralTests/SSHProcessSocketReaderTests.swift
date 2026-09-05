import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

/// The one live-kernel read in the plain-ssh join, against a real socket.
///
/// Everything else about that arm is unit-tested over injected fixtures, which
/// is right — but it means NOTHING would catch the two ways this file can be
/// silently wrong: `insi_lport`/`insi_fport` are network byte order widened
/// into an `int` (skip the swap and every port is byte-reversed, so the join
/// simply never fires), and `socket_fdinfo`'s union is read through
/// `insi_vflag` (get that wrong and the peer address is garbage). Both produce
/// a feature that compiles, passes every fixture test, and never joins.
///
/// So this makes a real loopback connection inside the test process and asks
/// the reader to describe it. No ssh, no network, no wall-clock: `connect(2)`
/// to a listening socket on this machine completes or fails immediately.
@MainActor
final class SSHProcessSocketReaderTests: XCTestCase {
    /// A listening loopback socket on an ephemeral port, and that port.
    private func makeListener() throws -> (descriptor: Int32, port: UInt16) {
        let raw = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        let listener = try XCTUnwrap(raw >= 0 ? raw : nil, "socket() failed: \(errno)")

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(errno)")
        XCTAssertEqual(Darwin.listen(listener, 1), 0, "listen failed: \(errno)")

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        XCTAssertEqual(named, 0)
        return (listener, UInt16(bigEndian: assigned.sin_port))
    }

    func testTheLiveReaderDescribesARealEstablishedSocketOfThisProcess() throws {
        let (listener, listenPort) = try makeListener()
        defer { Darwin.close(listener) }

        let rawClient = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        let client = try XCTUnwrap(rawClient >= 0 ? rawClient : nil, "socket() failed: \(errno)")
        defer { Darwin.close(client) }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = listenPort.bigEndian
        target.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: \(errno)")

        // The client's own ephemeral port, straight from the kernel — the same
        // number sshd would put into `$SSH_CONNECTION` as the client port.
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(client, $0, &length)
            }
        }
        XCTAssertEqual(named, 0)
        let clientPort = UInt16(bigEndian: local.sin_port)
        XCTAssertGreaterThan(clientPort, 0)

        let sockets = try XCTUnwrap(
            SSHProcessSocketReader.establishedTCPSockets(pid: getpid()),
            "this process's own fd table must be readable"
        )
        let match = sockets.first {
            $0.localPort == clientPort && $0.peerPort == listenPort
        }
        let described = try XCTUnwrap(
            match,
            "the reader must find the connection this test just made "
                + "(client \(clientPort) -> \(listenPort)); saw \(sockets)"
        )
        XCTAssertEqual(described.peerAddress, "127.0.0.1")

        // And the arm's comparison agrees with the report sshd would write for
        // exactly this connection — the two halves meeting on real values.
        let report = try XCTUnwrap(
            ClaudeRemoteSSHConnectionReport.parse(
                "127.0.0.1,\(clientPort),127.0.0.1,\(listenPort)"
            )
        )
        XCTAssertTrue(ClaudeSessionJoinResolver.socket(described, matches: report))

        // The accepted side of the same connection is ALSO in this process's
        // fd table, with the ports the other way round. It must not satisfy the
        // report: only the socket whose LOCAL port is the reported client port
        // does, which is what keeps the direction of the match honest.
        var acceptedAddress = sockaddr_in()
        var acceptedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &acceptedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listener, $0, &acceptedLength)
            }
        }
        XCTAssertGreaterThanOrEqual(accepted, 0, "accept failed: \(errno)")
        defer { Darwin.close(accepted) }

        let afterAccept = try XCTUnwrap(
            SSHProcessSocketReader.establishedTCPSockets(pid: getpid())
        )
        let serverSide = afterAccept.first {
            $0.localPort == listenPort && $0.peerPort == clientPort
        }
        let serverSocket = try XCTUnwrap(serverSide, "saw \(afterAccept)")
        XCTAssertFalse(
            ClaudeSessionJoinResolver.socket(serverSocket, matches: report),
            "the reversed tuple is a different connection end and must not match"
        )
    }

    func testAPidWithNoFdTableWeCanReadIsUnreadableRatherThanEmpty() {
        // pid 0 is not a process whose descriptors this user may list. The
        // reader must say "I could not read", which the arm turns into an
        // abstention — an empty list would read as "this ssh holds no
        // connection", which is a different and joinable-looking claim.
        XCTAssertNil(SSHProcessSocketReader.establishedTCPSockets(pid: 0))
    }

    func testAListeningSocketIsNotReportedAsAConnection() throws {
        // An `ssh -L` binds one. It has no peer, so it is not a connection any
        // report could name — and including it would put a zero-port entry
        // into the match set.
        let (listener, listenPort) = try makeListener()
        defer { Darwin.close(listener) }
        let sockets = try XCTUnwrap(
            SSHProcessSocketReader.establishedTCPSockets(pid: getpid())
        )
        XCTAssertFalse(
            sockets.contains { $0.localPort == listenPort && $0.peerPort == 0 },
            "a listening socket is not established: \(sockets)"
        )
    }
}
#endif
