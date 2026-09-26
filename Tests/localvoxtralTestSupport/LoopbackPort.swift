import Foundation
import localvoxtralCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A loopback TCP port nothing listens on: the OS picks it for a socket that
/// is closed again at once. For a listener that takes a port number, and for
/// a connection that must be refused.
///
/// Test classes run in several xctest processes at once (#442), so a fixed
/// port, or one counted up from a fixed base, can be another process's live
/// listener. Between the close here and the caller's bind, only another bind
/// to port 0 can take this one, and the OS answers those from ~16,000
/// ephemeral ports at random.
package func unusedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, POSIXSocket.stream, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(fd) }

    var address = sockaddr_in()
    POSIXSocket.setLength(of: &address)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return UInt16(bigEndian: assigned.sin_port)
}
