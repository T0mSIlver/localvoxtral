import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

public struct ClaudeBrokerLimits: Sendable, Equatable {
    /// Concurrent connections we will service. Hook publishers connect, write
    /// one line, and leave, so this only needs to absorb bursts.
    public var maxConcurrentConnections: Int
    /// listen(2) backlog.
    public var backlog: Int32
    /// Per-connection read deadline. A peer that connects and says nothing must
    /// not hold a slot.
    public var readTimeout: TimeInterval
    /// Records accepted from one connection before we close it. A publisher
    /// sends exactly one; more than a handful means something is wrong.
    public var maxRecordsPerConnection: Int
    public var wire: ClaudeHookLimits

    public init(
        maxConcurrentConnections: Int = 8,
        backlog: Int32 = 16,
        readTimeout: TimeInterval = 2.0,
        maxRecordsPerConnection: Int = 8,
        wire: ClaudeHookLimits = .default
    ) {
        self.maxConcurrentConnections = maxConcurrentConnections
        self.backlog = backlog
        self.readTimeout = readTimeout
        self.maxRecordsPerConnection = maxRecordsPerConnection
        self.wire = wire
    }

    public static let `default` = ClaudeBrokerLimits()
}

#if canImport(Darwin)

/// Raw AF_UNIX ingest for Claude Code hook records.
///
/// Design constraints, all load-bearing:
///
/// * **Raw POSIX sockets, not `Network.framework`.** NWListener cannot expose
///   peer credentials for a local UNIX socket, and peer-UID verification is the
///   whole authentication story here. There is no substitute.
/// * **No `FileHandle.availableData`.** Banned repo-wide: it throws an
///   uncatchable ObjC exception on descriptor errors and takes the app with it
///   (field crash, PR #60).
/// * **Trust from transport only.** The broker labels each record's origin from
///   `getpeereid`, and the record has no origin field to argue with.
///
/// Threading: one accept thread, one short-lived thread per connection, and a
/// `Mutex` for state — matching the repo's "no custom actors" convention.
public final class ClaudeContextBroker: Sendable {
    private struct State {
        var isRunning = false
        var activeConnections = 0
        /// Write end of the self-pipe that wakes a blocked accept loop.
        var wakeWriteFD: Int32 = -1
    }

    private let state = Mutex(State())
    private let socketPath: String
    private let registry: ClaudeSessionRegistry
    private let limits: ClaudeBrokerLimits

    #if DEBUG
    /// Test seam: fires after each record is accepted or rejected, so a socket
    /// integration test can await a deterministic signal instead of polling the
    /// registry on a wall clock (AGENTS: no wall-clock in tests). Never used in
    /// production paths.
    private let debugIngestHook = Mutex<(@Sendable (Result<ClaudeHookRecord, ClaudeHookWireError>) -> Void)?>(nil)

    public func debugConfigureIngestHook(
        _ hook: (@Sendable (Result<ClaudeHookRecord, ClaudeHookWireError>) -> Void)?
    ) {
        debugIngestHook.withLock { $0 = hook }
    }

    private func debugNotify(_ result: Result<ClaudeHookRecord, ClaudeHookWireError>) {
        let hook = debugIngestHook.withLock { $0 }
        hook?(result)
    }
    #endif

    public init(
        socketPath: String,
        registry: ClaudeSessionRegistry,
        limits: ClaudeBrokerLimits = .default
    ) {
        self.socketPath = socketPath
        self.registry = registry
        self.limits = limits
    }

    public enum StartFailure: Error, Equatable {
        case pathTooLong(String)
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case alreadyRunning
    }

    public var socketURL: URL { URL(fileURLWithPath: socketPath) }

    /// Bind, secure, and start accepting. Every failure is reported, never
    /// swallowed — a silent failure path here is exactly how the ensureReady
    /// bug cost an hour of remote probing (AGENTS: keep new paths loud).
    public func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try ClaudeSocketGuard.prepareDirectory(at: directory)

        let (listenerFD, wakeReadFD): (Int32, Int32) = try state.withLock { state in
            guard !state.isRunning else { throw StartFailure.alreadyRunning }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count < capacity else { throw StartFailure.pathTooLong(socketPath) }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: pathBytes)
                raw[pathBytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StartFailure.socketCreationFailed(errno: errno) }

            // A stale socket from a crashed run would make bind fail with
            // EADDRINUSE. Removing it is safe: the directory is verified ours
            // and private, so nothing else can have legitimately put a file here.
            unlink(socketPath)

            // Bind under a restrictive umask so the socket is never briefly
            // world-reachable between bind() and chmod().
            let previousMask = umask(0o177)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(previousMask)
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw StartFailure.bindFailed(errno: code)
            }
            // Belt and braces: umask should have produced 0600 already, but
            // macOS has historically been inconsistent about umask on AF_UNIX
            // binds, and this is cheap.
            chmod(socketPath, 0o600)

            guard listen(fd, limits.backlog) == 0 else {
                let code = errno
                close(fd)
                unlink(socketPath)
                throw StartFailure.listenFailed(errno: code)
            }

            // Self-pipe: the only reliable way to wake a blocked accept loop.
            // shutdown() on a LISTENING socket is not specified to return a
            // blocked accept() on Darwin, and closing the fd underneath the
            // loop is a use-after-close race — the accept thread could be about
            // to call accept() on a number the kernel has already recycled to
            // some other part of the app. Polling both the listener and this
            // pipe means stop() just writes a byte and the loop leaves on its
            // own terms.
            var wakePipe: [Int32] = [-1, -1]
            guard pipe(&wakePipe) == 0 else {
                let code = errno
                close(fd)
                unlink(socketPath)
                throw StartFailure.socketCreationFailed(errno: code)
            }
            // stop() writes to this pipe; the accept loop's defer closes the
            // read end. Without NOSIGPIPE a stop() racing a loop that already
            // exited would kill the whole app with SIGPIPE.
            _ = fcntl(wakePipe[1], F_SETNOSIGPIPE, 1)
            state.wakeWriteFD = wakePipe[1]
            state.isRunning = true
            return (fd, wakePipe[0])
        }

        // Started OUTSIDE the lock: the accept loop's first act is to read
        // `isRunning`, and this mutex is not reentrant. Spawning it while still
        // holding the lock would park the new thread until start() returned —
        // harmless today, but exactly the kind of ordering that becomes a
        // deadlock the moment someone adds a join or a synchronous handshake.
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, wakeReadFD: wakeReadFD)
        }
        thread.name = "com.localvoxtral.claude-broker"
        thread.stackSize = 512 * 1024
        thread.start()

        Log.claudeContext.info("Claude context broker listening")
    }

    /// Stop accepting and remove the socket.
    ///
    /// The listener fd is NOT closed here — the accept loop owns it and closes
    /// it on its way out once the wake byte tells it to leave. Closing it from
    /// this thread would race the loop's next accept().
    public func stop() {
        let wakeFD: Int32 = state.withLock { state in
            guard state.isRunning else { return -1 }
            state.isRunning = false
            let wakeFD = state.wakeWriteFD
            state.wakeWriteFD = -1
            return wakeFD
        }
        guard wakeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = retryingOnEINTRInt { write(wakeFD, &byte, 1) }
        close(wakeFD)
        unlink(socketPath)
        Log.claudeContext.info("Claude context broker stopped")
    }

    public var isRunning: Bool { state.withLock { $0.isRunning } }

    // MARK: - Accept

    private func acceptLoop(listenerFD: Int32, wakeReadFD: Int32) {
        defer {
            // Clear `isRunning` on EVERY exit, not just a stop() request. The
            // loop can also leave on a failed poll or a dead listener, and a
            // broker that reports `isRunning == true` with no loop behind it
            // rejects start() forever — and worse, lets stop() write to a wake
            // pipe whose read end this defer just closed.
            state.withLock { $0.isRunning = false }
            close(listenerFD)
            close(wakeReadFD)
        }
        /// Consecutive accept() failures we could not attribute. Used only to
        /// stop a hard-failing listener from becoming a hot loop.
        var stickyErrors = 0

        while state.withLock({ $0.isRunning }) {
            var fds = [
                pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = retryingOnEINTRInt32 { poll(&fds, 2, -1) }
            if ready < 0 {
                Log.claudeContext.error("Accept loop poll failed (\(errno, privacy: .public)); stopping")
                return
            }
            // Wake byte, or the pipe's write end closed: either way, leave.
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else {
                if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    Log.claudeContext.error("Listener socket failed; stopping accept loop")
                    return
                }
                continue
            }

            let fd = retryingOnEINTRInt32 { accept(listenerFD, nil, nil) }
            guard fd >= 0 else {
                let code = errno
                switch code {
                case EAGAIN, EWOULDBLOCK, ECONNABORTED:
                    // The peer left between poll() and accept(). Routine.
                    continue
                case EMFILE, ENFILE:
                    // Out of descriptors. poll() will keep reporting the same
                    // pending connection immediately, so retrying in a tight
                    // loop burns a core until the process-wide fd pressure
                    // clears. Yield instead of spinning.
                    Log.claudeContext.error("Accept hit the descriptor limit; backing off")
                    usleep(100_000)
                    continue
                default:
                    // An error we do not understand and that poll() will very
                    // likely report again on the next iteration — the exact
                    // shape of a 100%-CPU spin. Two in a row and we stop.
                    stickyErrors += 1
                    Log.claudeContext.error(
                        "Accept failed (\(code, privacy: .public)); sticky=\(stickyErrors, privacy: .public)"
                    )
                    if stickyErrors >= 2 {
                        Log.claudeContext.error("Accept loop stopping on repeated errors")
                        return
                    }
                    continue
                }
            }
            stickyErrors = 0
            let admitted = state.withLock { state -> Bool in
                guard state.isRunning, state.activeConnections < limits.maxConcurrentConnections else {
                    return false
                }
                state.activeConnections += 1
                return true
            }
            guard admitted else {
                // Over the cap: drop immediately. The publisher fails open and
                // the user loses one context update — the correct trade against
                // unbounded thread growth.
                close(fd)
                continue
            }
            let thread = Thread { [weak self] in
                guard let self else {
                    close(fd)
                    return
                }
                self.serve(connectionFD: fd)
                self.state.withLock { $0.activeConnections -= 1 }
            }
            thread.name = "com.localvoxtral.claude-broker.conn"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func serve(connectionFD fd: Int32) {
        defer { close(fd) }

        // Authenticate BEFORE reading a single byte.
        guard let peerUID = ClaudeSocketGuard.peerUID(ofDescriptor: fd) else {
            Log.claudeContext.error("Rejected connection: peer credentials unavailable")
            return
        }
        guard peerUID == UInt32(geteuid()) else {
            Log.claudeContext.error("Rejected connection from foreign uid \(peerUID, privacy: .public)")
            return
        }
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: peerUID)

        var timeout = timeval(
            tv_sec: Int(limits.readTimeout),
            tv_usec: Int32((limits.readTimeout - Double(Int(limits.readTimeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var pending = Data()
        var recordCount = 0
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            let count = retryingOnEINTRInt { read(fd, &chunk, chunk.count) }
            if count <= 0 { break } // EOF, timeout, or error — all mean "done".
            pending.append(contentsOf: chunk[0..<count])

            // Split FIRST, then bound only what is left over. The cap is on a
            // single LINE, not on how much a peer may send: a publisher is free
            // to deliver several complete records in one chunk, and checking
            // the pre-split buffer would drop that connection for the crime of
            // being efficient. What must stay bounded is an unterminated line —
            // i.e. the remainder.
            let (lines, remainder) = ClaudeHookWireCodec.splitLines(pending)
            pending = remainder
            if pending.count > limits.wire.maxLineBytes {
                Log.claudeContext.error("Dropping connection: unterminated line over cap")
                return
            }

            for line in lines where !line.isEmpty {
                recordCount += 1
                if recordCount > limits.maxRecordsPerConnection {
                    Log.claudeContext.error("Dropping connection: too many records")
                    return
                }
                reply(to: fd, marker: handle(line: line, origin: origin))
            }
        }
    }

    /// Send the session's marker back to the publisher.
    ///
    /// This is the focus join's outbound half: the publisher turns the marker
    /// into a terminal title sequence, so the app can later ask "which session
    /// owns the focused window?" and get an answer instead of a guess.
    ///
    /// Best-effort by design — a publisher that has already exited is normal,
    /// not an error.
    private func reply(to fd: Int32, marker: ClaudeSessionMarker?) {
        guard let line = ClaudeBrokerResponse.encodeLine(
            ClaudeBrokerResponse(marker: marker?.value)
        ) else { return }
        _ = line.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let written = retryingOnEINTRInt {
                    send(fd, base.advanced(by: offset), raw.count - offset, 0)
                }
                if written <= 0 { return offset } // Peer gone: nothing to do.
                offset += written
            }
            return offset
        }
    }

    /// - Returns: the marker for the session this record belongs to, or nil if
    ///   the record was rejected.
    @discardableResult
    private func handle(line: Data, origin: ClaudeTransportOrigin) -> ClaudeSessionMarker? {
        do {
            let record = try ClaudeHookWireCodec.decodeLine(line, limits: limits.wire)
            let snapshot = registry.ingest(record, origin: origin)
            // Content is never logged — only its shape. A hook record carries
            // the user's prompt and their file paths.
            Log.claudeContext.debug("Ingested \(record.event.rawValue, privacy: .public)")
            #if DEBUG
            debugNotify(.success(record))
            #endif
            return snapshot?.marker
        } catch let error as ClaudeHookWireError {
            Log.claudeContext.error("Rejected record: \(String(describing: error), privacy: .public)")
            #if DEBUG
            debugNotify(.failure(error))
            #endif
            return nil
        } catch {
            Log.claudeContext.error("Rejected record: undecodable")
            #if DEBUG
            debugNotify(.failure(.malformed))
            #endif
            return nil
        }
    }
}

/// EINTR-safe wrappers. A signal must not look like a socket failure.
@inline(__always)
private func retryingOnEINTRInt32(_ body: () -> Int32) -> Int32 {
    while true {
        let result = body()
        if result == -1 && errno == EINTR { continue }
        return result
    }
}

@inline(__always)
private func retryingOnEINTRInt(_ body: () -> Int) -> Int {
    while true {
        let result = body()
        if result == -1 && errno == EINTR { continue }
        return result
    }
}

#endif
