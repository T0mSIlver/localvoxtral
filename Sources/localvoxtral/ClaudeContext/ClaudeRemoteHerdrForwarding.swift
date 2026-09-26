import ClaudeContextWire
import Foundation
import Synchronization

/// A spawned, long-lived child process, reduced to what the forward needs of
/// it.
///
/// Deliberately NOT `ClaudeRemoteEnrollmentService.Runner`: that seam is
/// run-to-completion (argv in, exit code out), and an `ssh -N` that returns is
/// an ssh that is no longer forwarding anything. This one is spawn/observe/kill.
protocol ClaudeRemoteHerdrForwardProcess: ClaudeRemoteForwardProcess, AnyObject {
    var processIdentifier: pid_t { get }
    /// SIGTERM, then SIGKILL if it does not go. Idempotent.
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
/// A dictation-scoped lease on an app-owned forward. The stop-side `pane.read`
/// needs the same local socket the start side used, so the lease lasts for the
/// whole dictation. `close()` is idempotent and `deinit` calls it; releasing the
/// last lease starts the service's injected-clock idle policy rather than
/// killing a healthy process immediately.
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

    private let isProcessRunning: @Sendable () -> Bool
    private let closeEveryTime: @Sendable () -> Void
    private let closeOnce: @Sendable () -> Void
    private let closed = Mutex(false)

    init(
        workspace: ClaudeRemoteHerdrForwardWorkspace,
        process: any ClaudeRemoteHerdrForwardProcess,
        removeWorkspace: @escaping @Sendable (ClaudeRemoteHerdrForwardWorkspace) -> Void
    ) {
        self.localSocketPath = workspace.socketPath
        self.isProcessRunning = { process.isRunning }
        self.closeEveryTime = { process.terminate() }
        self.closeOnce = {
            removeWorkspace(workspace)
            Log.claudeContext.info("Remote herdr forward closed")
        }
    }

    init(
        localSocketPath: String,
        isRunning: @escaping @Sendable () -> Bool,
        release: @escaping @Sendable () -> Void
    ) {
        self.localSocketPath = localSocketPath
        self.isProcessRunning = isRunning
        self.closeEveryTime = {}
        self.closeOnce = release
    }

    var isRunning: Bool { isProcessRunning() }

    func close() {
        // ALWAYS, before the idempotence guard: `terminate()` is itself
        // idempotent, and it is the production RETRY path for a collection that
        // failed earlier. Gating it behind "already closed" meant a failed reap
        // could only ever be retried by a test calling `terminate()` twice —
        // deinit's `close()` was a no-op, so production had no second attempt
        // at all (review round 7).
        closeEveryTime()
        let alreadyClosed = closed.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !alreadyClosed else { return }
        closeOnce()
    }

    deinit { close() }
}

/// Protocol the resolver depends on, so the join arm can be tested without any
/// notion of processes at all.
@MainActor
protocol ClaudeRemoteHerdrForwarding: AnyObject {
    func open(alias: String, remoteSocketPath: String) async -> ClaudeRemoteHerdrForwardHandle?
}
