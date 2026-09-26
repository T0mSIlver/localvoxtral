import Foundation
import localvoxtralCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wakes a fixture thread blocked in `accept()` on the AF_UNIX listener at
/// `path`, by connecting to it and closing at once.
///
/// `shutdown()` on a listening socket does not return a blocked `accept()` on
/// macOS, so a fixture no client ever dialed (the refusal cases) waited out its
/// whole cleanup bound on every `stop()`. The serve loop sees this connection
/// as a peer that sent nothing: it reads EOF and returns without recording a
/// request. A listener that is already gone refuses the connect, which is fine.
package func wakeBlockedUnixListener(atPath path: String) {
    let descriptor = socket(AF_UNIX, POSIXSocket.stream, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    POSIXSocket.setLength(of: &address)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            LibC.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
