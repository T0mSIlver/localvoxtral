import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

public struct ClaudeRemoteListenerLimits: Sendable, Equatable {
    /// Dedicated port. The managed backends own 8471 (voxmlx) and 8472
    /// (polishd); this is a third, and it is the only one that is ever reachable
    /// from a forwarded connection.
    public var port: UInt16
    public var maxConcurrentConnections: Int
    public var backlog: Int32
    /// Whole-connection deadline: head, auth, body, response. A tunnelled peer
    /// on a bad link is still not allowed to hold a slot indefinitely.
    public var connectionTimeout: TimeInterval
    public var http: ClaudeRemoteHTTPLimits
    public var wire: ClaudeHookLimits
    public var snippets: ClaudeSnippetLimits

    public init(
        port: UInt16 = 8473,
        maxConcurrentConnections: Int = 8,
        backlog: Int32 = 16,
        connectionTimeout: TimeInterval = 3.0,
        http: ClaudeRemoteHTTPLimits = .default,
        wire: ClaudeHookLimits = .default,
        snippets: ClaudeSnippetLimits = .default
    ) {
        self.port = port
        self.maxConcurrentConnections = maxConcurrentConnections
        self.backlog = backlog
        self.connectionTimeout = connectionTimeout
        self.http = http
        self.wire = wire
        self.snippets = snippets
    }

    public static let `default` = ClaudeRemoteListenerLimits()
}

#if canImport(Darwin)

/// Loopback HTTP ingest for REMOTE Claude Code sessions.
///
/// The topology: an OpenSSH `RemoteForward 8473 127.0.0.1:8473` makes the remote
/// host's `127.0.0.1:8473` come out of the local ssh client and connect here.
/// Claude Code on the remote host runs `type: "http"` hooks against that address
/// — no publisher binary, no shell shim, no `curl`/`jq`/Node on the remote side.
///
/// Everything below is the consequence of one fact: *we cannot see who is on the
/// other end.* The local broker asks the kernel for a peer UID and gets an
/// unforgeable answer. Here the peer is always our own ssh client, so the
/// transport tells us nothing about the origin. That inverts the design:
///
/// * **The token is the identity**, and it is checked against the enrolled-host
///   registry BEFORE a byte of body is read.
/// * **Every accepted session is `.remote`**, unconditionally. There is no
///   payload field, no header, and no address that can make this listener mint a
///   `.localAuthenticated` origin — so a local process that connects here can
///   only ever downgrade itself to remote capabilities. Remote capabilities mean
///   opaque context: `ClaudeWorkspaceReference.make` will not build a
///   `LocalWorkspacePath` for them, which makes "remote cwd reaches the
///   filesystem" a compile error rather than a review item.
/// * **Sessions are namespaced by host id** (`ClaudeRemoteSessionScope`), so two
///   hosts cannot collide, and neither can name a local session.
///
/// Why not `Network.framework`: NWListener would not let us bind loopback-only,
/// inspect the peer address, and read the `Authorization` header before framing
/// a body — and its HTTP handling would frame that body for us, which is exactly
/// the decision we need to make ourselves. Raw POSIX, one accept thread and one
/// short-lived thread per connection, mirroring `ClaudeContextBroker`.
///
/// `FileHandle.availableData`/`readDataToEndOfFile` are banned repo-wide (field
/// crash, PR #60) and appear nowhere here.
public final class ClaudeRemoteContextListener: Sendable {
    private struct State {
        var isRunning = false
        var activeConnections = 0
        var wakeWriteFD: Int32 = -1
    }

    private let state = Mutex(State())
    private let registry: ClaudeSessionRegistry
    private let hosts: ClaudeRemoteHostRegistry
    private let limits: ClaudeRemoteListenerLimits
    private let now: @Sendable () -> Date

    public enum StartFailure: Error, Equatable {
        case alreadyRunning
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        /// Nothing is enrolled, so there is nothing to listen for. Not an error
        /// the user should see — just a reason not to open a port.
        case noEnrolledHosts
    }

    /// - Parameter now: injected clock, so record timestamps are testable
    ///   (AGENTS: no wall-clock in tests).
    public init(
        registry: ClaudeSessionRegistry,
        hosts: ClaudeRemoteHostRegistry,
        limits: ClaudeRemoteListenerLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.hosts = hosts
        self.limits = limits
        self.now = now
    }

    public var isRunning: Bool { state.withLock { $0.isRunning } }
    public var port: UInt16 { limits.port }

    /// Bind loopback and start accepting.
    ///
    /// Every failure is thrown, never swallowed (AGENTS: a silent failure path is
    /// how the ensureReady bug cost an hour of remote probing).
    public func start() throws {
        guard hosts.hasActiveHosts else { throw StartFailure.noEnrolledHosts }

        let (listenerFD, wakeReadFD): (Int32, Int32) = try state.withLock { state in
            guard !state.isRunning else { throw StartFailure.alreadyRunning }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StartFailure.socketCreationFailed(errno: errno) }

            // SO_REUSEADDR only, never SO_REUSEPORT: REUSEADDR lets us rebind a
            // port still in TIME_WAIT from our own previous run, while REUSEPORT
            // would let ANOTHER process on this machine bind the same port
            // alongside us and race us for connections — i.e. steal tokens.
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = limits.port.bigEndian
            // INADDR_LOOPBACK, explicitly — never INADDR_ANY. The tunnel's local
            // end arrives on 127.0.0.1, and binding anything wider would put a
            // token-authenticated ingest on the user's LAN.
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw StartFailure.bindFailed(errno: code)
            }
            guard listen(fd, limits.backlog) == 0 else {
                let code = errno
                close(fd)
                throw StartFailure.listenFailed(errno: code)
            }

            // Self-pipe, for the same reason the local broker has one: closing a
            // listener fd underneath a blocked accept() is a use-after-close
            // race against fd recycling.
            var wakePipe: [Int32] = [-1, -1]
            guard pipe(&wakePipe) == 0 else {
                let code = errno
                close(fd)
                throw StartFailure.socketCreationFailed(errno: code)
            }
            _ = fcntl(wakePipe[1], F_SETNOSIGPIPE, 1)
            state.wakeWriteFD = wakePipe[1]
            state.isRunning = true
            return (fd, wakePipe[0])
        }

        // Outside the lock: the accept loop's first act is to read `isRunning`,
        // and this mutex is not reentrant.
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, wakeReadFD: wakeReadFD)
        }
        thread.name = "com.localvoxtral.claude-remote"
        thread.stackSize = 512 * 1024
        thread.start()

        Log.claudeContext.info(
            "Claude remote context listener on 127.0.0.1:\(Int(self.limits.port), privacy: .public)"
        )
    }

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
        Log.claudeContext.info("Claude remote context listener stopped")
    }

    // MARK: - Accept

    private func acceptLoop(listenerFD: Int32, wakeReadFD: Int32) {
        defer {
            state.withLock { $0.isRunning = false }
            close(listenerFD)
            close(wakeReadFD)
        }
        var stickyErrors = 0

        while state.withLock({ $0.isRunning }) {
            var fds = [
                pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = retryingOnEINTRInt32 { poll(&fds, 2, -1) }
            if ready < 0 {
                Log.claudeContext.error("Remote listener poll failed (\(errno, privacy: .public)); stopping")
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else {
                if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    Log.claudeContext.error("Remote listener socket failed; stopping accept loop")
                    return
                }
                continue
            }

            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = retryingOnEINTRInt32 {
                withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        accept(listenerFD, sockaddrPointer, &peerLength)
                    }
                }
            }
            guard fd >= 0 else {
                let code = errno
                switch code {
                case EAGAIN, EWOULDBLOCK, ECONNABORTED:
                    continue
                case EMFILE, ENFILE:
                    Log.claudeContext.error("Remote listener hit the descriptor limit; backing off")
                    usleep(100_000)
                    continue
                default:
                    stickyErrors += 1
                    Log.claudeContext.error(
                        "Remote accept failed (\(code, privacy: .public)); sticky=\(stickyErrors, privacy: .public)"
                    )
                    if stickyErrors >= 2 { return }
                    continue
                }
            }
            stickyErrors = 0

            // The socket is loopback-bound, so this can only fail if that bind
            // regressed — which is exactly why it is checked rather than assumed.
            guard peer.sin_family == sa_family_t(AF_INET),
                  ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: UInt32(bigEndian: peer.sin_addr.s_addr))
            else {
                Log.claudeContext.error("Rejected non-loopback connection to the remote listener")
                close(fd)
                continue
            }

            let admitted = state.withLock { state -> Bool in
                guard state.isRunning, state.activeConnections < limits.maxConcurrentConnections else {
                    return false
                }
                state.activeConnections += 1
                return true
            }
            guard admitted else {
                // Over the cap: drop. The hook fails open and the user loses one
                // context update — the right trade against unbounded threads.
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
            thread.name = "com.localvoxtral.claude-remote.conn"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - Serve

    /// One request per connection, then close. There is no keep-alive to reason
    /// about and no second request to re-authenticate.
    private func serve(connectionFD fd: Int32) {
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let deadline = now().addingTimeInterval(limits.connectionTimeout)

        var buffer = Data()
        var request: ClaudeRemoteHTTPRequest?
        var bodyOffset = 0

        // Phase 1: the head, and nothing else.
        while request == nil {
            do {
                let parsed = try ClaudeRemoteHTTPCodec.parseRequestHead(buffer, limits: limits.http)
                request = parsed.request
                bodyOffset = parsed.bodyOffset
            } catch ClaudeRemoteHTTPError.incompleteHead {
                guard readMore(fd: fd, into: &buffer, deadline: deadline) else { return }
                continue
            } catch {
                respond(fd: fd, status: status(for: error))
                return
            }
        }
        guard let request else { return }

        guard ClaudeRemoteHTTPCodec.eventName(inPath: request.path) != nil else {
            respond(fd: fd, status: 404)
            return
        }

        // Phase 2: authenticate on the HEAD ALONE.
        //
        // This is the ordering that matters most in the file. An unauthenticated
        // peer never gets to hand us a body — not to parse, not to buffer, not
        // to log. `Content-Length` was already bounded by the head parser, so
        // even a rejected request never sized an allocation.
        guard let token = request.bearerToken, let host = hosts.authenticate(token: token) else {
            Log.claudeContext.error("Rejected unauthenticated connection to the remote listener")
            respond(fd: fd, status: 401)
            return
        }

        // Phase 3: the body, now that we know who is speaking.
        while buffer.count - bodyOffset < request.contentLength {
            guard readMore(fd: fd, into: &buffer, deadline: deadline) else {
                respond(fd: fd, status: 400)
                return
            }
        }
        let bodyStart = buffer.index(buffer.startIndex, offsetBy: bodyOffset)
        let bodyEnd = buffer.index(bodyStart, offsetBy: request.contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        hosts.noteActivity(hostID: host.id)
        let marker = ingest(body: body, request: request, host: host)
        respond(fd: fd, status: 200, body: ClaudeRemoteHTTPCodec.markerResponseBody(marker: marker?.value))
    }

    /// - Returns: the marker for the session, so the hook's response can carry
    ///   it back down the SSH PTY as an OSC 2 title write.
    private func ingest(
        body: Data,
        request: ClaudeRemoteHTTPRequest,
        host: ClaudeRemoteHost
    ) -> ClaudeSessionMarker? {
        guard let payload = ClaudeRemoteHookPayloadParser.parse(
            data: body,
            fallbackEvent: ClaudeRemoteHTTPCodec.eventName(inPath: request.path),
            timestamp: now().timeIntervalSince1970,
            limits: limits.wire,
            snippetLimits: limits.snippets
        ) else {
            Log.claudeContext.error("Rejected remote record: unparseable payload")
            return nil
        }

        // The two lines that define this listener's trust model. The session id
        // is namespaced under the host whose TOKEN authenticated the request —
        // not under anything the payload said — and the origin is `.remote`
        // unconditionally. Neither is derived from content.
        var record = payload.record
        record.sessionID = ClaudeRemoteSessionScope.scopedSessionID(
            hostID: host.id,
            sessionID: record.sessionID
        )
        let origin = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: host.id))

        let snapshot = registry.ingest(record, origin: origin, snippets: payload.snippets)
        // Shape only. A remote record carries the user's prompt and excerpts of
        // their code; a log is the wrong place for either.
        Log.claudeContext.debug(
            "Ingested remote \(record.event.rawValue, privacy: .public) from \(host.id, privacy: .public)"
        )
        return snapshot?.marker
    }

    private func status(for error: any Error) -> Int {
        guard let httpError = error as? ClaudeRemoteHTTPError else { return 400 }
        switch httpError {
        case .headTooLarge: return 431
        case .bodyTooLarge: return 413
        case .lengthRequired: return 411
        case .unsupportedMethod: return 405
        case .incompleteHead, .malformed, .unsupportedTransferEncoding: return 400
        }
    }

    private func respond(fd: Int32, status: Int, body: Data? = nil) {
        let data = ClaudeRemoteHTTPCodec.response(status: status, body: body)
        _ = data.withUnsafeBytes { raw -> Int in
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

    /// Append one chunk, or fail.
    ///
    /// Gated on `poll` with the remaining budget rather than `SO_RCVTIMEO`: the
    /// deadline is for the WHOLE connection, so a peer that dribbles one byte
    /// per timeout period — the classic slowloris — makes no progress against it.
    /// A per-read timeout would reset with every byte and let that run forever.
    private func readMore(fd: Int32, into buffer: inout Data, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { return false }
        var descriptorPoll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = retryingOnEINTRInt32 { poll(&descriptorPoll, 1, Int32(remaining * 1000)) }
        guard ready > 0 else { return false } // Timed out or failed: done either way.

        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        let count = retryingOnEINTRInt { read(fd, &chunk, chunk.count) }
        guard count > 0 else { return false } // EOF or error.
        buffer.append(contentsOf: chunk[0..<count])

        // Hard ceiling independent of the phase we are in: head cap plus body
        // cap is the most a well-formed request can ever be, so anything past it
        // is a peer that is not going to stop on its own.
        guard buffer.count <= limits.http.maxHeadBytes + limits.http.maxBodyBytes else { return false }
        return true
    }
}

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
