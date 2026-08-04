import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
import Synchronization

/// A spawned, long-lived child process, reduced to what the forward needs of
/// it.
///
/// Deliberately NOT `ClaudeRemoteEnrollmentService.Runner`: that seam is
/// run-to-completion (argv in, exit code out), and an `ssh -N` that returns is
/// an ssh that is no longer forwarding anything. This one is spawn/observe/kill.
protocol ClaudeRemoteHerdrForwardProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// SIGTERM, then SIGKILL if it does not go. Idempotent.
    func terminate()
}

/// Spawns the forward's child process. Injected everywhere, defaulted nowhere:
/// a test that forgets it must not be able to dial a real host.
protocol ClaudeRemoteHerdrForwardSpawning: Sendable {
    func spawn(argv: [String]) throws -> any ClaudeRemoteHerdrForwardProcess
}

/// Where the forward's local socket lives: a freshly created, private
/// directory, used once and removed.
struct ClaudeRemoteHerdrForwardWorkspace: Sendable, Equatable {
    var directoryPath: String
    var socketPath: String

    init(directoryPath: String, socketPath: String) {
        self.directoryPath = directoryPath
        self.socketPath = socketPath
    }
}

protocol ClaudeRemoteHerdrWorkspaceProviding: Sendable {
    /// A NEW directory every call. Never reuses a path: a socket path that
    /// could already exist is a socket path someone else could have created.
    func makeWorkspace() throws -> ClaudeRemoteHerdrForwardWorkspace
    func remove(_ workspace: ClaudeRemoteHerdrForwardWorkspace)
}

/// An open `ssh -L` forward to one remote herdr socket.
///
/// Owned by the dictation that opened it and closed when that dictation is
/// done with it — the stop-side `pane.read` needs the same tunnel the start
/// side used, so the lifetime is the whole dictation and not one request.
/// `close()` is idempotent and `deinit` calls it, so a join dropped on a path
/// nobody thought about still takes the ssh child and the socket with it.
final class ClaudeRemoteHerdrForwardHandle: Sendable, Equatable {
    /// Identity, not value: two handles are the same forward only when they ARE
    /// the same object. This exists so `ClaudeSessionJoin` can stay `Equatable`
    /// while owning one.
    static func == (lhs: ClaudeRemoteHerdrForwardHandle, rhs: ClaudeRemoteHerdrForwardHandle) -> Bool {
        lhs === rhs
    }

    /// The LOCAL end of the forward — an AF_UNIX socket on this machine, owned
    /// by this user, created by our own ssh child. That is what makes it
    /// dialable by `HerdrSocketClient`'s unchanged local-socket guard.
    let localSocketPath: String

    private let workspace: ClaudeRemoteHerdrForwardWorkspace
    private let process: any ClaudeRemoteHerdrForwardProcess
    private let removeWorkspace: @Sendable (ClaudeRemoteHerdrForwardWorkspace) -> Void
    private let closed = Mutex(false)

    init(
        workspace: ClaudeRemoteHerdrForwardWorkspace,
        process: any ClaudeRemoteHerdrForwardProcess,
        removeWorkspace: @escaping @Sendable (ClaudeRemoteHerdrForwardWorkspace) -> Void
    ) {
        self.localSocketPath = workspace.socketPath
        self.workspace = workspace
        self.process = process
        self.removeWorkspace = removeWorkspace
    }

    var isRunning: Bool { process.isRunning }

    func close() {
        let alreadyClosed = closed.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !alreadyClosed else { return }
        process.terminate()
        // The socket is ssh's to unlink on a clean exit, but a killed ssh
        // leaves it behind — and the directory is ours either way.
        removeWorkspace(workspace)
        Log.claudeContext.info("Remote herdr forward closed")
    }

    deinit { close() }
}

/// Opens an on-demand `ssh -L` tunnel to a REMOTE herdr's JSON socket.
///
/// Why an app-managed forward at all: herdr's socket protocol is happy over a
/// forwarded stream, but nothing on the user's machine forwards it — the
/// enrollment tunnel is a RemoteForward carrying hook events the other way. So
/// the join arm dials out for exactly as long as one dictation needs it.
///
/// Every live capability is a seam, and the two that matter most are the
/// clock and the sleep: readiness is a poll, and a poll with a real clock in it
/// is a test that sleeps.
struct ClaudeRemoteHerdrForwardService: ClaudeRemoteHerdrForwarding {
    /// How long a forward has to become dialable before it is abandoned.
    ///
    /// This is on the dictation-start path, so it is a latency ceiling as much
    /// as a correctness one: a host that is asleep or unreachable must cost a
    /// beat, not a stall. Two seconds is roughly four times a LAN ssh
    /// handshake and still short enough to be invisible against the model
    /// connect that follows.
    static let defaultReadinessTimeout: TimeInterval = 2.0

    private let spawner: any ClaudeRemoteHerdrForwardSpawning
    private let workspaces: any ClaudeRemoteHerdrWorkspaceProviding
    private let isSocketDialable: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let sleepFor: @Sendable (TimeInterval) async -> Void
    private let readinessTimeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        spawner: any ClaudeRemoteHerdrForwardSpawning,
        workspaces: any ClaudeRemoteHerdrWorkspaceProviding,
        isSocketDialable: @escaping @Sendable (String) -> Bool = {
            ClaudeRemoteHerdrForwardService.dial($0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        sleepFor: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        readinessTimeout: TimeInterval = ClaudeRemoteHerdrForwardService.defaultReadinessTimeout,
        pollInterval: TimeInterval = 0.025
    ) {
        self.spawner = spawner
        self.workspaces = workspaces
        self.isSocketDialable = isSocketDialable
        self.now = now
        self.sleepFor = sleepFor
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
    }

    /// Spawn the tunnel and wait for its local end to answer, or nil.
    ///
    /// Both inputs are validated HERE rather than at the call site, because
    /// this is the last place before they become argv. `remoteSocketPath` in
    /// particular arrived as an HTTP header from another machine
    /// (`ClaudeRemoteSessionEnvironment.herdrSocketPath`) and is a LABEL: it is
    /// never handed to `FileManager`, never `stat`ed, never opened — the only
    /// thing that ever happens to it is being passed through to `ssh`, which
    /// resolves it on the host that named it.
    func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle? {
        guard ClaudeRemoteEnrollmentService.isValidHostAlias(alias) else {
            Log.claudeContext.info("Remote herdr forward refused: invalid host alias")
            return nil
        }
        guard Self.isForwardableRemoteSocketPath(remoteSocketPath) else {
            Log.claudeContext.info("Remote herdr forward refused: unusable remote socket path")
            return nil
        }

        let workspace: ClaudeRemoteHerdrForwardWorkspace
        do {
            workspace = try workspaces.makeWorkspace()
        } catch {
            Log.claudeContext.error(
                "Remote herdr forward failed: private socket directory unavailable (\(String(describing: error), privacy: .public))"
            )
            return nil
        }
        guard Self.isUsableLocalSocketPath(workspace.socketPath) else {
            Log.claudeContext.error("Remote herdr forward failed: local socket path unusable")
            workspaces.remove(workspace)
            return nil
        }

        let process: any ClaudeRemoteHerdrForwardProcess
        do {
            process = try spawner.spawn(
                argv: Self.argv(
                    alias: alias,
                    localSocketPath: workspace.socketPath,
                    remoteSocketPath: remoteSocketPath
                )
            )
        } catch {
            Log.claudeContext.error(
                "Remote herdr forward failed to spawn: \(String(describing: error), privacy: .public)"
            )
            workspaces.remove(workspace)
            return nil
        }

        let handle = ClaudeRemoteHerdrForwardHandle(
            workspace: workspace,
            process: process,
            removeWorkspace: { [workspaces] in workspaces.remove($0) }
        )

        let deadline = now().addingTimeInterval(max(0, readinessTimeout))
        while now() < deadline {
            // An ssh that has already exited will never open the socket, and
            // its exit is the common failure (auth refused, host down,
            // BatchMode with no key). Noticing it is what turns a 2 s stall
            // into a prompt abstention.
            guard handle.isRunning else {
                Log.claudeContext.info("Remote herdr forward abstained: ssh exited before readiness")
                handle.close()
                return nil
            }
            if isSocketDialable(workspace.socketPath) {
                Log.claudeContext.info("Remote herdr forward ready")
                return handle
            }
            await sleepFor(pollInterval)
        }
        Log.claudeContext.info("Remote herdr forward abstained: readiness timeout")
        handle.close()
        return nil
    }

    /// The exact argv. Assembled in one static function so a test can assert
    /// every token of it — this is a command line built partly from a remote
    /// machine's strings, and "what exactly do we run" must be answerable
    /// without reading the spawn path.
    ///
    /// Two options the design review asked for are deliberately ABSENT, both
    /// falsified against OpenSSH 10.0 before this shipped:
    ///
    /// * `ClearAllForwardings=yes` clears forwardings "specified in the
    ///   configuration files OR ON THE COMMAND LINE", and the clearing runs
    ///   after all option parsing — so it deletes the very `-L` this exists
    ///   for. Measured: with it, the local socket is never created; without
    ///   it, it appears.
    /// * `ExitOnForwardFailure=yes` would make the ENROLLED host's own
    ///   `RemoteForward 8473` — which the user's live interactive session is
    ///   normally already holding — a fatal error for this connection.
    ///   Measured: with it, ssh exits ("Error: remote port forwarding failed");
    ///   without it, the collision is a warning and the local forward stays up.
    ///   That collision is not an edge case: it is the exact situation this
    ///   feature runs in. Readiness is proven by dialing the socket instead,
    ///   which is stronger than a flag anyway.
    ///
    /// `ControlPath=none` is present for lifetime hygiene: over a shared
    /// master the forward would belong to the user's long-lived connection
    /// rather than to our child, and killing our child would not be a
    /// teardown. It costs one handshake per dictation.
    static func argv(
        alias: String,
        localSocketPath: String,
        remoteSocketPath: String
    ) -> [String] {
        [
            "ssh", "-N",
            "-o", "BatchMode=yes",
            "-o", "ControlPath=none",
            // The connection still inherits the ALIAS's own `Host` block, and
            // two of its settings would break this child's containment
            // (review finding 5), so both are overridden here rather than
            // hoped about:
            //   * ForkAfterAuthentication would detach ssh into a process this
            //     Process object no longer tracks — a tunnel we could neither
            //     observe nor kill, i.e. an orphan per dictation;
            //   * PermitLocalCommand + LocalCommand would run a command on THIS
            //     machine every time we open a tunnel, which is not something a
            //     dictation should be able to trigger.
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=no",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            // `--` ends option parsing; the alias is validated above and cannot
            // begin with `-`, and this makes any alias that somehow did a
            // failed connection rather than a silently accepted option.
            "--", alias,
        ]
    }

    /// Whether a remote socket path may be pasted into `-L`.
    ///
    /// The charset is PR #216's header allowlist, re-applied at the point of
    /// use: the listener already dropped anything outside it, and this is the
    /// half that does not depend on that having happened. On top of it:
    ///
    /// * absolute, because a relative herdr socket path is not a thing and a
    ///   bare word could be read as a port;
    /// * no `:`, because `-L` is a COLON-SEPARATED spec — a colon in the
    ///   remote path would re-split the argument into a different forward;
    /// * no leading `-` (implied by the absolute rule, asserted anyway) so it
    ///   can never be read as an option.
    static func isForwardableRemoteSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("-") else { return false }
        guard !path.contains(":") else { return false }
        return ClaudeRemoteEnvironmentCodec.isAcceptableValue(path)
    }

    /// `sun_path` is 104 bytes on Darwin including the terminator, and a path
    /// that does not fit produces a socket nothing can dial — a failure worth
    /// naming rather than discovering as a readiness timeout.
    static let maxLocalSocketPathBytes = 100

    static func isUsableLocalSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(":")
            && !path.isEmpty && path.utf8.count <= maxLocalSocketPathBytes
    }

    /// Live readiness: can this AF_UNIX path be connected to right now?
    ///
    /// Existence is not enough. A killed ssh leaves the socket FILE behind, and
    /// `-L` onto a path that cannot be bound leaves ssh running with no
    /// listener at all — both look identical to `lstat`. A successful connect
    /// proves only the LOCAL listener, which is the point: what is on the other
    /// end is then re-proven by the herdr response itself.
    static func dial(_ socketPath: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return status == 0
    }
}

/// Protocol the resolver depends on, so the join arm can be tested without any
/// notion of processes at all.
protocol ClaudeRemoteHerdrForwarding: Sendable {
    func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle?
}

// MARK: - Live implementations

/// `posix_spawn`-backed spawn that puts the child in its OWN process group.
///
/// Not `Process`, and the reason is teardown: Foundation gives no way to set a
/// process group, so `terminate()` could only ever signal the one pid it knows.
/// ssh under some configurations leaves descendants behind (and re-execs
/// itself), so a group leader plus `kill(-pgid)` is what makes "close the
/// tunnel" mean the whole tunnel (review finding 5). The child is its own group
/// leader, so the negative pid can only ever reach OUR ssh and its children.
///
/// stdout/stderr go to `/dev/null` on purpose: ssh is chatty on stderr
/// (host-key notices, forwarding warnings) and reading a child's pipe is how
/// this app crashed in the field once already (PR #60). Nothing here needs
/// ssh's words — the socket either answers or it does not.
struct ClaudeRemoteHerdrForwardSpawner: ClaudeRemoteHerdrForwardSpawning {
    /// Absolute, exactly like the enrollment runner's: a PATH lookup for the
    /// program we hand another machine's socket path to is not a lookup worth
    /// having.
    var executablePath = "/usr/bin/ssh"
    /// Injected so a test can spawn something observable instead of ssh.
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func spawn(argv: [String]) throws -> any ClaudeRemoteHerdrForwardProcess {
        guard !argv.isEmpty else { throw SpawnError.emptyArgv }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // pgroup 0 with SETPGROUP: the child's process group id becomes its own
        // pid, so it leads a group containing only itself and its descendants.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        // The environment is passed explicitly rather than inherited through a
        // global: ssh needs HOME to find the alias's config at all, and an
        // empty envp would make every forward fail in a way that looks like a
        // dead host.
        let arguments = argv.map { strdup($0) } + [nil]
        let environmentStrings = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            environmentStrings.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(
            &pid, executablePath, &fileActions, &attributes, arguments, environmentStrings
        )
        guard status == 0, pid > 1 else { throw SpawnError.launchFailed(code: status) }
        return LiveHerdrForwardProcess(pid: pid)
    }

    enum SpawnError: Error, Equatable {
        case emptyArgv
        case launchFailed(code: Int32)
    }
}

/// A spawned forward, tracked by pid and torn down by process GROUP.
final class LiveHerdrForwardProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    /// Short on purpose. This is our own `ssh -N`: it installs no SIGTERM
    /// handler and dies at once, and the call runs on user-visible exit paths
    /// (a cancelled dictation, app quit) where seconds of blocking would be
    /// felt. SIGKILL to the group follows immediately after.
    static let gracePeriod: TimeInterval = 0.25

    /// Everything teardown has to agree about, in one lock.
    private struct State {
        /// The group leader has exited. Its zombie still reserves the pid.
        var leaderExited = false
        /// The child has been collected — from here `-pid` may name a stranger.
        var reaped = false
        /// Signals actually delivered to the group, so a test can prove none is
        /// sent after the reap.
        var groupSignalsSent = 0
    }

    private let pid: pid_t
    private let exited = DispatchSemaphore(value: 0)
    private let state = Mutex(State())
    private let source: any DispatchSourceProcess

    init(pid: pid_t) {
        self.pid = pid
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility)
        )
        self.source = source
        source.setEventHandler { [weak self] in self?.noteExit() }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    var isRunning: Bool { !state.withLock { $0.leaderExited } }

    /// The group leader's pid. Exposed so the teardown test can kill the LEADER
    /// alone and prove that a dead leader does not suppress the group SIGKILL —
    /// the exact shape of the bug this guards.
    var leaderPID: pid_t { pid }

    /// Test seams for the reuse guard: how many signals reached the group, and
    /// whether the child has been collected.
    var groupSignalsSent: Int { state.withLock { $0.groupSignalsSent } }
    var hasBeenReaped: Bool { state.withLock { $0.reaped } }

    /// SIGTERM the group, wait a beat for the LEADER, SIGKILL the group
    /// unconditionally — and only then reap.
    ///
    /// Two rules pull against each other here, and the reap order is what
    /// satisfies both:
    ///
    /// * The final kill must NOT be gated on the leader being alive (review
    ///   round 3). We observe only the leader, so its exit satisfies
    ///   `waitForExit` while a descendant that ignored SIGTERM is still holding
    ///   the tunnel; a liveness guard suppressed exactly the signal that clears
    ///   it.
    /// * We must NEVER signal a group we have already reaped (review round 4).
    ///   A pid is reserved only while the child is unreaped; once reaped the
    ///   kernel may hand that pid to a new process — as a new group leader with
    ///   that pgid — and `kill(-pid)` would then hit a stranger. The window is
    ///   real: a tunnel that exits by itself mid-dictation is reaped, and stop
    ///   time calls `close()` seconds later.
    ///
    /// So the exit source does not reap; it only records and wakes the waiter.
    /// The zombie it leaves is what RESERVES the pid (and with it the pgid) for
    /// as long as we might still need to signal the group. Teardown signals,
    /// then reaps, and every later call is a no-op. Cost: one zombie per open
    /// forward, for the life of one dictation.
    func terminate() {
        // Not gated on `isRunning`: the leader may be gone while its group is
        // not. It IS gated on not-yet-reaped, which is the only thing that
        // makes `-pid` still mean our group.
        guard signalGroupIsSafe else {
            reapIfNeeded()
            return
        }
        _ = ClaudePluginInstallService.terminateBounded(
            gracePeriod: Self.gracePeriod,
            // Negative pid = the whole process group. The child is its own
            // group leader (POSIX_SPAWN_SETPGROUP), so this cannot reach
            // anything we did not spawn.
            terminate: { self.signalGroup(SIGTERM) },
            kill: { self.signalGroup(SIGKILL) },
            // The child's own exit event, not a poll: a spin would be a wall
            // clock in production code as much as in a test.
            waitForExit: { window in
                self.exited.wait(timeout: .now() + max(window, 0)) == .success
            }
        )
        // Unconditional within the un-reaped window: the leader going quietly
        // says nothing about the rest of its group.
        signalGroup(SIGKILL)
        reapIfNeeded()
    }

    /// Whether `-pid` still names OUR process group.
    private var signalGroupIsSafe: Bool { !state.withLock { $0.reaped } }

    /// Signal the whole group, refusing once the pid could have been reused.
    /// Counted so a test can prove no signal is sent after the reap.
    private func signalGroup(_ signal: Int32) {
        let sent = state.withLock { current -> Bool in
            guard !current.reaped else { return false }
            current.groupSignalsSent += 1
            return true
        }
        guard sent else { return }
        _ = Darwin.kill(-pid, signal)
    }

    /// Collect the child, once. After this the pid is the kernel's to reuse,
    /// which is precisely why nothing may signal the group afterwards.
    private func reapIfNeeded() {
        let shouldReap = state.withLock { current -> Bool in
            guard !current.reaped else { return false }
            current.reaped = true
            return true
        }
        guard shouldReap else { return }
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        source.cancel()
    }

    /// Record the leader's exit and wake the waiter. Deliberately does NOT
    /// reap: the zombie is what keeps `-pid` meaning our group until teardown
    /// has finished signalling it.
    private func noteExit() {
        state.withLock { $0.leaderExited = true }
        exited.signal()
    }
}

/// Private per-forward directory under the user's own temporary directory.
///
/// Not Application Support: `sun_path` is 104 bytes, and
/// `~/Library/Application Support/localvoxtral/...` plus a unique name is close
/// enough to that ceiling that a long user name would break it. Not `/tmp`
/// either — that is world-writable, and while the unpredictable name and the
/// 0700 mode would carry it, the per-user temporary directory is 0700 by the
/// OS and shorter. The directory is created fresh (never reused, never
/// "repaired"), validated with the same lstat rules as the broker's run
/// directory, and removed on close.
struct ClaudeRemoteHerdrForwardWorkspaces: ClaudeRemoteHerdrWorkspaceProviding {
    var base: String = NSTemporaryDirectory()
    var makeName: @Sendable () -> String = { UUID().uuidString.prefix(8).lowercased() }

    func makeWorkspace() throws -> ClaudeRemoteHerdrForwardWorkspace {
        let directory = (base as NSString)
            .appendingPathComponent("lvx-herdr-fwd-\(makeName())")
        // withIntermediateDirectories: false — the create must FAIL if the path
        // already exists, so an attacker-planted directory is an error rather
        // than a socket we hand to ssh.
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard let metadata = ClaudeSocketGuard.metadata(ofPath: directory),
              ClaudeSocketGuard.validateDirectory(
                metadata, path: directory, expectedUID: UInt32(geteuid())
              ) == nil
        else {
            try? FileManager.default.removeItem(atPath: directory)
            throw WorkspaceError.directoryNotPrivate
        }
        return ClaudeRemoteHerdrForwardWorkspace(
            directoryPath: directory,
            socketPath: (directory as NSString).appendingPathComponent("h.sock")
        )
    }

    func remove(_ workspace: ClaudeRemoteHerdrForwardWorkspace) {
        unlink(workspace.socketPath)
        try? FileManager.default.removeItem(atPath: workspace.directoryPath)
    }

    enum WorkspaceError: Error, Equatable {
        case directoryNotPrivate
    }
}
#endif
