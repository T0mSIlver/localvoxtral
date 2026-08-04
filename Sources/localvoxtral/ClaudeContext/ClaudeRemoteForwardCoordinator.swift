import Foundation
import Observation

/// Owns one `ClaudeRemoteForwardSupervisor` per host that opted in, and keeps
/// that set equal to what the registry says.
///
/// **Ordering with `ClaudeRemoteListenerCoordinator` is fixed and load-bearing:
/// the listener binds FIRST, forwards start second.** A forward is a pipe to
/// the listener's port; started before the bind, it terminates at a closed port
/// and every hook on the remote gets connection-refused — which fails open
/// silently, and makes the Mac's ssh client print `connect_to … failed.` into
/// the user's remote terminal on every dial. So this type refuses to run any
/// forward while the listener is not bound, and the app calls
/// `listenerCoordinator.reconcile()` before `forwards.reconcile()`.
///
/// The reverse order (stopping) is the mirror: revoking the last host stops the
/// forwards and then closes the port.
@MainActor
@Observable
public final class ClaudeRemoteForwardCoordinator {
    public typealias MakeSupervisor = @MainActor (ClaudeRemoteForwardSupervisor.Configuration) ->
        any ClaudeRemoteForwarding

    /// Per-host state for the pane, keyed by host id.
    public private(set) var states: [String: ClaudeRemoteForwardSupervisor.State] = [:]

    @ObservationIgnored private let hosts: ClaudeRemoteHostRegistry
    @ObservationIgnored private let isListenerBound: @MainActor () -> Bool
    @ObservationIgnored private let remoteForwardPort: UInt16
    @ObservationIgnored private let listenerPort: UInt16
    @ObservationIgnored private let makeSupervisor: MakeSupervisor
    @ObservationIgnored private var supervisors: [String: any ClaudeRemoteForwarding] = [:]

    public init(
        hosts: ClaudeRemoteHostRegistry,
        remoteForwardPort: UInt16,
        listenerPort: UInt16 = ClaudeRemoteListenerLimits.default.port,
        isListenerBound: @escaping @MainActor () -> Bool,
        makeSupervisor: MakeSupervisor? = nil
    ) {
        self.hosts = hosts
        self.remoteForwardPort = remoteForwardPort
        self.listenerPort = listenerPort
        self.isListenerBound = isListenerBound
        self.makeSupervisor = makeSupervisor ?? { configuration in
            ClaudeRemoteForwardSupervisor(
                configuration: configuration,
                launch: { try ClaudeRemoteForwardLiveProcess(argv: $0.argv) }
            )
        }
    }

    /// Which hosts should have a live forward right now.
    ///
    /// Three conditions, each of which has to hold: opted in, not revoked, and
    /// an alias we were actually told. A host with no alias on file is not
    /// guessable — the label is a different field and can name a different
    /// machine (PR #197) — so it cannot be forwarded, only re-enrolled.
    private func eligibleHosts() -> [ClaudeRemoteHost] {
        hosts.hosts().filter { host in
            host.persistentForwardEnabled
                && !host.isRevoked
                && host.sshHostAlias.map(ClaudeRemoteEnrollmentService.isValidHostAlias) == true
        }
    }

    /// Bring the running set in line with the registry. Idempotent: calling it
    /// twice starts nothing twice, which is what lets every mutation path call
    /// it unconditionally.
    public func reconcile() {
        guard isListenerBound() else {
            if !supervisors.isEmpty {
                Log.claudeContext.info(
                    "Claude remote forwards stopping: listener is not bound"
                )
                stopAll()
            }
            return
        }

        let eligible = eligibleHosts()
        let wanted = Set(eligible.map(\.id))

        // Snapshot the keys: `stop` mutates the dictionary being iterated.
        for hostID in Array(supervisors.keys) where !wanted.contains(hostID) {
            stop(hostID: hostID)
        }

        for host in eligible {
            guard supervisors[host.id] == nil, let alias = host.sshHostAlias else { continue }
            let supervisor = makeSupervisor(
                ClaudeRemoteForwardSupervisor.Configuration(
                    hostID: host.id,
                    sshHostAlias: alias,
                    remoteForwardPort: remoteForwardPort,
                    listenerPort: listenerPort
                )
            )
            supervisors[host.id] = supervisor
            states[host.id] = supervisor.state
            observe(supervisor, hostID: host.id)
            Log.claudeContext.info(
                "Claude remote forward starting for host \(host.id, privacy: .public)"
            )
            supervisor.start()
        }
    }

    /// The user's move after freeing a held port. Only a failed forward can be
    /// retried — there is nothing to retry about a healthy one.
    public func retry(hostID: String) {
        supervisors[hostID]?.retry()
        states[hostID] = supervisors[hostID]?.state
    }

    public func stopAll() {
        for hostID in Array(supervisors.keys) { stop(hostID: hostID) }
    }

    private func stop(hostID: String) {
        supervisors[hostID]?.onStateChange = nil
        supervisors[hostID]?.stop()
        supervisors[hostID] = nil
        states[hostID] = nil
        Log.claudeContext.info(
            "Claude remote forward stopped for host \(hostID, privacy: .public)"
        )
    }

    /// Mirror one supervisor's state into `states` so the pane can render it.
    ///
    /// A direct callback, not observation tracking: the pane must show the
    /// state the supervisor is IN, and `withObservationTracking`'s `onChange`
    /// fires before the new value is written — which makes every mirrored value
    /// one transition stale unless you hop a turn, and makes every test about
    /// it a race. The supervisor calls this synchronously from `transition`.
    private func observe(_ supervisor: any ClaudeRemoteForwarding, hostID: String) {
        supervisor.onStateChange = { [weak self] state in
            self?.states[hostID] = state
        }
    }
}
