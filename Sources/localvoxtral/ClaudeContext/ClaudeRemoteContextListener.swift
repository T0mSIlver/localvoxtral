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
    /// Caps on the allowlisted env headers the shim adds. Re-applied here on
    /// arrival: the shim validating first is a courtesy, not a guarantee.
    public var environment: ClaudeRemoteEnvironmentLimits

    public init(
        port: UInt16 = 8473,
        maxConcurrentConnections: Int = 8,
        backlog: Int32 = 16,
        connectionTimeout: TimeInterval = 3.0,
        http: ClaudeRemoteHTTPLimits = .default,
        wire: ClaudeHookLimits = .default,
        snippets: ClaudeSnippetLimits = .default,
        environment: ClaudeRemoteEnvironmentLimits = .default
    ) {
        self.port = port
        self.maxConcurrentConnections = maxConcurrentConnections
        self.backlog = backlog
        self.connectionTimeout = connectionTimeout
        self.http = http
        self.wire = wire
        self.snippets = snippets
        self.environment = environment
    }

    public static let `default` = ClaudeRemoteListenerLimits()
}

#if canImport(Darwin)

/// Loopback HTTP ingest for REMOTE Claude Code sessions.
///
/// The topology: an OpenSSH `RemoteForward 8473 127.0.0.1:8473` makes the remote
/// host's `127.0.0.1:8473` come out of the local ssh client and connect here.
/// Claude Code on the remote host runs the plugin's command-hook curl shim
/// against that address — no publisher binary and no `jq`/Node on the remote
/// side, just POSIX `sh` and `curl`.
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
        /// Signalled by the accept loop's `defer` on every exit. `stop()` waits
        /// on it, so a rebind after a revoke/enroll cannot race the outgoing
        /// loop for the port.
        var loopExit: DispatchSemaphore?
    }

    private let state = Mutex(State())
    private let registry: ClaudeSessionRegistry
    private let hosts: ClaudeRemoteHostRegistry
    private let limits: ClaudeRemoteListenerLimits
    private let now: @Sendable () -> Date
    private let uptimeNanos: @Sendable () -> UInt64
    /// Rejections since launch, for the Settings hint. Injected (rather than
    /// owned) so it OUTLIVES this listener: the coordinator builds a fresh
    /// listener on every rebind, and evidence the user has not read yet must not
    /// be erased by enrolling a second host.
    private let rejections: ClaudeRemoteRejectionTally

    #if DEBUG
    private let debugPostAuthenticationHook = Mutex<(@Sendable () -> Void)?>(nil)

    public func debugConfigurePostAuthenticationHook(_ hook: (@Sendable () -> Void)?) {
        debugPostAuthenticationHook.withLock { $0 = hook }
    }
    #endif

    public enum StartFailure: Error, Equatable {
        case alreadyRunning
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        /// Nothing is enrolled, so there is nothing to listen for. Not an error
        /// the user should see — just a reason not to open a port.
        case noEnrolledHosts
    }

    /// - Parameters:
    ///   - now: injected wall clock, for the TIMESTAMP stamped on a record —
    ///     which must be a real date, because it is compared against the
    ///     registry's other records.
    ///   - uptimeNanos: injected monotonic source, for the connection DEADLINE.
    ///     Deliberately a second, separate seam. These are two different
    ///     questions and one clock cannot answer both: `now` is settable (NTP,
    ///     a DST change, the user fixing their clock), and a deadline built on a
    ///     settable clock either fires instantly or never when it steps. It is
    ///     also frozen in tests — a test that pins `now` to inspect a record's
    ///     timestamp would otherwise pin every connection's deadline to "never
    ///     expires", quietly disabling the slowloris bound in exactly the suite
    ///     meant to prove it.
    public init(
        registry: ClaudeSessionRegistry,
        hosts: ClaudeRemoteHostRegistry,
        limits: ClaudeRemoteListenerLimits = .default,
        rejections: ClaudeRemoteRejectionTally = ClaudeRemoteRejectionTally(),
        now: @escaping @Sendable () -> Date = { Date() },
        uptimeNanos: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.registry = registry
        self.hosts = hosts
        self.limits = limits
        self.rejections = rejections
        self.now = now
        self.uptimeNanos = uptimeNanos
    }

    public var isRunning: Bool { state.withLock { $0.isRunning } }
    public var port: UInt16 { limits.port }
    /// Rejections since the tally was created, by category.
    public var rejectionSnapshot: ClaudeRemoteRejectionTally.Snapshot { rejections.snapshot() }

    /// Bind loopback and start accepting.
    ///
    /// Every failure is thrown, never swallowed (AGENTS: a silent failure path is
    /// how the ensureReady bug cost an hour of remote probing).
    public func start() throws {
        guard hosts.hasActiveHosts else { throw StartFailure.noEnrolledHosts }

        let (listenerFD, wakeReadFD, exitSignal): (Int32, Int32, DispatchSemaphore) =
            try state.withLock { state in
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
            let exitSignal = DispatchSemaphore(value: 0)
            state.loopExit = exitSignal
            state.isRunning = true
                return (fd, wakePipe[0], exitSignal)
            }

        // Outside the lock: the accept loop's first act is to read `isRunning`,
        // and this mutex is not reentrant.
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, wakeReadFD: wakeReadFD, exitSignal: exitSignal)
        }
        thread.name = "com.localvoxtral.claude-remote"
        thread.stackSize = 512 * 1024
        thread.start()

        Log.claudeContext.info(
            "Claude remote context listener on 127.0.0.1:\(Int(self.limits.port), privacy: .public)"
        )
    }

    /// Stop accepting, and do not return until the accept loop is gone.
    ///
    /// Waiting is what makes the enroll/revoke rebind deterministic: a caller
    /// that revokes the last host and immediately re-enrolls one calls
    /// `stop(); start()` back to back, and without the wait `start()` can reach
    /// `bind` while the outgoing loop still holds the port — an intermittent
    /// EADDRINUSE that looks exactly like a real port conflict.
    public func stop() {
        let (wakeFD, exitSignal): (Int32, DispatchSemaphore?) = state.withLock { state in
            guard state.isRunning else { return (-1, nil) }
            state.isRunning = false
            let wakeFD = state.wakeWriteFD
            // Taken under the lock, so the loop's defer sees -1 and cannot close
            // it a second time.
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
        Log.claudeContext.info("Claude remote context listener stopped")
    }

    // MARK: - Accept

    private func acceptLoop(listenerFD: Int32, wakeReadFD: Int32, exitSignal: DispatchSemaphore?) {
        defer {
            // Release everything start() handed us, on EVERY exit — including a
            // spontaneous one (failed poll, dead listener, repeated accept
            // errors). That path used to clear `isRunning` and leave the wake
            // pipe's write end open for the life of the process.
            let wakeWriteFD: Int32 = state.withLock { state in
                state.isRunning = false
                let fd = state.wakeWriteFD
                state.wakeWriteFD = -1
                state.loopExit = nil
                return fd
            }
            // Non-negative only on a spontaneous exit; stop() takes it under the
            // same lock. Exactly one of us closes it.
            if wakeWriteFD >= 0 { close(wakeWriteFD) }
            close(listenerFD)
            close(wakeReadFD)
            exitSignal?.signal()
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
        // Monotonic, not wall clock. See `init(uptimeNanos:)`.
        let deadline = uptimeNanos() &+ UInt64(limits.connectionTimeout * 1_000_000_000)

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

        // Phase 2: authenticate on the HEAD ALONE, before ANY other judgement
        // about the request.
        //
        // This is the ordering that matters most in the file. An unauthenticated
        // peer never gets to hand us a body — not to parse, not to buffer, not
        // to log. `Content-Length` was already bounded by the head parser, so
        // even a rejected request never sized an allocation.
        //
        // The path check used to run FIRST, which made this endpoint an oracle:
        // 404 versus 401 told an unauthenticated caller exactly which event
        // paths exist, enumerable without a credential. It says nothing an
        // attacker could not guess from the public plugin manifest — but "the
        // answer is currently harmless" is not a reason to answer. Nothing is
        // discriminated on until the token is known good.
        //
        // The rejection is CLASSIFIED on the way out. One undifferentiated line
        // is what made a night of "Rejected unauthenticated connection" say
        // nothing about whether the remedy was updating a host's plugin or
        // re-running its enrollment (field report, 2026-07-26). The category is
        // derived from the header's shape and the authentication result only —
        // no token material reaches the log, the tally, or the UI.
        let shape = ClaudeRemoteHTTPCodec.authorizationShape(
            in: request.headers["authorization"], limits: limits.http
        )
        let candidate = request.bearerToken
        let authenticatedHost = candidate.flatMap { hosts.authenticate(token: $0) }
        guard let token = candidate, let host = authenticatedHost else {
            // The REAL authentication result, not a constant `false`: the
            // mapping's contract includes "an accepted credential is not a
            // rejection", and its only production caller should exercise that
            // rather than assert it. Reaching the fallback would mean
            // `bearerToken` and `authorizationShape` disagreed about one header
            // — impossible while the former is implemented on the latter, and
            // `unknownToken` is the conservative reading if it ever were not.
            let category = ClaudeRemoteRejectionCategory.category(
                for: shape, authenticated: authenticatedHost != nil
            ) ?? .unknownToken
            rejections.record(category)
            Log.claudeContext.error("\(category.logLine, privacy: .public)")
            respond(fd: fd, status: 401)
            return
        }
        #if DEBUG
        debugPostAuthenticationHook.withLock { $0 }?()
        #endif

        guard ClaudeRemoteHTTPCodec.eventName(inPath: request.path) != nil else {
            respond(fd: fd, status: 404)
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

        // Parse and scope OUTSIDE the host lock: constant-time-hashing every
        // stored token is already the lock's fixed cost per request, and
        // serializing body parsing behind it would stall every other host's
        // auth behind one slow payload. Only the COMMIT — the part the
        // revocation race is about — re-authenticates under the lock.
        guard let prepared = prepareIngest(body: body, request: request, host: host) else {
            // Unparseable payloads never touch the session registry, so
            // revocation has nothing to protect; same 200-with-no-marker the
            // pre-race-fix path returned.
            hosts.noteActivity(hostID: host.id)
            respond(fd: fd, status: 200, body: ClaudeRemoteHTTPCodec.markerResponseBody(marker: nil))
            return
        }
        guard let marker = hosts.withAuthenticatedHost(
            token: token,
            expectedHostID: host.id,
            { _ in
                commitIngest(prepared)
            }
        ) else {
            Log.claudeContext.error(
                "Rejected remote connection: host was revoked before ingest"
            )
            respond(fd: fd, status: 401)
            return
        }
        hosts.noteActivity(hostID: host.id)
        respond(fd: fd, status: 200, body: ClaudeRemoteHTTPCodec.markerResponseBody(marker: marker?.value))
    }

    private struct PreparedIngest {
        let record: ClaudeHookRecord
        let snippets: [ClaudeContentSnippet]
        let environment: ClaudeRemoteSessionEnvironment?
        let hostID: String
    }

    /// The parse/scope half of ingest, safe outside any lock.
    private func prepareIngest(
        body: Data,
        request: ClaudeRemoteHTTPRequest,
        host: ClaudeRemoteHost
    ) -> PreparedIngest? {
        guard let payload = ClaudeRemoteHookPayloadParser.parse(
            data: body,
            fallbackEvent: ClaudeRemoteHTTPCodec.eventName(inPath: request.path),
            timestamp: now().timeIntervalSince1970,
            limits: limits.wire,
            snippetLimits: limits.snippets
        ) else {
            // With the event, which is the one thing that makes this actionable:
            // "every SessionStart is unparseable" and "one PostToolUse was" are
            // different bugs. Taken from the URL the plugin manifest chose and
            // narrowed to a KNOWN event name — the path is bounded but still
            // peer-supplied, and a log line is not the place to find that out.
            let event = Self.knownEventLabel(inPath: request.path)
            Log.claudeContext.error(
                "Rejected remote record: unparseable payload (event \(event, privacy: .public))"
            )
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

        // Enrichment rides as HEADERS, not in the body: the shim has no jq and
        // must hand Claude Code's event JSON on byte-for-byte, so there is
        // nowhere in the body to put this without parsing and re-serializing it
        // on a host where we cannot count on a JSON tool existing.
        //
        // The header VALUES stay what they were on the wire — opaque labels
        // about another machine — and they land in their own snapshot field,
        // never in `process`. Re-validated here against the same charset and
        // caps the shim applies; the shim's own validation is a courtesy from a
        // machine we do not control.
        let environment = ClaudeRemoteEnvironmentCodec.environment(
            in: request.headers, limits: limits.environment
        )
        // Count only. The values name panes, sockets and TTYs on the user's
        // other machine; the log is not the place for them, and a count is what
        // makes "the shim is on an old version" diagnosable.
        if let environment {
            let count = ClaudeRemoteEnvironmentField.allCases.filter { environment[$0] != nil }.count
            Log.claudeContext.debug(
                "Remote record carried \(count, privacy: .public) allowlisted env labels"
            )
        }

        return PreparedIngest(
            record: record,
            snippets: payload.snippets,
            environment: environment,
            hostID: host.id
        )
    }

    /// The session-registry half of ingest. Runs under the host-registry lock
    /// (`withAuthenticatedHost`) so revocation cannot commit between the
    /// re-check and this write.
    ///
    /// - Returns: the marker for the session, so the hook's response can carry
    ///   it back down the SSH PTY as an OSC 2 title write.
    private func commitIngest(_ prepared: PreparedIngest) -> ClaudeSessionMarker? {
        let origin = ClaudeTransportOrigin.remote(
            channel: ClaudeRemoteSessionScope.channel(hostID: prepared.hostID)
        )
        let snapshot = registry.ingest(
            prepared.record,
            origin: origin,
            snippets: prepared.snippets,
            environment: prepared.environment
        )
        // Shape only. A remote record carries the user's prompt and excerpts of
        // their code; a log is the wrong place for either.
        Log.claudeContext.debug(
            "Ingested remote \(prepared.record.event.rawValue, privacy: .public) from \(prepared.hostID, privacy: .public)"
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
    ///
    /// - Parameter deadline: an absolute `uptimeNanos()` value.
    private func readMore(fd: Int32, into buffer: inout Data, deadline: UInt64) -> Bool {
        let current = uptimeNanos()
        guard current < deadline else { return false }
        let remainingMillis = (deadline - current) / 1_000_000
        var descriptorPoll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        // Clamped: a deadline further out than ~24 days would overflow Int32 and
        // poll(2) reads a negative timeout as "block forever" — the one
        // behaviour this function exists to prevent.
        let timeout = Int32(min(remainingMillis, UInt64(Int32.max)))
        let ready = retryingOnEINTRInt32 { poll(&descriptorPoll, 1, timeout) }
        guard ready > 0 else { return false } // Timed out or failed: done either way.

        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        let count = retryingOnEINTRInt { read(fd, &chunk, chunk.count) }
        guard count > 0 else { return false } // EOF or error.
        buffer.append(contentsOf: chunk[0..<count])

        // Hard ceiling independent of the phase we are in: the most a
        // well-formed request can ever be. That is head + separator + body —
        // the CRLFCRLF terminating the head lives in this buffer too, and
        // omitting it made the ceiling one separator TIGHTER than a legitimate
        // maximum-sized request, so the largest requests we advertise as valid
        // were dropped mid-body.
        guard buffer.count <= Self.maxBufferedBytes(for: limits.http) else { return false }
        return true
    }

    /// The event a hook path names, when it names one this app knows.
    ///
    /// An unrecognized (or absent) event reads as `unknown` rather than as
    /// whatever the peer wrote: the path reached us bounded by the head limit,
    /// not by an allowlist, and echoing it into the log would put peer-chosen
    /// text there.
    static func knownEventLabel(inPath path: String) -> String {
        guard let name = ClaudeRemoteHTTPCodec.eventName(inPath: path),
              ClaudeHookEvent(rawValue: name) != nil
        else { return "unknown" }
        return name
    }

    /// The largest buffer a well-formed request can legitimately occupy.
    static func maxBufferedBytes(for http: ClaudeRemoteHTTPLimits) -> Int {
        http.maxHeadBytes + ClaudeRemoteHTTPCodec.headTerminator.count + http.maxBodyBytes
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
