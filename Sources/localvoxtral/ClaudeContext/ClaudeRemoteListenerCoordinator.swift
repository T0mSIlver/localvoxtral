import ClaudeContextWire
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
    /// Connections turned away since launch, by category. Settings turns a
    /// nonzero count into one short, actionable line — the failure this
    /// diagnoses used to be visible only in the unified log.
    var rejectionSnapshot: ClaudeRemoteRejectionTally.Snapshot { get }

    /// Bring the listener AND the cached sessions in line with the registry:
    /// bind if a host is now enrolled, stop if the last one just went away, and
    /// forget the context of any host that is no longer active.
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
///
/// It owns the SESSION registry for the same reason it owns the listener: a
/// host that is revoked or removed must stop being a source of context, and
/// closing the door on new records is only half of that — the records it
/// already published are still cached, still joinable by marker, until TTL.
/// Enrollment is the fact; both the port and the cache are consequences of it,
/// so they are reconciled together rather than by two owners who can disagree.
@MainActor
public final class ClaudeRemoteListenerCoordinator: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    private let sessions: ClaudeSessionRegistry
    private let makeListener:
        @MainActor (ClaudeRemoteHostRegistry, ClaudeRemoteRejectionTally) -> ClaudeRemoteContextListener
    private var listener: ClaudeRemoteContextListener?
    /// Held HERE, not in the listener, because `reconcile` replaces the listener
    /// object on every 0→1 transition. A tally that lived in the listener would
    /// forget a night of rejections the moment the user enrolled another host.
    private let rejections = ClaudeRemoteRejectionTally()

    /// - Parameter makeListener: handed the tally as well as the registry, so
    ///   every listener this coordinator builds reports into the SAME counters.
    public init(
        hosts: ClaudeRemoteHostRegistry,
        sessions: ClaudeSessionRegistry,
        makeListener: @escaping @MainActor (
            ClaudeRemoteHostRegistry, ClaudeRemoteRejectionTally
        ) -> ClaudeRemoteContextListener
    ) {
        self.hosts = hosts
        self.sessions = sessions
        self.makeListener = makeListener
    }

    public convenience init(hosts: ClaudeRemoteHostRegistry, sessions: ClaudeSessionRegistry) {
        self.init(hosts: hosts, sessions: sessions) { registry, rejections in
            ClaudeRemoteContextListener(registry: sessions, hosts: registry, rejections: rejections)
        }
    }

    public var isListening: Bool { listener?.isRunning ?? false }
    public var boundPort: UInt16 { listener?.port ?? ClaudeRemoteListenerLimits.default.port }
    public var rejectionSnapshot: ClaudeRemoteRejectionTally.Snapshot { rejections.snapshot() }

    public func reconcile() throws {
        // Before the listener, and unconditionally: a bind that throws must not
        // be the reason a revoked host's context stayed cached. This is also why
        // it is here rather than at the revoke/remove call sites — reconcile is
        // already what every enrollment change funnels through, and a rule
        // enforced in one place cannot be forgotten at a second one.
        evictSessionsOfInactiveHosts()

        if hosts.hasActiveHosts {
            guard !isListening else { return }
            // A listener that died on its own (a failed poll) reports
            // `isRunning == false` while `listener` is still non-nil, so this
            // deliberately builds a fresh one rather than restarting the corpse.
            let listener = makeListener(hosts, rejections)
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

    /// Drop cached context for every host that is no longer active.
    ///
    /// Phrased as "keep only what an active host published" rather than "delete
    /// what host X published", so it is correct for revoke, for remove, and for
    /// a launch that finds hosts gone from the file — and so a host that
    /// vanished by some route nobody has thought of yet still loses its cache.
    /// A revoked host is inactive: the entry survives so the user can rotate it
    /// back, but its credential does not, and neither does its context.
    ///
    /// Local sessions and sessions from other remote transports are not
    /// candidates — so an empty registry evicting every SSH-host session is the
    /// intent, not collateral damage.
    private func evictSessionsOfInactiveHosts() {
        let active = Set(
            hosts.hosts()
                .filter { !$0.isRevoked }
                .map { ClaudeRemoteSessionScope.channel(hostID: $0.id) }
        )
        let evicted = sessions.evictRemoteSessions(notIn: active)
        if evicted > 0 {
            Log.claudeContext.info(
                "Evicted \(evicted, privacy: .public) Claude session(s) for inactive remote hosts"
            )
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
