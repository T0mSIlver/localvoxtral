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
        /// Signalled by the accept loop's `defer` on EVERY exit — requested or
        /// spontaneous. `stop()` waits on it so a caller that stops and
        /// immediately restarts cannot race the outgoing loop for the socket.
        var loopExit: DispatchSemaphore?
    }

    private let state = Mutex(State())
    private let socketPath: String
    private let registry: ClaudeSessionRegistry
    private let limits: ClaudeBrokerLimits
    private let uptimeNanos: @Sendable () -> UInt64
    private let shouldEmitLocalTitleMarker: @Sendable () -> Bool

    #if DEBUG
    /// Test seam: fires after each record is accepted or rejected, so a socket
    /// integration test can await a deterministic signal instead of polling the
    /// registry on a wall clock (AGENTS: no wall-clock in tests). Never used in
    /// production paths.
    private let debugIngestHook = Mutex<(@Sendable (Result<ClaudeHookRecord, ClaudeHookWireError>) -> Void)?>(nil)
    private let debugReadHook = Mutex<(@Sendable (Int) -> Void)?>(nil)

    public func debugConfigureIngestHook(
        _ hook: (@Sendable (Result<ClaudeHookRecord, ClaudeHookWireError>) -> Void)?
    ) {
        debugIngestHook.withLock { $0 = hook }
    }

    public func debugConfigureReadHook(_ hook: (@Sendable (Int) -> Void)?) {
        debugReadHook.withLock { $0 = hook }
    }

    private func debugNotify(_ result: Result<ClaudeHookRecord, ClaudeHookWireError>) {
        let hook = debugIngestHook.withLock { $0 }
        hook?(result)
    }
    #endif

    public init(
        socketPath: String,
        registry: ClaudeSessionRegistry,
        limits: ClaudeBrokerLimits = .default,
        uptimeNanos: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        shouldEmitLocalTitleMarker: @escaping @Sendable () -> Bool = { true }
    ) {
        self.socketPath = socketPath
        self.registry = registry
        self.limits = limits
        self.uptimeNanos = uptimeNanos
        self.shouldEmitLocalTitleMarker = shouldEmitLocalTitleMarker
    }

    public enum StartFailure: Error, Equatable {
        case pathTooLong(String)
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case alreadyRunning
        /// Another live process of ours already owns this socket. Distinct from
        /// `bindFailed(EADDRINUSE)`, which cannot tell a live owner from a
        /// leftover file — and the two demand opposite responses.
        case socketOwnedByLiveInstance(String)
    }

    public var socketURL: URL { URL(fileURLWithPath: socketPath) }

    /// Bind, secure, and start accepting. Every failure is reported, never
    /// swallowed — a silent failure path here is exactly how the ensureReady
    /// bug cost an hour of remote probing (AGENTS: keep new paths loud).
    public func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try ClaudeSocketGuard.prepareDirectory(at: directory)

        let (listenerFD, wakeReadFD, exitSignal): (Int32, Int32, DispatchSemaphore) =
            try state.withLock { state in
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

            // Bind under a restrictive umask so the socket is never briefly
            // world-reachable between bind() and chmod().
            //
            // Returns errno ALONGSIDE the result rather than leaving the caller
            // to read it: `umask` runs between the bind and the return, and a
            // caller reading `errno` afterwards is reading whatever the last
            // syscall left there, not the bind's. That is the same trap
            // `ClaudeSocketGuard.prepareDirectory` documents, and EADDRINUSE
            // getting lost here would mean silently unlinking a live instance's
            // socket — the exact failure this code exists to prevent.
            func attemptBind() -> (result: Int32, code: Int32) {
                let previousMask = umask(0o177)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                let code = errno
                umask(previousMask)
                return (result, code)
            }

            // Bind FIRST; only investigate if the path is taken.
            //
            // The previous code unlinked unconditionally, reasoning that the
            // directory is ours and private so nothing else could have put a
            // file there. True — but WE could have: a second live localvoxtral
            // running as the same user owns a perfectly legitimate socket at
            // this path, and unlinking it silently severed that instance from
            // every hook publisher on the machine. It kept accepting on an
            // unlinked inode, publishers connected to our new socket, and
            // nothing anywhere reported a problem.
            //
            // So: EADDRINUSE is ambiguous, and the way to disambiguate is to ask
            // the socket. A live owner accepts a connection; a leftover file
            // from a crashed run refuses it (ECONNREFUSED — nothing is
            // listening). Only the latter is ours to remove.
            var bound = attemptBind()
            if bound.result != 0, bound.code == EADDRINUSE {
                if Self.isSocketLive(atPath: socketPath) {
                    close(fd)
                    throw StartFailure.socketOwnedByLiveInstance(socketPath)
                }
                Log.claudeContext.info("Removing stale Claude broker socket")
                unlink(socketPath)
                bound = attemptBind()
            }
            guard bound.result == 0 else {
                close(fd)
                throw StartFailure.bindFailed(errno: bound.code)
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
            let exitSignal = DispatchSemaphore(value: 0)
            state.loopExit = exitSignal
            state.isRunning = true
                return (fd, wakePipe[0], exitSignal)
            }

        // Started OUTSIDE the lock: the accept loop's first act is to read
        // `isRunning`, and this mutex is not reentrant. Spawning it while still
        // holding the lock would park the new thread until start() returned —
        // harmless today, but exactly the kind of ordering that becomes a
        // deadlock the moment someone adds a join or a synchronous handshake.
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, wakeReadFD: wakeReadFD, exitSignal: exitSignal)
        }
        thread.name = "com.localvoxtral.claude-broker"
        thread.stackSize = 512 * 1024
        thread.start()

        Log.claudeContext.info("Claude context broker listening")
    }

    /// Stop accepting, and do not return until the accept loop is gone.
    ///
    /// The listener fd and the socket file are NOT touched here — the accept
    /// loop owns both and releases them in its `defer`, on every exit path. That
    /// keeps cleanup in ONE place: a stop-driven exit and a spontaneous one (a
    /// failed poll, a dead listener) previously cleaned up differently, so a
    /// loop that died on its own left the socket file on disk and the wake pipe's
    /// write end open forever.
    ///
    /// Waiting is what makes `stop(); start()` safe. Without it, start() can bind
    /// while the outgoing loop is still between its last accept() and its unlink
    /// — and that unlink then deletes the NEW socket, leaving a running broker
    /// nobody can reach.
    public func stop() {
        let (wakeFD, exitSignal): (Int32, DispatchSemaphore?) = state.withLock { state in
            guard state.isRunning else { return (-1, nil) }
            state.isRunning = false
            let wakeFD = state.wakeWriteFD
            // Taken under the lock so the loop's defer sees -1 and does not
            // close it a second time. Exactly one of us owns this fd.
            state.wakeWriteFD = -1
            let exitSignal = state.loopExit
            state.loopExit = nil
            return (wakeFD, exitSignal)
        }
        guard wakeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = retryingOnEINTRInt { write(wakeFD, &byte, 1) }
        close(wakeFD)
        exitSignal?.wait()
        Log.claudeContext.info("Claude context broker stopped")
    }

    public var isRunning: Bool { state.withLock { $0.isRunning } }

    /// Is something actually listening on this socket path?
    ///
    /// The only reliable answer is to connect. `stat` tells us a file exists,
    /// which is true of both a live socket and the corpse of a crashed run;
    /// those need opposite handling, and guessing wrong either steals a live
    /// instance's socket or refuses to ever start again.
    ///
    /// Connecting to our own broker is harmless: it accepts, we send nothing, and
    /// the connection closes. The serve thread reads EOF and exits.
    static func isSocketLive(atPath path: String) -> Bool {
        guard let metadata = ClaudeSocketGuard.metadata(ofPath: path) else {
            // Only a definite absence licenses cleanup. Any other lstat error
            // is indeterminate, so assume a live owner and do not unlink.
            return errno != ENOENT
        }
        // A symlink is never ours to follow or unlink. A non-socket inode in
        // this already-validated private directory cannot belong to a live
        // broker, so it is stale junk and may be replaced.
        if metadata.isSymlink { return true }
        guard metadata.isSocket else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { close(probe) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                retryingOnEINTRInt32 {
                    connect(probe, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard connected != 0 else { return true }
        let code = errno
        switch code {
        case ECONNREFUSED:
            // The file is there but nobody is home: a corpse from a crashed run.
            // This is the one answer that licenses removing it.
            return false
        case ENOENT:
            // Nothing is there at all. Not live, and nothing to remove either.
            return false
        default:
            // Anything else (EACCES, a timeout, EPERM) is a state we do not
            // understand, and the safe reading of "I do not understand" is
            // "assume it is live and do not delete it". Refusing to start is
            // recoverable; deleting a live instance's socket is not.
            return true
        }
    }

    // MARK: - Accept

    private func acceptLoop(listenerFD: Int32, wakeReadFD: Int32, exitSignal: DispatchSemaphore?) {
        defer {
            // The loop owns every resource start() handed it, and releases them
            // all here — on EVERY exit, not just a stop() request. The loop can
            // also leave on a failed poll or a dead listener, and that path used
            // to clear `isRunning` and nothing else: the wake pipe's write end
            // stayed open for the life of the process, and the socket file
            // stayed on disk advertising a broker that no longer existed.
            let wakeWriteFD: Int32 = state.withLock { state in
                state.isRunning = false
                let fd = state.wakeWriteFD
                state.wakeWriteFD = -1
                state.loopExit = nil
                return fd
            }
            // Non-negative only on a SPONTANEOUS exit: stop() takes this fd
            // under the same lock before writing to it, so exactly one of us
            // ever closes it.
            if wakeWriteFD >= 0 { close(wakeWriteFD) }
            close(listenerFD)
            close(wakeReadFD)
            // Ours to remove: we bound it, and stop() deliberately waits for
            // this defer rather than unlinking itself, so this cannot delete a
            // socket a subsequent start() has already bound.
            unlink(socketPath)
            exitSignal?.signal()
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
        // Kernel-verified peer pid, read once per connection. Used only for
        // the per-agent pid cross-check in `handle` — see peerPID's doc for
        // why it applies to opencode records and cannot apply to Claude's.
        let peerPID = ClaudeSocketGuard.peerPID(ofDescriptor: fd)

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let deadline = uptimeNanos() &+ UInt64(max(0, limits.readTimeout) * 1_000_000_000)

        var pending = Data()
        var recordCount = 0
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            guard readMore(fd: fd, into: &pending, using: &chunk, deadline: deadline) else {
                break
            }

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
                let handled = handle(line: line, origin: origin, peerPID: peerPID)
                reply(
                    to: fd,
                    marker: handled.marker,
                    accepted: handled.accepted,
                    isHerdrHosted: handled.isHerdrHosted,
                    version: handled.replyVersion
                )
            }
        }
    }

    /// Append one chunk under a whole-connection monotonic deadline. A
    /// per-syscall `SO_RCVTIMEO` resets after every byte and lets a slowloris
    /// retain a connection slot forever.
    private func readMore(
        fd: Int32,
        into buffer: inout Data,
        using chunk: inout [UInt8],
        deadline: UInt64
    ) -> Bool {
        let current = uptimeNanos()
        guard current < deadline else {
            Log.claudeContext.error("Dropping Claude broker connection: read deadline expired")
            return false
        }
        let remainingMillis = (deadline - current) / 1_000_000
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeout = Int32(min(remainingMillis, UInt64(Int32.max)))
        let ready = poll(&descriptor, 1, timeout)
        if ready < 0, errno == EINTR {
            // Re-enter rather than retry with the same timeout: the caller
            // loops straight back in and the remaining budget is recomputed,
            // so a late signal cannot extend the absolute deadline.
            return true
        }
        guard ready != 0 else {
            Log.claudeContext.error("Dropping Claude broker connection: read deadline expired")
            return false
        }
        guard ready > 0 else {
            Log.claudeContext.error("Claude broker connection poll failed (\(errno, privacy: .public))")
            return false
        }

        let count = retryingOnEINTRInt { read(fd, &chunk, chunk.count) }
        guard count >= 0 else {
            Log.claudeContext.error("Claude broker connection read failed (\(errno, privacy: .public))")
            return false
        }
        guard count > 0 else { return false }
        #if DEBUG
        debugReadHook.withLock { $0 }?(count)
        #endif
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }

    /// Optionally send the LOCAL session's marker back to the publisher.
    ///
    /// Focused-pane TTY is the default local join. The publisher only receives
    /// a marker to turn into a terminal title sequence when the user opted into
    /// that fallback. Registry ingestion and marker allocation are unchanged,
    /// so TTY joins keep the same marker-keyed liveness checks either way.
    /// herdr records never receive one: herdr intercepts OSC 2 inside its pane,
    /// so the marker cannot describe the outer Ghostty surface and would only
    /// contaminate herdr's own pane-title state.
    ///
    /// Best-effort by design — a publisher that has already exited is normal,
    /// not an error.
    private func reply(
        to fd: Int32,
        marker: ClaudeSessionMarker?,
        accepted: Bool,
        isHerdrHosted: Bool,
        version: Int
    ) {
        let responseMarker = shouldEmitLocalTitleMarker() && !isHerdrHosted ? marker?.value : nil
        guard let line = ClaudeBrokerResponse.encodeLine(
            // Echo the REQUEST's wire version (review C4): an already-installed
            // v1 publisher rejects any reply that does not say v1, so replying
            // with the broker's own version would silently kill the marker
            // channel for every stale plugin install until it updated.
            // `accepted` rides along in every reply shape — old decoders
            // ignore the unknown key (synthesized Codable), so no bump.
            ClaudeBrokerResponse(version: version, marker: responseMarker, accepted: accepted)
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

    /// - Returns: the marker for the session this record belongs to, whether
    ///   the record was committed to the registry (`accepted` — carried back
    ///   in the reply so a publisher can distinguish "read" from "took
    ///   effect"), whether herdr must intercept title changes, and the wire
    ///   version to shape the reply as (the request's own — see `reply`).
    ///
    /// `accepted` is truthful for every layer that still produces a reply. A
    /// reply is per complete LINE, so exactly three rejection layers can
    /// answer `false`:
    ///   1. wire-shape rejection of a complete line (`decodeLine` throws —
    ///      malformed JSON, unsupported version, over-limit fields);
    ///   2. the opencode peer-pid cross-check below;
    ///   3. the registry refusing the record (`ingest` returns nil: focus
    ///      declarations/clears for sessions it has never seen, origin or
    ///      agent mismatch, `SessionEnd` for an unknown session, and the
    ///      namespace-prefix aliasing drop).
    /// Connection-level rejections (foreign uid, unterminated over-cap line,
    /// too many records, read deadline) drop the connection WITHOUT a reply,
    /// unchanged — publishers observe those as an error/close, not a verdict.
    @discardableResult
    private func handle(
        line: Data,
        origin: ClaudeTransportOrigin,
        peerPID: pid_t?
    ) -> (marker: ClaudeSessionMarker?, accepted: Bool, isHerdrHosted: Bool, replyVersion: Int) {
        do {
            let record = try ClaudeHookWireCodec.decodeLine(line, limits: limits.wire)
            // Per-agent pid cross-check against the KERNEL's answer. The
            // opencode plugin runs inside the agent process and dials this
            // socket from it, so the pid its records claim must be the pid on
            // the other end of the connection — a same-user process forging
            // opencode records for a pid it does not own is cut off here.
            // Claude records cannot be held to this: their publisher is a
            // transient child of the session, never the session process
            // itself, which is exactly why the claude pid rides in the record
            // (see ClaudeSocketGuard.peerPID). The residual same-user threat
            // for THAT path is accepted and documented in
            // docs/agent/invariants.md — trust is transport-derived, and
            // every local peer shares this uid.
            if record.agent == .opencode {
                guard let peerPID, record.process?.claudePID == peerPID else {
                    Log.claudeContext.error(
                        "Rejected opencode record: claimed pid does not match socket peer"
                    )
                    #if DEBUG
                    debugNotify(.failure(.malformed))
                    #endif
                    return (nil, false, false, record.version)
                }
            }
            let snapshot = registry.ingest(record, origin: origin)
            let accepted = snapshot != nil
            // Content is never logged — only its shape. A hook record carries
            // the user's prompt and their file paths.
            if accepted {
                Log.claudeContext.debug("Ingested \(record.event.rawValue, privacy: .public)")
            } else {
                Log.claudeContext.debug("Registry refused \(record.event.rawValue, privacy: .public)")
            }
            #if DEBUG
            debugNotify(.success(record))
            #endif
            // Only Claude Code has a writable title channel, so only Claude
            // sessions ever receive their marker back — the herdr rule,
            // generalized per agent: opencode rewrites its own OSC titles
            // mid-turn (and clears them on exit), so a marker sent there could
            // never survive to identify a pane, and its plugin deliberately
            // never writes to the terminal at all. Allocation is unchanged —
            // the registry marker remains every join's liveness handle.
            let marker = snapshot?.agent == .claude ? snapshot?.marker : nil
            return (marker, accepted, record.process?.herdrPaneID != nil, record.version)
        } catch let error as ClaudeHookWireError {
            Log.claudeContext.error("Rejected record: \(String(describing: error), privacy: .public)")
            #if DEBUG
            debugNotify(.failure(error))
            #endif
            // A rejected record carries no marker; the current version is as
            // good as any guess for the reply shape.
            return (nil, false, false, ClaudeHookWire.version)
        } catch {
            Log.claudeContext.error("Rejected record: undecodable")
            #if DEBUG
            debugNotify(.failure(.malformed))
            #endif
            return (nil, false, false, ClaudeHookWire.version)
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
