import Foundation
import XCTest
@testable import localvoxtralCore

#if canImport(Darwin) || canImport(Glibc)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class POSIXPortabilityTests: XCTestCase {
    /// A send to a peer that has gone must fail with EPIPE, not raise
    /// SIGPIPE: the signal would end the test process, as it would the app.
    func testSendToAClosedPeerFailsWithEPIPEInsteadOfSignalling() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, POSIXSocket.stream, 0, &descriptors), 0)
        defer { close(descriptors[0]) }
        POSIXSocket.suppressSIGPIPE(onSocket: descriptors[0])
        close(descriptors[1])

        let byte: [UInt8] = [0x2A]
        let written = byte.withUnsafeBytes { raw in
            LibC.send(descriptors[0], raw.baseAddress!, raw.count, POSIXSocket.sendFlags)
        }
        XCTAssertEqual(written, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testConnectReachesAListenerBoundThroughTheHelpers() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("posix-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }

        func address() -> sockaddr_un {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                let bytes = Array(path.utf8)
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            POSIXSocket.setLength(of: &address)
            return address
        }

        let listener = socket(AF_UNIX, POSIXSocket.stream, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var listenAddress = address()
        let bound = withUnsafePointer(to: &listenAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified: XCTestCase inherits NSObject's `bind`.
                #if canImport(Darwin)
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)

        let client = socket(AF_UNIX, POSIXSocket.stream, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var connectAddress = address()
        let connected = withUnsafePointer(to: &connectAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                LibC.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
    }
}
#endif
