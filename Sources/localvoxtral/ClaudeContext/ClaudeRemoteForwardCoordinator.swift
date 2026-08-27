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

    /// Fired after `states` changes, naming the host that changed.
    ///
    /// Settings renders COPIES of these rows, so a dictionary the pane never
    /// hears about is a pane frozen on whatever it sampled when it appeared —
    /// which for a tunnel means it shows "Connecting…" forever and never the
    /// `.forwarding`, `.retrying` or failure that followed. A push, not a
    /// timer: transitions are rare and a Settings pane redrawing on a schedule
    /// is a cost with no reader.
    @ObservationIgnored public var onStateChange: (@MainActor (String) -> Void)?

    /// Teardowns still draining, keyed by host. A replacement forward for the
    /// same host waits on its entry: the remote port is not free until the old
    /// ssh has actually exited, and dialing it early reports `portUnavailable`
    /// at ourselves.
    /// Identified rather than compared: `Task` is a struct, so "is this still
    /// the teardown I was waiting on" needs a token of its own.
    @ObservationIgnored private var pendingTeardowns: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    @ObservationIgnored private let hosts: ClaudeRemoteHostRegistry
    @ObservationIgnored private let isListenerBound: @MainActor () -> Bool
    @ObservationIgnored private let remoteForwardPort: UInt16
    @ObservationIgnored private let listenerPort: UInt16
    @ObservationIgnored private let makeSupervisor: MakeSupervisor
    @ObservationIgnored private var supervisors: [String: any ClaudeRemoteForwarding] = [:]

    /// Whether the launch-time orphan reap has run yet. Forwards may not start
    /// before it finishes: the orphan holds exactly the remote port the new
    /// forward is about to dial, so starting early reproduces the "Port held"
    /// state the reap exists to clear.
    private enum OrphanReapPhase { case pending, running, done }
    @ObservationIgnored private var orphanReap: OrphanReapPhase
    @ObservationIgnored private let reapOrphans: (@Sendable () async -> Void)?

    public init(
        hosts: ClaudeRemoteHostRegistry,
        remoteForwardPort: UInt16,
        listenerPort: UInt16 = ClaudeRemoteListenerLimits.default.port,
        isListenerBound: @escaping @MainActor () -> Bool,
        makeSupervisor: MakeSupervisor? = nil,
        pidLedger: ClaudeRemoteForwardPidLedger? = nil,
        reapOrphans: (@Sendable () async -> Void)? = nil
    ) {
        self.hosts = hosts
        self.remoteForwardPort = remoteForwardPort
        self.listenerPort = listenerPort
        self.isListenerBound = isListenerBound
        self.reapOrphans = reapOrphans
        // No reaper means nothing to wait for — the seam's absence must not
        // stall every forward forever.
        self.orphanReap = reapOrphans == nil ? .done : .pending
        self.makeSupervisor = makeSupervisor ?? { configuration in
            ClaudeRemoteForwardSupervisor(
                configuration: configuration,
                launch: { config in
                    let process = try ClaudeRemoteForwardLiveProcess(argv: config.argv)
                    // Written BEFORE the process is handed to the supervisor:
                    // if this app dies without applicationWillTerminate, the
                    // record is what lets the next launch find and kill the
                    // orphan instead of reporting "Port held" at it.
                    if let pidLedger,
                       let record = ClaudeRemoteForwardProcessIdentity.snapshot(
                           pid: process.processIdentifier
                       )
                    {
                        pidLedger.remember(hostID: config.hostID, record: record)
                    }
                    return process
                }
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

        // Orphans from a previous run die BEFORE the first forward dials. The
        // gate sits after the listener check on purpose: only the instance
        // holding the listener port gets here, so a second app instance can
        // never reap the first one's healthy tunnels.
        switch orphanReap {
        case .running:
            return
        case .pending:
            guard let reapOrphans else {
                orphanReap = .done
                break
            }
            orphanReap = .running
            Log.claudeContext.info(
                "Claude remote forwards waiting for the orphan reap before first start"
            )
            Task { @MainActor [weak self] in
                await reapOrphans()
                guard let self else { return }
                self.orphanReap = .done
                self.reconcile()
            }
            return
        case .done:
            break
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
            setState(supervisor.state, hostID: host.id)
            observe(supervisor, hostID: host.id)
            Log.claudeContext.info(
                "Claude remote forward starting for host \(host.id, privacy: .public)"
            )
            // Registered synchronously above (so nothing starts this host
            // twice), started only once the previous ssh for the SAME host has
            // finished dying. Toggling off and straight back on is the ordinary
            // way a user hits this, and the old process still holds the remote
            // bind for as long as it takes to honour SIGTERM.
            if let draining = pendingTeardowns[host.id] {
                let hostID = host.id
                Task { @MainActor [weak self, weak supervisor] in
                    await draining.task.value
                    guard let self, self.pendingTeardowns[hostID]?.id == draining.id else { return }
                    self.pendingTeardowns[hostID] = nil
                    // Still the current supervisor for this host? A reconcile
                    // during the wait may have retired it already.
                    guard let supervisor, self.supervisors[hostID] === supervisor else { return }
                    supervisor.start()
                }
            } else {
                supervisor.start()
            }
        }
    }

    /// The user's move after freeing a held port. Only a failed forward can be
    /// retried — there is nothing to retry about a healthy one.
    public func retry(hostID: String) {
        supervisors[hostID]?.retry()
        setState(supervisors[hostID]?.state, hostID: hostID)
    }

    public func stopAll() {
        for hostID in Array(supervisors.keys) { stop(hostID: hostID) }
    }

    /// Every teardown still draining, for a caller that must not return until
    /// the ssh processes are gone (app termination).
    public var drainingTeardowns: [Task<Void, Never>] { pendingTeardowns.values.map(\.task) }

    private func stop(hostID: String) {
        supervisors[hostID]?.onStateChange = nil
        supervisors[hostID]?.stop()
        // Keep the escalation, not the supervisor: the port stays bound until
        // this finishes, and the next start for this host must wait for it.
        if let teardown = supervisors[hostID]?.teardown {
            pendingTeardowns[hostID] = (id: UUID(), task: teardown)
        }
        supervisors[hostID] = nil
        setState(nil, hostID: hostID)
        Log.claudeContext.info(
            "Claude remote forward stopped for host \(hostID, privacy: .public)"
        )
    }

    private func setState(_ state: ClaudeRemoteForwardSupervisor.State?, hostID: String) {
        states[hostID] = state
        onStateChange?(hostID)
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
            self?.setState(state, hostID: hostID)
        }
    }
}
