#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

/// An AF_UNIX control socket that exists ONLY in a dogfood build.
///
/// ## Why it exists
///
/// Debugging the Claude Code / herdr join without sitting at the machine means
/// driving the app through synthetic menu clicks, modifier gestures and AX
/// scraping, and then inferring what happened from a log line that names one
/// abstention category. Two of those problems are not fixable from outside the
/// process: a dictation cannot be started deterministically (the trigger is a
/// modifier GESTURE), and `ClaudeSessionRegistry` is per-process with no
/// persistence, so no separate process — including PR #237's `--probe-surface`
/// — can ever resolve a surface against the sessions the app actually holds.
///
/// ## Why it is a real risk, and what bounds it
///
/// This is a socket that starts dictations and reports on the context
/// pipeline. It is a deliberate, owner-approved tradeoff, and every bound on it
/// is load-bearing:
///
/// * **`#if LOCALVOXTRAL_DOGFOOD` and nothing else.** A release build contains
///   no listener, no path, and no code that could create one. There is no
///   setting, no environment variable and no argument that turns this on in a
///   shipped binary — the file is not compiled.
///   `DogfoodControlBuildBoundaryTests` runs in BOTH configurations and fails
///   if any of this becomes reachable outside the flag.
/// * **0700 directory, 0600 socket, and a peer-UID check anyway.** The
///   permissions should already make another uid unable to reach the path;
///   `getpeereid` is checked before a single byte is read, so that "should" is
///   not the only thing standing there. Defence in depth, because this is the
///   surface that was accepted on a recommendation.
/// * **Nothing identifying crosses.** Every reply value is a bool, a count or
///   a closed enum name (`DogfoodControlProtocol`); no field is ever built from
///   a token, nonce, marker, host, path, tty or pane id. Replies are passed
///   through the same shape-matched token scrub the capture records use
///   (`DogfoodCaptureRedaction`) as a backstop, not as the strategy.
/// * **A started session is bounded.** `DogfoodControlService` auto-stops it,
///   so a client that disconnects mid-dictation cannot leave the app
///   recording.
/// * **No injection.** No command carries a surface, a session or a join to
///   pretend with. Every verb observes.
///
/// ## Threading
///
/// One accept thread, one connection at a time, `Mutex` for state — the
/// repo's "no custom actors" convention, and the same self-pipe shutdown the
/// broker uses (`shutdown()` on a listening socket is not specified to wake a
/// blocked `accept` on Darwin, and closing the fd underneath the loop is a
/// use-after-close race). Serving one connection at a time is deliberate: it
/// serializes commands without a second lock, and a debug socket has exactly
/// one client.
final class DogfoodControlSocket: Sendable {
    /// Deliberately under the app's existing dogfood directory, whose 0700-ness
    /// the store already depends on — one private place for everything this
    /// build adds, rather than a second one to audit.
    static func defaultSocketPath() -> String {
        DogfoodCaptureStore.defaultDirectoryURL()
            .appendingPathComponent("control")
            .appendingPathComponent("control.sock")
            .path
    }

    enum StartFailure: Error, Equatable {
        case pathTooLong
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case alreadyRunning
        /// Another live instance of ours owns this path. Distinct from
        /// `bindFailed(EADDRINUSE)`, which cannot tell a live owner from the
        /// corpse of a crashed run — and the two demand opposite responses.
        case socketOwnedByLiveInstance
    }

    /// Reads one line and produces one reply line. Injected so the socket can
    /// be tested end to end (bind, connect, credentials, framing) without a
    /// view model.
    typealias Handler = @Sendable (String) async -> String

    private struct State {
        var isRunning = false
        var wakeWriteFD: Int32 = -1
        var loopExit: DispatchSemaphore?
    }

    private let state = Mutex(State())
    private let socketPath: String
    private let handler: Handler
    /// Peer credentials, injected. The live implementation is the kernel's
    /// answer; a test substitutes a foreign uid to prove the rejection is real
    /// rather than merely present in the source.
    private let peerUID: @Sendable (Int32) -> UInt32?
    private let expectedUID: @Sendable () -> UInt32
    /// Whole-connection read deadline in milliseconds. A peer that connects and
    /// says nothing must not hold the single serving slot.
    private let readTimeoutMillis: Int32

    init(
        socketPath: String,
        handler: @escaping Handler,
        peerUID: @escaping @Sendable (Int32) -> UInt32? = { ClaudeSocketGuard.peerUID(ofDescriptor: $0) },
        expectedUID: @escaping @Sendable () -> UInt32 = { UInt32(geteuid()) },
        readTimeoutMillis: Int32 = 5_000
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.peerUID = peerUID
        self.expectedUID = expectedUID
        self.readTimeoutMillis = readTimeoutMillis
    }

    var isRunning: Bool { state.withLock { $0.isRunning } }

    /// Bind, secure, start accepting. Loud on every failure (AGENTS: a silent
    /// failure path is how the ensureReady bug cost an hour of remote probing)
    /// — and non-fatal, because the app's own dictation does not need this.
    func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        // Reuses the broker's guard: creates 0700 if absent, and REFUSES a
        // directory that is a symlink, is not ours, or is group/world
        // reachable. It never "repairs" one — that is a situation to report.
        try ClaudeSocketGuard.prepareDirectory(at: directory)

        let (listenerFD, wakeReadFD, exitSignal): (Int32, Int32, DispatchSemaphore) =
            try state.withLock { state in
                guard !state.isRunning else { throw StartFailure.alreadyRunning }

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = Array(socketPath.utf8)
                let capacity = MemoryLayout.size(ofValue: address.sun_path)
                guard pathBytes.count < capacity else { throw StartFailure.pathTooLong }
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    raw.copyBytes(from: pathBytes)
                    raw[pathBytes.count] = 0
                }
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw StartFailure.socketCreationFailed(errno: errno) }

                // Bind under a restrictive umask so the socket is never briefly
                // reachable by another uid between bind() and chmod(). errno is
                // returned alongside the result rather than read afterwards:
                // umask() runs in between, and a lost EADDRINUSE would mean
                // silently unlinking a live instance's socket.
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

                // A path that is taken is ambiguous: a live second instance
                // owns a legitimate socket there, and a crashed run leaves an
                // identical-looking corpse. Ask the socket — a live owner
                // accepts, a corpse refuses (ECONNREFUSED). Only the latter is
                // ours to remove. Unlinking unconditionally would sever a live
                // instance from its client with nothing reporting a problem.
                var bound = attemptBind()
                if bound.result != 0, bound.code == EADDRINUSE {
                    if ClaudeContextBroker.isSocketLive(atPath: socketPath) {
                        close(fd)
                        throw StartFailure.socketOwnedByLiveInstance
                    }
                    Log.claudeContext.info("Removing stale dogfood control socket")
                    unlink(socketPath)
                    bound = attemptBind()
                }
                guard bound.result == 0 else {
                    close(fd)
                    throw StartFailure.bindFailed(errno: bound.code)
                }
                // Belt and braces: the umask should have produced 0600, but
                // macOS has been inconsistent about umask on AF_UNIX binds and
                // this is cheap. The mode is asserted by test.
                chmod(socketPath, 0o600)

                guard listen(fd, 4) == 0 else {
                    let code = errno
                    close(fd)
                    unlink(socketPath)
                    throw StartFailure.listenFailed(errno: code)
                }

                var wakePipe: [Int32] = [-1, -1]
                guard pipe(&wakePipe) == 0 else {
                    let code = errno
                    close(fd)
                    unlink(socketPath)
                    throw StartFailure.socketCreationFailed(errno: code)
                }
                // Without NOSIGPIPE, a stop() racing a loop that already left
                // would kill the whole app with SIGPIPE.
                _ = fcntl(wakePipe[1], F_SETNOSIGPIPE, 1)
                state.wakeWriteFD = wakePipe[1]
                let exitSignal = DispatchSemaphore(value: 0)
                state.loopExit = exitSignal
                state.isRunning = true
                return (fd, wakePipe[0], exitSignal)
            }

        // Started outside the lock: the loop's first act is to read
        // `isRunning`, and this mutex is not reentrant.
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, wakeReadFD: wakeReadFD, exitSignal: exitSignal)
        }
        thread.name = "com.localvoxtral.dogfood-control"
        thread.stackSize = 512 * 1024
        thread.start()
        Log.claudeContext.info("Dogfood control socket listening")
    }

    /// Stop accepting and do not return until the loop is gone.
    ///
    /// The listener fd and the socket file belong to the loop and are released
    /// in its `defer` on EVERY exit path. Waiting here is what makes
    /// `stop(); start()` safe: without it a new bind can race the outgoing
    /// loop's unlink, which would then delete the NEW socket.
    func stop() {
        let (wakeFD, exitSignal): (Int32, DispatchSemaphore?) = state.withLock { state in
            guard state.isRunning else { return (-1, nil) }
            state.isRunning = false
            let wakeFD = state.wakeWriteFD
            state.wakeWriteFD = -1
            let exitSignal = state.loopExit
            state.loopExit = nil
            return (wakeFD, exitSignal)
        }
        guard wakeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakeFD, &byte, 1)
        close(wakeFD)
        exitSignal?.wait()
        Log.claudeContext.info("Dogfood control socket stopped")
    }

    // MARK: - Accept

    private func acceptLoop(listenerFD: Int32, wakeReadFD: Int32, exitSignal: DispatchSemaphore?) {
        defer {
            let wakeWriteFD: Int32 = state.withLock { state in
                state.isRunning = false
                let fd = state.wakeWriteFD
                state.wakeWriteFD = -1
                state.loopExit = nil
                return fd
            }
            // Non-negative only on a SPONTANEOUS exit: stop() takes this fd
            // under the same lock before writing, so exactly one of us closes it.
            if wakeWriteFD >= 0 { close(wakeWriteFD) }
            close(listenerFD)
            close(wakeReadFD)
            unlink(socketPath)
            exitSignal?.signal()
        }

        var stickyErrors = 0
        while state.withLock({ $0.isRunning }) {
            var fds = [
                pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                Log.claudeContext.error(
                    "Dogfood control accept poll failed (\(errno, privacy: .public)); stopping"
                )
                return
            }
            // Wake byte, or the pipe's write end closed: either way, leave.
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else {
                if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    Log.claudeContext.error("Dogfood control listener failed; stopping")
                    return
                }
                continue
            }

            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else {
                let code = errno
                switch code {
                case EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED:
                    continue
                default:
                    // poll() will very likely report the same thing next
                    // iteration — the shape of a 100%-CPU spin. Two in a row
                    // and we leave.
                    stickyErrors += 1
                    Log.claudeContext.error(
                        "Dogfood control accept failed (\(code, privacy: .public))"
                    )
                    if stickyErrors >= 2 { return }
                    continue
                }
            }
            stickyErrors = 0
            // Served inline: one client, one command at a time. Serializing
            // here is what keeps the non-reentrant abstention tap safe without
            // a second lock.
            serve(connectionFD: fd)
        }
    }

    private func serve(connectionFD fd: Int32) {
        defer { close(fd) }

        // Authenticated BEFORE the first read: an unauthorized peer never gets
        // to hand us bytes at all. The directory is 0700 and the socket 0600,
        // so this should be unreachable — which is exactly why it is here.
        guard let uid = peerUID(fd) else {
            Log.claudeContext.error(
                "Dogfood control: rejected connection, peer credentials unavailable"
            )
            return
        }
        guard uid == expectedUID() else {
            Log.claudeContext.error(
                "Dogfood control: rejected connection from foreign uid \(uid, privacy: .public)"
            )
            return
        }

        let reply: String
        switch readRequestLine(fd: fd) {
        case .none:
            return
        case .some(.failure(let error)):
            reply = DogfoodControlProtocol.reply(
                command: nil,
                result: nil,
                error: error.rawValue
            )
        case .some(.success(let line)):
            reply = runHandler(line)
        }
        // One line, LF-terminated. The scrub is a backstop: nothing upstream
        // renders a token into a reply, and this catches a future field that
        // forgets.
        var count = 0
        let scrubbed = DogfoodCaptureRedaction.redacting(reply, count: &count)
        if count > 0 {
            Log.claudeContext.error(
                "Dogfood control: redacted \(count, privacy: .public) token-shaped run(s) from a reply"
            )
        }
        writeAll(fd: fd, string: scrubbed + "\n")
    }

    /// Bridges the async handler to this synchronous serving thread.
    ///
    /// A semaphore is correct HERE and would be a deadlock in the app's own
    /// main-actor code: this is a dedicated socket thread that owns nothing and
    /// blocks nobody, and the handler hops to the main actor on its own.
    private func runHandler(_ line: String) -> String {
        let box = Mutex<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task {
            let reply = await handler(line)
            box.withLock { $0 = reply }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 } ?? DogfoodControlProtocol.reply(
            command: nil,
            result: nil,
            error: "handler produced no reply"
        )
    }

    /// One LF-terminated line, under a whole-connection deadline and a hard
    /// byte cap. Never `FileHandle.availableData` (banned repo-wide: it raises
    /// an uncatchable ObjC exception on descriptor errors and aborts the app,
    /// field crash PR #60).
    ///
    /// - Returns: nil when there is nothing to answer (the peer left, or the
    ///   deadline passed with no request), a failure when the bytes were not a
    ///   request this socket will parse, and the line otherwise.
    private func readRequestLine(
        fd: Int32
    ) -> Result<String, DogfoodControlProtocol.RequestError>? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        // A single budget for the whole read, not a per-syscall timeout: a
        // per-syscall one resets after every byte and lets a slowloris hold the
        // serving slot forever.
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(readTimeoutMillis) * 1_000_000

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                Log.claudeContext.error("Dogfood control: read deadline expired")
                return nil
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(min((deadline - now) / 1_000_000, UInt64(Int32.max)))
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else {
                Log.claudeContext.error("Dogfood control: read deadline expired")
                return nil
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            // EOF before a newline. A client that closed its write end after
            // sending a bare command still gets an answer; one that sent
            // nothing gets no reply at all.
            if count == 0 {
                return buffer.isEmpty ? nil : .success(decode(buffer))
            }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return .success(decode(Array(buffer[0..<newline])))
            }
            // Over the cap with no newline in sight. Answered with the reason
            // rather than dropped, so a client learns why — and stops reading
            // here rather than buffering whatever else is coming.
            if buffer.count > DogfoodControlProtocol.maxRequestBytes {
                return .failure(.tooLong)
            }
        }
    }

    private func decode(_ bytes: [UInt8]) -> String {
        // Trailing CR: a client using `printf 'join report\r\n'` should not
        // fail on an invisible byte.
        var bytes = bytes
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeAll(fd: Int32, string: String) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                return
            }
            offset += written
        }
    }
}

#endif
