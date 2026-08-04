import AppKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// What the resolver needs to know about cmux's focused surface.
///
/// `surfaceID` is `CMUX_SURFACE_ID`: minted by cmux and injected into the
/// surface's process environment — and, through its ssh relay, into the
/// environment of a `cmux ssh` shell on another host.
///
/// It is SESSION-SCOPED, not persistent: cmux re-mints surface ids when a
/// workspace is restored (its own `PanelStableSurfaceIdentity` notes that
/// `Panel/id` is "re-minted every time a panel is recreated, including session
/// restore", and the restart-stable id is a different value that is neither
/// exported to the environment nor returned on the socket). Nothing here is
/// durable for that reason: both sides of the match — the session's published
/// env and the socket's answer — come from the same cmux run, and a stale id
/// simply fails to match, because these are UUIDs and a re-minted one cannot
/// collide with an old one. `CMUX_WORKSPACE_ID` is equally volatile and is
/// deliberately never consulted.
struct CmuxFocusedSurface: Sendable, Equatable {
    var surfaceID: String
    /// The surface's controlling tty, when cmux reports one. Optional because a
    /// non-answer must stay distinguishable from a disagreement: the resolver
    /// cross-checks only when both sides know a tty.
    var tty: String?
    /// Whether the workspace HOSTING this surface is a live remote (`cmux ssh`)
    /// workspace, as cmux reports it right now. Nil when cmux would not say.
    ///
    /// This is the only remote-ness signal cmux exposes to a client, and it is
    /// deliberately read fresh per dictation. The surface node itself carries
    /// nothing: a `cmux ssh` surface is an ordinary `type: "terminal"` whose
    /// remoteness lives on the WORKSPACE (`workspace.remote.configure` stores
    /// it; `Workspace.isRemoteWorkspace` is `remoteConfiguration != nil`), so
    /// it takes a second method to see it. Nil is not "local" — it is "cmux did
    /// not answer", which the resolver treats as refusing every remote claim.
    var workspaceIsRemote: Bool?
}

/// One socket answer. Three cases rather than an optional because exactly one
/// failure — "the socket did not let us in" — is the user's to fix, and folding
/// it into a generic nil is how a fixable misconfiguration becomes an
/// unexplained silence.
enum CmuxQueryResult<Value: Sendable>: Sendable {
    case value(Value)
    /// The socket answered and refused us: password mode with no/wrong
    /// password, or the default `cmuxOnly` mode, where cmux checks peer
    /// ancestry and we are by construction not a cmux child.
    case authenticationRequired
    /// No socket, no answer, a malformed answer, a deadline, or an error that
    /// is not about credentials. Includes "cmux is not running", which is the
    /// common case and not an error.
    case unavailable
}

/// Equatable only where the payload is — the internal wire shapes this enum
/// also carries have no business gaining an equality just to be returned.
extension CmuxQueryResult: Equatable where Value: Equatable {}

/// The one short sentence the Settings row shows for the cmux socket. Details —
/// which method, which code — go to the log; the pane gets a sentence (owner
/// rule: never long text in the popover/pane).
enum CmuxSocketStatus: Sendable, Equatable {
    case ok
    case authenticationRequired
    case unavailable

    var message: String? {
        switch self {
        case .ok:
            return nil
        case .authenticationRequired:
            return "cmux socket requires password mode."
        case .unavailable:
            return "cmux socket not reachable."
        }
    }
}

/// Read-only access to cmux's control socket, as the join arm needs it.
///
/// Every call carries the pid the CONNECTED PEER must turn out to be — the
/// running cmux app the join is about. It is a required argument rather than
/// client state because it is a per-dictation fact (the frontmost app), and
/// because a credential must never be sent to a peer nobody named.
protocol CmuxSurfaceQuerying: Sendable {
    /// The surface the user is currently looking at.
    func focusedSurface(expectedPeerPID: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface>
    /// The visible text of EXACTLY `surfaceID`. Raw wire text: the caller owns
    /// sanitization, bounding, and every consent gate.
    func surfaceText(
        surfaceID: String, expectedPeerPID: pid_t
    ) async -> CmuxQueryResult<String>
}

#if canImport(Darwin)
/// Minimal read-only client for cmux's newline-delimited JSON control socket.
///
/// Hand-written against cmux's wire contract, never derived from its code: cmux
/// is GPL-3.0-or-later and this app is not. Everything below is the shape of the
/// messages (key names, method names, error codes), which is what interop needs
/// and all that was taken.
///
/// Verified against manaflow-ai/cmux @ 2026-08 (`Packages/macOS/CmuxControlSocket`,
/// `Sources/TerminalController*.swift`):
///
/// * **Framing** is one JSON object per line, terminated by a BARE `\n` — cmux's
///   line reader deliberately does not accept `\r\n`, and its encoder escapes
///   newlines so a response is always exactly one line.
/// * **Envelope** is not JSON-RPC: `{"id","method","params"}` in,
///   `{"id","ok":true,"result":…}` or `{"id","ok":false,"error":{"code","message"}}`
///   out, with `id` echoed verbatim. Malformed input gets a reply with NO `id`
///   at all, which is why the id check below tolerates its absence only by
///   failing.
/// * **Auth is per CONNECTION, not per message**: in `password` mode the first
///   line must be `auth.login`, and everything before it is answered
///   `auth_required`. So one connection carries the login and then the one
///   query, and is closed — the same one-exchange-per-connection discipline as
///   `HerdrSocketClient`, widened by exactly one line.
/// * cmux also drops idle connections after ~30 s and answers some refusals
///   with a NON-JSON `ERROR: …` line (access denied, verification failed) which
///   may be localized — hence the prefix match rather than a message compare.
struct CmuxSocketClient: CmuxSurfaceQuerying {
    private let socketPaths: [String]
    private let password: @Sendable () -> String?
    private let timeout: TimeInterval
    private let uptimeNanos: @Sendable () -> UInt64
    private let socketMetadata: @Sendable (String) -> ClaudeSocketGuard.PathMetadata?
    private let peerPID: @Sendable (Int32) -> pid_t?
    private let bundleIDOfRunningPID: @Sendable (pid_t) -> String?

    /// - Parameters:
    ///   - socketPaths: candidate control sockets, most specific first.
    ///     Injectable for tests; NEVER read from `CMUX_SOCKET_PATH` in our own
    ///     environment. We are not a cmux child, so that variable — if it is
    ///     set at all — describes whatever terminal launched US, and on a
    ///     `cmux ssh` remote it is not even a path (cmux sets it to a
    ///     `host:port` relay address there).
    ///   - password: the socket password, read lazily so a keychain lookup only
    ///     happens when a query actually runs. Nil means "send no login", which
    ///     is correct for cmux's non-password modes: `auth.login` is not a
    ///     method there, and sending it unconditionally would turn a working
    ///     `automation`-mode socket into `method_not_found`.
    ///   - timeout: one absolute deadline for the WHOLE exchange (connect,
    ///     login, request, response) — a per-phase budget would let each phase
    ///     spend it in turn.
    ///   - peerPID: reads `LOCAL_PEERPID` off a CONNECTED descriptor. Injected
    ///     so the impostor cases are testable — a test process cannot easily
    ///     arrange to be a different pid on the other end of its own socket.
    ///   - bundleIDOfRunningPID: LaunchServices' answer for which bundle a pid
    ///     is running. Injected for the same reason.
    init(
        socketPaths: [String] = CmuxSocketClient.defaultSocketPaths(),
        password: @escaping @Sendable () -> String? = { nil },
        timeout: TimeInterval = 1.0,
        uptimeNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        socketMetadata: @escaping @Sendable (String) -> ClaudeSocketGuard.PathMetadata? = {
            ClaudeSocketGuard.metadata(ofPath: $0)
        },
        peerPID: @escaping @Sendable (Int32) -> pid_t? = { CmuxSocketClient.localPeerPID($0) },
        bundleIDOfRunningPID: @escaping @Sendable (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
    ) {
        self.socketPaths = socketPaths
        self.password = password
        self.timeout = timeout
        self.uptimeNanos = uptimeNanos
        self.socketMetadata = socketMetadata
        self.peerPID = peerPID
        self.bundleIDOfRunningPID = bundleIDOfRunningPID
    }

    /// `LOCAL_PEERPID` for a connected AF_UNIX descriptor: the kernel's answer
    /// for which process is on the other end of THIS connection. Unlike a path
    /// check it cannot be raced — it describes the established connection, not
    /// a name that something else may since have rebound.
    ///
    /// Delegates to `ClaudeSocketGuard` rather than calling `getsockopt` again
    /// here. That one deliberately spells the two options numerically because
    /// the Darwin overlay does not export them; a second call site using the
    /// symbolic names would compile today and become a maintenance trap the
    /// moment the overlay differs, and two spellings of one syscall is one too
    /// many for a check the password depends on.
    static func localPeerPID(_ fd: Int32) -> pid_t? {
        ClaudeSocketGuard.peerPID(ofDescriptor: fd)
    }

    /// cmux's stable socket locations, in the order cmux itself prefers them.
    ///
    /// The public API docs still say `/tmp/cmux.sock`; the source says that is
    /// the LEGACY fallback and the release path is under the state directory,
    /// with a uid-scoped variant used when the shared path is taken by another
    /// user. All four are listed; the debug/nightly/staging sockets
    /// deliberately are NOT — joining a development build of someone else's
    /// terminal is not a thing this feature should do unasked.
    static func defaultSocketPaths() -> [String] {
        // cmux resolves its own state dir from the ACCOUNT home
        // (`homeDirectoryForCurrentUser`), independent of `$HOME`, so this
        // resolves the same way inside a shell that overrode it.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uid = geteuid()
        return [
            "\(home)/.local/state/cmux/cmux.sock",
            "\(home)/.local/state/cmux/cmux-\(uid).sock",
            "/tmp/cmux.sock",
            "/tmp/cmux-\(uid).sock",
        ]
    }

    func focusedSurface(expectedPeerPID: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface> {
        await Task.detached(priority: .userInitiated) { [self] in
            // Both requests ride ONE authenticated connection. Not just to save
            // a login: cmux authorizes per connection, so a second connection
            // would be a second login with the password sent twice, and — worse
            // — a second moment, in which the focused workspace could have
            // changed under the answer we are about to trust.
            openAuthenticated(
                expectedPeerPID: expectedPeerPID
            ) { fd, deadline -> CmuxQueryResult<CmuxFocusedSurface> in
                // `system.tree` answers the focus question in ONE request:
                // `active` is the same payload `system.identify` returns, and
                // the window walk carries each surface's tty.
                let treeOutcome = request(
                    fd: fd, deadline: deadline,
                    method: "system.tree", params: EmptyParams(),
                    resultType: SystemTreeResult.self
                )
                let tree: SystemTreeResult
                switch treeOutcome {
                case .value(let value): tree = value
                case .authenticationRequired: return .authenticationRequired
                case .unavailable: return .unavailable
                }
                guard let surfaceID = tree.active?.surfaceID, !surfaceID.isEmpty else {
                    Log.claudeContext.info(
                        "cmux focused-surface query abstained: no focused surface"
                    )
                    return .unavailable
                }
                // The tty is a cross-check the resolver REQUIRES; a surface
                // node we cannot find leaves it nil, and the resolver abstains
                // rather than joining on the id alone.
                let tty = tree.surface(id: surfaceID)?.tty
                let remoteHosting = tree.active?.workspaceID.flatMap {
                    workspaceIsRemote(fd: fd, deadline: deadline, workspaceID: $0)
                }
                return .value(
                    CmuxFocusedSurface(
                        surfaceID: surfaceID,
                        tty: tty,
                        workspaceIsRemote: remoteHosting
                    )
                )
            }
        }.value
    }

    /// Whether cmux currently considers `workspaceID` a live remote workspace.
    ///
    /// Returns nil — never false — when cmux does not answer cleanly, so "cmux
    /// said local" and "cmux said nothing" stay distinguishable all the way to
    /// the resolver, which refuses remote claims on either but only for the
    /// right reason.
    ///
    /// Both `enabled` and `connected` are required. A remote workspace whose
    /// link is down is not currently hosting anything, so a claim to own its
    /// surface is not evidence of anything either.
    private func workspaceIsRemote(
        fd: Int32, deadline: UInt64, workspaceID: String
    ) -> Bool? {
        let status = request(
            fd: fd, deadline: deadline,
            method: "workspace.remote.status",
            params: WorkspaceRemoteStatusParams(workspaceID: workspaceID),
            resultType: WorkspaceRemoteStatusResult.self
        )
        guard case .value(let status) = status, let remote = status.remote else {
            // An older cmux without the method, an error, a shape we do not
            // recognize: all "unknown", which fails closed downstream.
            Log.claudeContext.info("cmux workspace remote status unavailable")
            return nil
        }
        return remote.enabled && remote.connected
    }

    func surfaceText(
        surfaceID: String, expectedPeerPID: pid_t
    ) async -> CmuxQueryResult<String> {
        await Task.detached(priority: .userInitiated) { [self] in
            // `scrollback` is sent explicitly false — that is cmux's default,
            // but this caller DEPENDS on getting the viewport rather than the
            // history, and the default is theirs to change. `lines` is
            // deliberately never sent: in cmux it IMPLIES `scrollback: true`,
            // so the parameter that looks like a bound is actually a request
            // for more.
            let outcome = openAuthenticated(expectedPeerPID: expectedPeerPID) { fd, deadline in
                request(
                    fd: fd, deadline: deadline,
                    method: "surface.read_text",
                    params: SurfaceReadTextParams(surfaceID: surfaceID),
                    resultType: SurfaceReadTextResult.self
                )
            }
            switch outcome {
            case .authenticationRequired:
                return .authenticationRequired
            case .unavailable:
                return .unavailable
            case .value(let read):
                // The response must be ABOUT the surface that was asked for. A
                // server answering about any other surface is invalid, and its
                // text must never be attributed to the joined surface.
                guard read.surfaceID == surfaceID else {
                    Log.claudeContext.info(
                        "cmux surface read abstained: response names a different surface"
                    )
                    return .unavailable
                }
                return .value(read.text)
            }
        }.value
    }

    // MARK: - Exchange

    /// Opens ONE peer-authenticated, logged-in connection and runs `body` on
    /// it. Every request a query needs must happen inside that closure — the
    /// connection closes when it returns.
    private func openAuthenticated<Value: Sendable>(
        expectedPeerPID: pid_t,
        _ body: (Int32, UInt64) -> CmuxQueryResult<Value>
    ) -> CmuxQueryResult<Value> {
        let deadline = makeDeadline()
        guard let fd = connectToSoleSocket(
            deadline: deadline, expectedPeerPID: expectedPeerPID
        ) else {
            return .unavailable
        }
        defer { close(fd) }

        // Login FIRST and on this same connection: cmux authorizes the
        // connection, not the message, and answers everything before the login
        // with `auth_required`. By here the peer is already PROVEN to be the
        // cmux process this join is about (`connectToSoleSocket`), which is the
        // precondition for the password leaving this process at all.
        if let password = password() {
            switch login(fd: fd, password: password, deadline: deadline) {
            case .ok:
                break
            case .authenticationRequired:
                return .authenticationRequired
            case .unavailable:
                return .unavailable
            }
        }
        return body(fd, deadline)
    }

    /// One request/response on an already-authenticated connection.
    private func request<Params: Encodable, Result: Decodable>(
        fd: Int32,
        deadline: UInt64,
        method: String,
        params: Params,
        resultType: Result.Type
    ) -> CmuxQueryResult<Result> {
        let request = Request(id: Self.requestID(), method: method, params: params)
        guard let line = send(fd: fd, request: request, deadline: deadline) else {
            return .unavailable
        }
        return decode(line: line, id: request.id, resultType: resultType)
    }

    private enum LoginOutcome {
        case ok
        case authenticationRequired
        case unavailable
    }

    private func login(fd: Int32, password: String, deadline: UInt64) -> LoginOutcome {
        let request = Request(
            id: Self.requestID(),
            method: "auth.login",
            params: AuthLoginParams(password: password)
        )
        guard let line = send(fd: fd, request: request, deadline: deadline) else {
            return .unavailable
        }
        switch decode(line: line, id: request.id, resultType: AuthLoginResult.self) {
        case .value(let result):
            guard result.authenticated else {
                Log.claudeContext.info("cmux login refused: server did not confirm authentication")
                return .authenticationRequired
            }
            return .ok
        case .authenticationRequired:
            return .authenticationRequired
        case .unavailable:
            // A line ARRIVED and was not a well-formed confirmation: no
            // `result`, no `authenticated` field, an id that does not answer
            // this request, an unrecognized error. Only an explicit
            // `authenticated: true` may be read as a login, so everything else
            // is an authentication failure rather than a generic abstention —
            // the distinction matters because it is the difference between
            // telling the user to fix their cmux auth mode and silently
            // dropping the join with no reason. (A transport failure, where no
            // line arrives at all, is still `.unavailable`: that is a dead
            // socket, not a refusal.)
            Log.claudeContext.info("cmux login refused: response was not a valid confirmation")
            return .authenticationRequired
        }
    }

    /// Decodes one response line into a result, classifying every failure.
    ///
    /// The credential-shaped error codes are the ones the user can act on;
    /// everything else — including a non-JSON `ERROR: …` line, which is what
    /// cmux's default `cmuxOnly` mode sends before closing on us — is folded
    /// into the same actionable answer, because "switch cmux to password mode"
    /// is the fix for all of them. Anything else is an abstention.
    private func decode<Result: Decodable>(
        line: Data,
        id: String,
        resultType: Result.Type
    ) -> CmuxQueryResult<Result> {
        if Self.isPlainTextError(line) {
            // Deliberately not matched on the message: cmux localizes these,
            // so only the `ERROR:` prefix is contractual.
            Log.claudeContext.info("cmux query refused: socket denied access before authentication")
            return .authenticationRequired
        }
        guard let envelope = try? JSONDecoder().decode(
            Envelope<Result>.self, from: line
        ) else {
            Log.claudeContext.info("cmux query abstained: unreadable response")
            return .unavailable
        }
        guard envelope.id == id else {
            // cmux omits `id` entirely on parse errors, and echoes it verbatim
            // otherwise. A mismatch means this line is not our answer.
            Log.claudeContext.info("cmux query abstained: response does not answer this request")
            return .unavailable
        }
        if let code = envelope.errorCode {
            // The code is SERVER-CONTROLLED text. A hostile peer can put
            // anything in it — including the password we just sent it — so only
            // a code we recognize is ever logged verbatim; everything else is
            // logged as a constant. A credential must not be laundered into the
            // unified log through an error field.
            if Self.authenticationErrorCodes.contains(code) {
                Log.claudeContext.info("cmux query refused: \(code, privacy: .public)")
                return .authenticationRequired
            }
            if Self.knownErrorCodes.contains(code) {
                Log.claudeContext.info("cmux query abstained: error \(code, privacy: .public)")
            } else {
                Log.claudeContext.info("cmux query abstained: unrecognized error code")
            }
            return .unavailable
        }
        guard let result = envelope.result else {
            Log.claudeContext.info("cmux query abstained: response carried no result")
            return .unavailable
        }
        return .value(result)
    }

    /// `auth_unconfigured` is in here on purpose: it means the socket IS in
    /// password mode and the user has not set a password — squarely the same
    /// "fix your cmux settings" answer as a rejected one.
    private static let authenticationErrorCodes: Set<String> = [
        "auth_required", "auth_failed", "auth_unconfigured",
    ]

    /// The rest of cmux's documented codes. Membership is the ONLY thing that
    /// makes a code loggable — see `decode(line:id:resultType:)`.
    private static let knownErrorCodes: Set<String> = [
        "invalid_params", "method_not_found", "not_found", "internal_error",
        "unsupported", "timeout",
    ]

    private static func isPlainTextError(_ line: Data) -> Bool {
        line.starts(with: Array("ERROR:".utf8))
    }

    // MARK: - Transport

    /// Connects to the ONE cmux socket we are sure about, and PROVES who is on
    /// the other end before returning it.
    ///
    /// The path checks below are a cheap pre-filter and nothing more. They are
    /// inherently TOCTOU — `lstat` names a path, and between that call and
    /// `connect` any process running as this user can unlink it and bind its
    /// own socket there, which then passes an owner check trivially because it
    /// IS owned by this user. The legacy `/tmp` candidates make that easy: a
    /// same-user process only has to get there while the real cmux socket is
    /// elsewhere or absent. So the authoritative check is on the ESTABLISHED
    /// connection (`LOCAL_PEERPID`), which names the process actually holding
    /// the other end and cannot be raced by a later rebind.
    ///
    /// Two things must hold, and both are about the app the user is LOOKING at:
    /// the peer's pid must be `expectedPeerPID` — the frontmost cmux
    /// application this dictation already resolved — and LaunchServices must
    /// still say that pid is running the cmux bundle. The second is not
    /// redundant: it fails closed if the pid died and was recycled between the
    /// join resolving and this connection.
    ///
    /// Deliberately NOT a code-signature check. `SecCode`'s signing identifier
    /// is not guaranteed to equal the bundle identifier, so requiring equality
    /// would silently kill the feature against a legitimately signed cmux whose
    /// identifiers differ, and a signature we do not pin to a specific team
    /// proves little that the pid identity does not already prove. What the pid
    /// binding gives is stronger than a signature check anyway: the peer must
    /// be the exact process macOS reports as frontmost.
    ///
    /// A candidate that connects but does not authenticate is DROPPED rather
    /// than counted, so an impostor cannot manufacture the "multiple live
    /// sockets" ambiguity either. If two candidates both authenticate as the
    /// same expected pid, that is one process listening twice, which is fine
    /// and takes the first.
    private func connectToSoleSocket(deadline: UInt64, expectedPeerPID: pid_t) -> Int32? {
        var authenticated: [Int32] = []
        var connectedCount = 0
        for path in socketPaths {
            guard path.hasPrefix("/"),
                  let metadata = socketMetadata(path),
                  metadata.isSocket,
                  metadata.ownerUID == UInt32(geteuid())
            else { continue }
            guard let fd = openConnection(to: path, deadline: deadline) else { continue }
            connectedCount += 1
            if isExpectedPeer(fd: fd, expectedPeerPID: expectedPeerPID) {
                authenticated.append(fd)
            } else {
                close(fd)
            }
        }
        guard let fd = authenticated.first else {
            // Outcome only: a socket path is a live handle and never belongs in
            // the unified log.
            Log.claudeContext.info(
                "cmux query abstained: \(connectedCount == 0 ? "no reachable socket" : "no socket answered as the focused cmux process", privacy: .public)"
            )
            return nil
        }
        for extra in authenticated.dropFirst() { close(extra) }
        return fd
    }

    /// Whether the process on the other end of `fd` is the cmux app this join
    /// is about. Nothing may be written to the socket before this returns true.
    private func isExpectedPeer(fd: Int32, expectedPeerPID: pid_t) -> Bool {
        guard let peer = peerPID(fd) else {
            Log.claudeContext.info("cmux peer check failed: peer pid unavailable")
            return false
        }
        guard peer == expectedPeerPID else {
            // Count-only: a pid is not secret, but naming the impostor's pid in
            // the log invites treating this as a diagnostic rather than a
            // refusal. The outcome is the fact that matters.
            Log.claudeContext.info(
                "cmux peer check failed: socket is held by another process, not the focused cmux app"
            )
            return false
        }
        guard bundleIDOfRunningPID(peer) == TerminalScreenAllowlist.cmuxBundleID else {
            Log.claudeContext.info(
                "cmux peer check failed: peer pid is no longer running the cmux bundle"
            )
            return false
        }
        return true
    }

    /// One request line out, one response line back. The connection stays open
    /// afterwards because the login and the query share it.
    private func send(fd: Int32, request: some Encodable, deadline: UInt64) -> Data? {
        guard let requestLine = try? Self.encodedLine(request) else { return nil }
        guard writeAll(fd: fd, data: requestLine, deadline: deadline) else {
            Log.claudeContext.info("cmux query abstained: request deadline or write failure")
            return nil
        }
        guard let response = readLine(fd: fd, deadline: deadline) else {
            Log.claudeContext.info(
                "cmux query abstained: response deadline, framing, or size failure"
            )
            return nil
        }
        return response
    }

    private func openConnection(to socketPath: String, deadline: UInt64) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard makeNonBlocking(fd) else {
            close(fd)
            return nil
        }
        // A failed SO_NOSIGPIPE is fatal to the CALLER, not just this query: a
        // peer closing mid-write would then SIGPIPE the whole app (the same
        // class of crash as the FileHandle field bug, PR #60). Abstain instead.
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            close(fd)
            return nil
        }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status == 0 { return fd }
        guard errno == EINPROGRESS || errno == EINTR,
              wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
        else {
            close(fd)
            return nil
        }

        // Writability also reports a failed non-blocking connect. SO_ERROR is
        // the only authoritative completion result.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0
        else {
            close(fd)
            return nil
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data, deadline: UInt64) -> Bool {
        data.withUnsafeBytes { raw in
            // Zero-length Data has a nil baseAddress; an empty write is
            // vacuously complete, not a failure.
            if raw.isEmpty { return true }
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                        return false
                    }
                    continue
                }
                return false
            }
            return true
        }
    }

    private func readLine(fd: Int32, deadline: UInt64) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            guard wait(fd: fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            // Read at most one byte beyond the advertised line cap: that byte
            // is needed to distinguish an exactly-capped line followed by `\n`
            // from an oversized one, but no peer can make the buffer grow by
            // whole extra chunks past the limit.
            let remainingThroughSentinel = Self.maxResponseLineBytes + 1 - buffer.count
            guard remainingThroughSentinel > 0 else { return nil }
            let readCapacity = min(chunk.count, remainingThroughSentinel)
            let count = Darwin.read(fd, &chunk, readCapacity)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return nil
            }
            guard count > 0 else { return nil } // A response must be newline-terminated.
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
                guard lineLength <= Self.maxResponseLineBytes else { return nil }
                return Data(buffer[buffer.startIndex..<newline])
            }
            guard buffer.count <= Self.maxResponseLineBytes else { return nil }
        }
    }

    private func wait(fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            let current = uptimeNanos()
            guard current < deadline else { return false }
            let remaining = deadline - current
            let roundedMillis = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            let timeoutMillis = Int32(min(roundedMillis, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, timeoutMillis)
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }

    private func makeDeadline() -> UInt64 {
        // A finite defensive ceiling keeps an injected infinity/NaN or absurd
        // duration from trapping during the Double→UInt64 conversion; it does
        // not widen the production budget.
        let boundedSeconds = timeout.isFinite ? min(max(0, timeout), 60) : 0
        let duration = UInt64(boundedSeconds * 1_000_000_000)
        let (deadline, overflow) = uptimeNanos().addingReportingOverflow(duration)
        return overflow ? UInt64.max : deadline
    }

    private func makeNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func requestID() -> String {
        "lvx-" + UUID().uuidString.lowercased()
    }

    private static func encodedLine(_ request: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(request)
        // A BARE newline: cmux's line reader skips a `\n` preceded by `\r`, so
        // CRLF framing would never complete a line and the request would hang
        // until the deadline.
        data.append(0x0A)
        return data
    }

    /// Generous relative to a viewport read, and finite. cmux returns the
    /// screen text TWICE (`text` plus a base64 copy of the same bytes) and caps
    /// nothing server-side, so the ceiling is what keeps a huge buffer from
    /// becoming our memory.
    static let maxResponseLineBytes = 1024 * 1024

    // MARK: - Wire shapes

    private struct Request<Params: Encodable>: Encodable {
        var id: String
        var method: String
        var params: Params
    }

    /// cmux treats missing/non-object `params` as empty, but sends it anyway:
    /// an explicit empty object is one fewer thing that depends on their
    /// leniency.
    private struct EmptyParams: Encodable {}

    private struct AuthLoginParams: Encodable {
        var password: String
    }

    private struct WorkspaceRemoteStatusParams: Encodable {
        var workspaceID: String

        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    }

    /// `workspace.remote.status` — only the two fields that decide whether a
    /// workspace is CURRENTLY hosting a remote session are decoded. The rest of
    /// that payload (destination, ports, transport, daemon) names another
    /// machine and is deliberately never retained.
    private struct WorkspaceRemoteStatusResult: Decodable {
        var remote: Remote?

        struct Remote: Decodable {
            var enabled: Bool
            var connected: Bool

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Absent means "not remote" for `enabled`, but a MISSING
                // `connected` must not read as connected.
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? false
            }

            enum CodingKeys: String, CodingKey { case enabled, connected }
        }
    }

    private struct SurfaceReadTextParams: Encodable {
        var surfaceID: String
        /// Viewport, not history. See `surfaceText(surfaceID:)`.
        var scrollback = false

        enum CodingKeys: String, CodingKey {
            case surfaceID = "surface_id"
            case scrollback
        }
    }

    private struct Envelope<Result: Decodable>: Decodable {
        var id: String?
        var result: Result?
        var errorCode: String?

        enum CodingKeys: String, CodingKey { case id, ok, result, error }
        enum ErrorKeys: String, CodingKey { case code }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Echoed verbatim, and absent entirely on cmux's parse errors. Only
            // a String matches what we send; anything else is not our answer.
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            let ok = try container.decode(Bool.self, forKey: .ok)
            if ok {
                result = try container.decodeIfPresent(Result.self, forKey: .result)
                errorCode = nil
            } else {
                result = nil
                let error = try container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
                errorCode = try error.decode(String.self, forKey: .code)
            }
        }
    }

    private struct AuthLoginResult: Decodable {
        var authenticated: Bool
    }

    /// `system.tree` — only the fields this client validates or consumes.
    private struct SystemTreeResult: Decodable {
        var active: Active?
        var windows: [Window]?

        /// The focused payload, identical in shape to `system.identify`'s.
        struct Active: Decodable {
            var surfaceID: String?
            /// The workspace hosting the focused surface — the only handle
            /// through which remote-ness can be asked about at all.
            var workspaceID: String?

            enum CodingKeys: String, CodingKey {
                case surfaceID = "surface_id"
                case workspaceID = "workspace_id"
            }
        }

        struct Window: Decodable {
            var workspaces: [Workspace]?
        }

        struct Workspace: Decodable {
            var panes: [Pane]?
        }

        struct Pane: Decodable {
            var surfaces: [Surface]?
        }

        struct Surface: Decodable {
            var id: String
            /// Null for surfaces with no pty (a browser surface, say).
            var tty: String?
        }

        /// The surface node with this id, wherever in the tree it sits.
        func surface(id: String) -> Surface? {
            for window in windows ?? [] {
                for workspace in window.workspaces ?? [] {
                    for pane in workspace.panes ?? [] {
                        if let match = (pane.surfaces ?? []).first(where: { $0.id == id }) {
                            return match
                        }
                    }
                }
            }
            return nil
        }
    }

    /// `surface.read_text` success. `base64` (a second copy of `text`) is
    /// deliberately not decoded.
    private struct SurfaceReadTextResult: Decodable {
        var text: String
        var surfaceID: String

        enum CodingKeys: String, CodingKey {
            case text
            case surfaceID = "surface_id"
        }
    }
}
#endif
