import Foundation

/// Keeps the remote listener's bound/unbound state in step with the host
/// registry.
///
/// A protocol rather than the concrete listener, so the Settings model — which
/// decides WHEN to reconcile — is testable without binding a real port. A unit
/// test that had to open 8473 would be a port conflict against the developer's
/// own running app, and against the other tests in the same suite.
@MainActor
public protocol ClaudeRemoteListenerControlling: AnyObject {
    var isListening: Bool { get }
    var boundPort: UInt16 { get }

    /// Bring the listener in line with the registry: bind if a host is now
    /// enrolled, stop if the last one just went away.
    ///
    /// Idempotent — the callers are UI actions, and the user is entitled to
    /// press a button twice.
    func reconcile() throws
}

#if canImport(Darwin)

/// The production coordinator.
///
/// It owns the listener because the *lifetime* question ("is a port bound?") and
/// the *enrollment* question ("is anyone enrolled?") have exactly one correct
/// answer between them, and splitting them across two owners is how they drift.
///
/// Note what `reconcile` does NOT do: it does not rebind when a host is added to
/// an already-listening listener. The listener authenticates against the
/// registry live, on every request, so a host enrolled a moment ago already
/// works. Only the 0→1 and 1→0 transitions move a socket, which is also why
/// "enrolling a second host briefly drops the first host's tunnel" is not a
/// thing that can happen.
@MainActor
public final class ClaudeRemoteListenerCoordinator: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    private let makeListener: @MainActor (ClaudeRemoteHostRegistry) -> ClaudeRemoteContextListener
    private var listener: ClaudeRemoteContextListener?

    public init(
        hosts: ClaudeRemoteHostRegistry,
        makeListener: @escaping @MainActor (ClaudeRemoteHostRegistry) -> ClaudeRemoteContextListener
    ) {
        self.hosts = hosts
        self.makeListener = makeListener
    }

    public convenience init(hosts: ClaudeRemoteHostRegistry, sessions: ClaudeSessionRegistry) {
        self.init(hosts: hosts) { registry in
            ClaudeRemoteContextListener(registry: sessions, hosts: registry)
        }
    }

    public var isListening: Bool { listener?.isRunning ?? false }
    public var boundPort: UInt16 { listener?.port ?? ClaudeRemoteListenerLimits.default.port }

    public func reconcile() throws {
        if hosts.hasActiveHosts {
            guard !isListening else { return }
            // A listener that died on its own (a failed poll) reports
            // `isRunning == false` while `listener` is still non-nil, so this
            // deliberately builds a fresh one rather than restarting the corpse.
            let listener = makeListener(hosts)
            try listener.start()
            self.listener = listener
        } else {
            guard let listener else { return }
            // stop() waits for the accept loop to exit, so a revoke immediately
            // followed by an enroll cannot race itself for the port.
            listener.stop()
            self.listener = nil
        }
    }

    /// Called at app teardown. Separate from `reconcile` because quitting is not
    /// a statement about enrollment — the hosts stay enrolled for next launch.
    public func shutdown() {
        listener?.stop()
        listener = nil
    }
}

#endif
