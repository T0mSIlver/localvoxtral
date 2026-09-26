import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
/// The C library by name, for call sites inside types that declare their own
/// `read`, `send` or `connect`, where an unqualified call would resolve to the
/// method. `Darwin.x` does the same job on Apple platforms only.
package enum LibC {
    package static func connect(
        _ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, address, length)
        #else
        Glibc.connect(fd, address, length)
        #endif
    }

    package static func send(
        _ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, _ flags: Int32
    ) -> Int {
        #if canImport(Darwin)
        Darwin.send(fd, buffer, count, flags)
        #else
        Glibc.send(fd, buffer, count, flags)
        #endif
    }

    package static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }

    package static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }

    package static func poll(
        _ descriptors: UnsafeMutablePointer<pollfd>, _ count: nfds_t, _ timeout: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        Darwin.poll(descriptors, count, timeout)
        #else
        Glibc.poll(descriptors, count, timeout)
        #endif
    }

    package static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.kill(pid, signal)
        #else
        Glibc.kill(pid, signal)
        #endif
    }
}

/// Where Darwin and Glibc spell AF_UNIX socket code differently.
package enum POSIXSocket {
    /// `SOCK_STREAM`, which Glibc imports as an enum case.
    package static var stream: Int32 {
        #if canImport(Darwin)
        SOCK_STREAM
        #else
        Int32(SOCK_STREAM.rawValue)
        #endif
    }

    /// Flags for every `send`. Darwin suppresses SIGPIPE per socket
    /// (`suppressSIGPIPE(onSocket:)`); Linux has no such option and takes
    /// `MSG_NOSIGNAL` per call instead.
    package static var sendFlags: Int32 {
        #if canImport(Darwin)
        0
        #else
        Int32(MSG_NOSIGNAL)
        #endif
    }

    /// Sets `sun_len`, which only the BSD layout has.
    package static func setLength(of address: inout sockaddr_un) {
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
    }

    /// Sets `sin_len`, likewise.
    package static func setLength(of address: inout sockaddr_in) {
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
    }

    /// `SO_NOSIGPIPE` on Darwin. A no-op on Linux, where sends pass
    /// `sendFlags` instead.
    package static func suppressSIGPIPE(onSocket fd: Int32) {
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// `F_SETNOSIGPIPE` on Darwin. Linux has no per-descriptor equivalent for
    /// a pipe, so there a write to a pipe whose reader is gone raises SIGPIPE
    /// unless the process ignores it.
    package static func suppressSIGPIPE(onPipe fd: Int32) {
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #endif
    }
}
#endif
