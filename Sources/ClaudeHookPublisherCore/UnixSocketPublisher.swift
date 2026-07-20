import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reasons a publish did not happen. Every one of them is a normal, silent,
/// exit-0 outcome for a hook — none is worth a word on stdout/stderr.
public enum ClaudeHookPublishFailure: Error, Equatable {
    /// No socket path could be resolved (no $HOME, no override).
    case noSocketPath
    /// Path too long for `sockaddr_un.sun_path`.
    case socketPathTooLong
    /// Nothing is listening — the overwhelmingly common case: app not running.
    case notListening
    /// Connect/write did not finish inside the deadline.
    case timedOut
    /// socket()/setsockopt() failed.
    case socketUnavailable
    /// The peer went away mid-write.
    case writeFailed
    /// The record could not be encoded within the wire limits.
    case notEncodable
}

/// Writes one NDJSON line to an AF_UNIX stream socket, under a hard deadline,
/// and gives up quietly on anything unexpected.
///
/// Everything here is raw POSIX on purpose:
///
/// * `FileHandle.availableData` is banned repo-wide — it raises an uncatchable
///   ObjC exception on descriptor errors and aborts the process (field crash,
///   PR #60). A hook that crashes is a hook that breaks the user's Claude turn.
/// * `Network.framework` cannot do peer-credential authentication on a local
///   socket, which is the entire security model of the broker side. Using it
///   here too keeps both ends on one honest transport.
public struct UnixSocketPublisher: Sendable {
    /// Wall-clock ceiling for connect + write, combined. Deliberately tiny:
    /// this runs inline in a Claude Code hook, and being late is worse than
    /// being absent.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 0.25) {
        self.timeout = timeout
    }

    /// Publish a line and read the broker's reply.
    ///
    /// - Returns: the reply line on success, or a failure. A nil reply with no
    ///   failure means the broker accepted the record but said nothing.
    public func publishAndReadReply(
        line: Data,
        to socketPath: String
    ) -> Result<Data?, ClaudeHookPublishFailure> {
        guard !socketPath.isEmpty else { return .failure(.noSocketPath) }
        switch openConnection(to: socketPath) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let fd):
            defer { close(fd) }
            if let failure = writeAll(fd: fd, data: line) { return .failure(failure) }
            // Half-close so the broker sees EOF and stops waiting for more
            // records; it can still write its reply back to us.
            shutdown(fd, SHUT_WR)
            return .success(readReply(fd: fd))
        }
    }

    public func publish(line: Data, to socketPath: String) -> ClaudeHookPublishFailure? {
        switch publishAndReadReply(line: line, to: socketPath) {
        case .failure(let failure): return failure
        case .success: return nil
        }
    }

    /// Connect with a bounded, non-blocking handshake.
    ///
    /// A blocking `connect()` on AF_UNIX is NOT covered by `SO_SNDTIMEO` — that
    /// option applies to sends on an established socket. So a broker that has
    /// bound and listened but is not accepting (wedged, paused, backlog full)
    /// would park this hook indefinitely, and a hook that hangs stalls the
    /// user's Claude turn. O_NONBLOCK + poll is the only way to actually honour
    /// the deadline we promise.
    /// Named `openConnection`, not `connect`: a member named `connect` shadows
    /// the C `connect(2)` for unqualified lookup inside this type, and
    /// qualifying it as `Darwin.connect` would not compile on the Glibc arm.
    private func openConnection(to socketPath: String) -> Result<Int32, ClaudeHookPublishFailure> {
        guard !socketPath.isEmpty else { return .failure(.noSocketPath) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path must hold the path AND a NUL terminator.
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return .failure(.socketPathTooLong) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        // O_NONBLOCK via fcntl rather than a SOCK_NONBLOCK socket type: that
        // flag is a Linux extension and does not exist on Darwin.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socketUnavailable) }

        configureNoSIGPIPE(fd)
        makeNonBlocking(fd)
        setDeadline(fd)

        // NOTE: connect() is NOT wrapped in a retry-on-EINTR loop, and that is
        // deliberate. POSIX says a connect() interrupted by a signal continues
        // asynchronously; calling it again returns EALREADY (or, on some
        // systems, EADDRINUSE) rather than re-attempting. The correct recovery
        // from EINTR here is identical to EINPROGRESS: wait for writability.
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .success(fd) } // Connected immediately — the common case.

        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EINTR else {
            close(fd)
            switch connectErrno {
            // App not running, socket stale, nobody accepting. All routine.
            case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE:
                return .failure(.notListening)
            case ETIMEDOUT, EAGAIN:
                return .failure(.timedOut)
            default:
                return .failure(.notListening)
            }
        }

        switch waitForWritable(fd: fd) {
        case .some(let failure):
            close(fd)
            return .failure(failure)
        case .none:
            return .success(fd)
        }
    }

    /// Poll until the connect completes, the deadline expires, or it fails.
    ///
    /// The poll timeout is recomputed from a monotonic deadline on every EINTR:
    /// restarting a fixed timeout after each signal would let a stream of them
    /// extend the wait without bound, which is the bug the deadline exists to
    /// prevent.
    private func waitForWritable(fd: Int32) -> ClaudeHookPublishFailure? {
        let deadline = monotonicNow() + timeout
        while true {
            let remaining = deadline - monotonicNow()
            if remaining <= 0 { return .timedOut }

            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue } // Recompute `remaining`, do not restart it.
                return .writeFailed
            }
            if ready == 0 { return .timedOut }

            // Writable does NOT mean connected: a failed connect also reports
            // ready. SO_ERROR is the only way to tell them apart.
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                return .writeFailed
            }
            switch socketError {
            case 0:
                return nil
            case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE:
                return .notListening
            case ETIMEDOUT:
                return .timedOut
            default:
                return .notListening
            }
        }
    }

    /// Read the broker's reply, bounded by the same deadline.
    ///
    /// Returns nil for absolutely everything unexpected. A missing or malformed
    /// reply is not an error worth surfacing: the record was already delivered,
    /// and the only consequence is that we emit no marker.
    private func readReply(fd: Int32) -> Data? {
        let deadline = monotonicNow() + timeout
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4 * 1024)

        while buffer.count <= maxReplyBytes {
            let remaining = deadline - monotonicNow()
            if remaining <= 0 { return nil }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }

            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break } // EOF.
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<newline])
            }
        }
        return nil
    }

    /// A reply is one small JSON object; anything larger is not ours.
    private var maxReplyBytes: Int { 4 * 1024 }

    private func makeNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Monotonic seconds. Never `Date()`: a wall-clock jump (NTP, DST, the user
    /// changing the clock) must not extend or collapse a socket deadline.
    private func monotonicNow() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// Loop until every byte is gone. A stream socket is free to accept a
    /// prefix; treating a short write as success would silently truncate the
    /// record into an unparseable line at the broker.
    ///
    /// The socket is non-blocking, so EAGAIN here means "the buffer is full
    /// right now", NOT "give up" — it is the normal way a large record meets a
    /// full socket buffer. Wait for writability (bounded by the deadline) and
    /// carry on; only a real error or the deadline ends the loop.
    private func writeAll(fd: Int32, data: Data) -> ClaudeHookPublishFailure? {
        let deadline = monotonicNow() + timeout
        var offset = 0
        return data.withUnsafeBytes { raw -> ClaudeHookPublishFailure? in
            guard let base = raw.baseAddress else { return .writeFailed }
            while offset < raw.count {
                let written = send(fd, base.advanced(by: offset), raw.count - offset, sendFlags)
                if written > 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    let remaining = deadline - monotonicNow()
                    if remaining <= 0 { return .timedOut }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, Int32(remaining * 1000))
                    if ready == 0 { return .timedOut }
                    if ready < 0 && errno != EINTR { return .writeFailed }
                    continue
                default:
                    return .writeFailed
                }
            }
            return nil
        }
    }

    private var sendFlags: Int32 {
        #if canImport(Darwin)
        return 0 // SO_NOSIGPIPE is set on the socket instead.
        #else
        return Int32(MSG_NOSIGNAL)
        #endif
    }

    /// Never let a dead peer kill this process with SIGPIPE. On Darwin the
    /// socket option is the reliable form; on Linux we pass MSG_NOSIGNAL per
    /// send and additionally ignore the signal as a belt-and-braces default.
    private func configureNoSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    private func setDeadline(_ fd: Int32) {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Self.microsecondsRemainder(timeout)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// `timeval.tv_usec` is `__darwin_suseconds_t` (Int32) on Darwin but
    /// `__suseconds_t` (Int) on Glibc, so the return type must follow the
    /// platform or the Linux publisher build — the whole point of keeping this
    /// target dependency-free — fails to compile.
    #if canImport(Darwin)
    static func microsecondsRemainder(_ timeout: TimeInterval) -> Int32 {
        Int32(fractionalMicroseconds(timeout))
    }
    #else
    static func microsecondsRemainder(_ timeout: TimeInterval) -> Int {
        Int(fractionalMicroseconds(timeout))
    }
    #endif

    private static func fractionalMicroseconds(_ timeout: TimeInterval) -> Double {
        (timeout - Double(Int(timeout))) * 1_000_000
    }
}

/// Retry a syscall interrupted by a signal. Without this, an unlucky SIGCHLD
/// turns a healthy publish into a spurious failure.
@inline(__always)
func retryingOnEINTR<T: BinaryInteger>(_ body: () -> T) -> T {
    while true {
        let result = body()
        if result == -1 && errno == EINTR { continue }
        return result
    }
}
