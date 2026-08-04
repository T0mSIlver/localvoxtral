import Foundation
import Observation
import Synchronization

/// One long-lived `ssh -N -R` process, as a seam.
///
/// A protocol rather than `Process` for the reason the backend supervisor
/// cannot claim: that one spawns a local binary a test can write itself, while
/// this one spawns **ssh against a real host**. No unit test may do that — not
/// slowly, not flakily, not at all — so the process is injected and the tests
/// drive a fake.
public protocol ClaudeRemoteForwardProcess: Sendable {
    /// stderr, line by line, finishing when the process does.
    ///
    /// stderr is not diagnostics here, it is the PRODUCT: `remote port
    /// forwarding failed` is the only thing that distinguishes "another machine
    /// holds this port" from any other reason ssh exited.
    var standardErrorLines: AsyncStream<String> { get }
    /// Resumes with the exit status once the process ends.
    func waitUntilExit() async -> Int32
    /// Ask it to stop (SIGTERM). Must be safe to call more than once, and after
    /// exit.
    func terminate()
    /// Make it stop (SIGKILL), for a process that ignored `terminate()`. Same
    /// safety contract: idempotent, and harmless after exit.
    ///
    /// Separate from `terminate()` because the supervisor must be able to
    /// ESCALATE. An ssh that is wedged — a dead network with unacked data in
    /// flight, a host that stopped answering — holds the remote bind and this
    /// Mac's file descriptors, and asking it politely a second time achieves
    /// nothing.
    func forceTerminate()
}

/// Keeps one enrolled host's SSH `RemoteForward` up, without an interactive
/// session holding it.
///
/// Why this exists: hook events only reach the Mac while SOMETHING holds the
/// forward. A person's own ssh session does that for their own terminal work —
/// but a harness-spawned session (t3 code, `claude remote-control` services,
/// any headless runner on the enrolled host) has no such terminal, so its
/// events go nowhere and the user sees dictation quietly ungrounded.
///
/// Deliberate differences from `BackendProcessSupervisor`:
///
/// * `ExitOnForwardFailure=yes`. The enrollment ssh block sets `no` on purpose
///   — a dictation nicety must never cost you a shell. This process IS the
///   nicety and nothing else: a forward it cannot bind is a process with no
///   remaining purpose, so the exit is the detection signal we want rather
///   than a session we would be protecting.
/// * A bind failure is TERMINAL, not a restart. Something else holds that port
///   (see issue #215) and will keep holding it; retrying on a timer would be a
///   connection storm, an auth-log full of sessions, and possibly a fail2ban
///   ban — all while the user is told nothing. One clear failed state, with the
///   fix in it, beats an infinite retry that hides the cause.
/// * NO `ClearAllForwardings`. It was here to stop this process inheriting the
///   alias's own `RemoteForward` and requesting the port twice — and it does
///   that, but it ALSO clears the `-R` given on the command line, which is the
///   only forward this process exists to create. `ssh -G` is the instrument:
///   with the flag, the effective config contains `clearallforwardings yes`
///   and NO `remoteforward` line at all, so the supervised ssh connects,
///   survives its settle window, reports "Tunnel up." and forwards nothing.
///   The doubling it was guarding against does not happen anyway: an
///   IDENTICAL forward on the command line and in the config collapses to one
///   `remoteforward` entry (measured). What does survive is a forward for a
///   DIFFERENT port left in an old config block — see `staleConfiguredForward`.
/// * Containment, because this connection is made with the user's ssh config
///   and any of it can be set per-Host: `ForkAfterAuthentication=no` (a
///   backgrounded ssh leaves the tracked `Process`, keeps the remote bind and
///   its stderr pipe, and can be killed by nothing we hold), `ControlPath=none`
///   (a multiplexed session can outlive the process that started it, and
///   `ControlPersist` is designed to), `PermitLocalCommand=no` (an inherited
///   `LocalCommand` would run on this Mac on every reconnect).
/// What the coordinator actually depends on.
///
/// A protocol so a test can drive the coordinator's decisions — which hosts get
/// a forward, and when — without a supervisor that would spawn ssh. The
/// supervisor's own behavior has its own suite, against a fake process.
@MainActor
public protocol ClaudeRemoteForwarding: AnyObject {
    var state: ClaudeRemoteForwardSupervisor.State { get }
    var onStateChange: (@MainActor (ClaudeRemoteForwardSupervisor.State) -> Void)? { get set }
    /// The in-flight SIGTERM→SIGKILL escalation, if `stop()` started one.
    /// Whoever dials this host's port next has to wait for it.
    var teardown: Task<Void, Never>? { get }
    func start()
    func stop()
    func retry()
}

@MainActor
@Observable
public final class ClaudeRemoteForwardSupervisor: ClaudeRemoteForwarding {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        case forwarding
        case retrying(attempt: Int)
        /// The remote refused the bind: someone else holds the port.
        case portUnavailable
        /// The remote refused a bind for a port this supervisor never asked
        /// for — so the alias's ssh config block still declares an old
        /// `RemoteForward`, which we inherit and `ExitOnForwardFailure=yes`
        /// then kills us over. Distinct from `portUnavailable` because the fix
        /// is the opposite: nothing on the host needs freeing, the user's own
        /// config needs updating.
        case staleConfiguredForward(port: UInt16)
        case failed(summary: String)

        /// One short sentence for the pane (owner rule: no long text in the
        /// popover, and a Settings status line has the same problem). Full
        /// detail — the ssh stderr tail — goes to the log, never here.
        public var text: String {
            switch self {
            case .stopped: return "Off."
            case .connecting: return "Connecting…"
            case .forwarding: return "Tunnel up."
            case .retrying(let attempt): return "Reconnecting (attempt \(attempt))."
            // Names the thing to close. The overwhelmingly common holder is an
            // ssh session from THIS Mac — the user's own terminal, or one a
            // harness left behind — and the previous copy ("Port already held
            // on the host.") left them with a Retry button that could only
            // fail again. Still one sentence, by the popover rule.
            case .portUnavailable: return "Port held — close ssh sessions to that host."
            case .staleConfiguredForward: return "Old RemoteForward in ~/.ssh/config blocks this."
            case .failed: return "Tunnel stopped."
            }
        }

        public var isFailure: Bool {
            switch self {
            case .stopped, .connecting, .forwarding, .retrying: return false
            case .portUnavailable, .staleConfiguredForward, .failed: return true
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var hostID: String
        public var sshHostAlias: String
        /// The port bound on the REMOTE host — this Mac's allocation.
        public var remoteForwardPort: UInt16
        /// The port the app listens on HERE. The forward's target.
        public var listenerPort: UInt16
        /// After this many consecutive failed connections, stop and say so. A
        /// tunnel that has failed five times in a row is not one more retry
        /// away from working, and an unbounded loop against someone's SSH
        /// server is not a thing to ship.
        public var maxConsecutiveFailures: Int
        /// How long a freshly launched ssh must stay alive before the pane is
        /// allowed to call the tunnel up. Measured on the supervisor's injected
        /// clock, never the wall.
        public var settleDelay: Duration
        /// How long a connection must have been UP for its eventual drop to
        /// count as an isolated incident rather than part of a run of
        /// failures.
        ///
        /// Deliberately much longer than `settleDelay`. Surviving the settle
        /// window only means ssh did not refuse the bind; a tunnel that
        /// connects, holds for three seconds and dies, over and over, is
        /// exactly the reconnect storm `maxConsecutiveFailures` exists to stop,
        /// and treating each of those as "healthy" would make the cap
        /// unreachable.
        public var healthyUptime: Duration
        /// How long a process gets to honour SIGTERM before SIGKILL. Measured
        /// on the injected clock.
        public var terminationGrace: Duration
        /// How long to keep watching after SIGKILL before giving up and saying
        /// so in the log. A process in an uninterruptible wait can outlive even
        /// this; pretending otherwise is how a teardown blocks forever.
        public var killGrace: Duration

        public init(
            hostID: String,
            sshHostAlias: String,
            remoteForwardPort: UInt16,
            listenerPort: UInt16,
            maxConsecutiveFailures: Int = 5,
            settleDelay: Duration = .seconds(2),
            healthyUptime: Duration = .seconds(60),
            terminationGrace: Duration = .seconds(2),
            killGrace: Duration = .seconds(1)
        ) {
            self.hostID = hostID
            self.sshHostAlias = sshHostAlias
            self.remoteForwardPort = remoteForwardPort
            self.listenerPort = listenerPort
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.settleDelay = settleDelay
            self.healthyUptime = healthyUptime
            self.terminationGrace = terminationGrace
            self.killGrace = killGrace
        }

        /// The complete argv. No token is involved anywhere on this path — the
        /// credential lives in the remote plugin's config, and this process only
        /// carries bytes for it.
        ///
        /// `--` terminates option parsing: the alias is validated before a
        /// supervisor is ever built, and this makes an alias that somehow got
        /// through a failed connection rather than a silently accepted option
        /// (the `-V` lesson from PR #197).
        public var argv: [String] {
            [
                "ssh", "-N",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                // Containment — see the type comment. These are forced rather
                // than assumed because every one of them is settable per-Host
                // in the config this connection reads.
                "-o", "ForkAfterAuthentication=no",
                "-o", "ControlPath=none",
                "-o", "PermitLocalCommand=no",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-R", "\(remoteForwardPort):127.0.0.1:\(listenerPort)",
                "--", sshHostAlias,
            ]
        }
    }

    public typealias Launch = @MainActor (Configuration) throws -> any ClaudeRemoteForwardProcess
    public typealias SleepClosure = @Sendable (Duration) async throws -> Void
    public typealias NowClosure = @MainActor () -> Date

    public private(set) var state: State = .stopped

    /// Called synchronously on every transition, on the main actor. The
    /// coordinator mirrors state into the pane through this rather than through
    /// observation tracking, whose `onChange` fires before the write lands.
    @ObservationIgnored public var onStateChange: (@MainActor (State) -> Void)?

    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored private let launch: Launch
    @ObservationIgnored private let sleepFor: SleepClosure
    @ObservationIgnored private let now: NowClosure
    @ObservationIgnored private var superviseTask: Task<Void, Never>?
    @ObservationIgnored private var currentProcess: (any ClaudeRemoteForwardProcess)?
    @ObservationIgnored private var stoppingIntentionally = false
    /// Bumped per launch AND the moment a process is known dead. The settle
    /// task carries the generation it belongs to, so a stale one cannot report
    /// a dead process as up.
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Consecutive failures, on the INSTANCE rather than in `supervise()`, so
    /// the settle task can clear it the moment a connection proves healthy.
    @ObservationIgnored private var consecutiveFailures = 0
    /// The in-flight SIGTERM→SIGKILL escalation, if any. Exposed so whoever
    /// replaces this supervisor can wait for the port to actually be released
    /// before dialing it again.
    @ObservationIgnored public private(set) var teardown: Task<Void, Never>?

    public init(
        configuration: Configuration,
        launch: @escaping Launch,
        sleepFor: @escaping SleepClosure = { try await Task.sleep(for: $0) },
        now: @escaping NowClosure = { Date() }
    ) {
        self.configuration = configuration
        self.launch = launch
        self.sleepFor = sleepFor
        self.now = now
    }

    public func start() {
        guard superviseTask == nil else { return }
        stoppingIntentionally = false
        consecutiveFailures = 0
        Log.claudeContext.info(
            "Claude remote forward start requested for host \(self.configuration.hostID, privacy: .public) port \(self.configuration.remoteForwardPort, privacy: .public)"
        )
        transition(to: .connecting)
        superviseTask = Task { @MainActor [weak self] in
            await self?.supervise()
        }
    }

    public func stop() {
        guard !stoppingIntentionally else { return }
        stoppingIntentionally = true
        Log.claudeContext.info(
            "Claude remote forward stop requested for host \(self.configuration.hostID, privacy: .public)"
        )
        superviseTask?.cancel()
        superviseTask = nil
        // Any settle window belongs to a process we are about to kill.
        invalidateSettleWindow()
        let process = currentProcess
        currentProcess = nil
        transition(to: .stopped)
        guard let process else {
            teardown = nil
            return
        }
        // SIGTERM goes NOW, synchronously. Deferring it into the task below
        // would put a scheduling hop between the user's click and the signal,
        // for no benefit: it is the WAITING that has to be asynchronous.
        process.terminate()
        // Escalation runs on its own task because `stop()` has synchronous
        // callers (app termination, the pane's toggle) and none of them may
        // block the main thread for the grace window. What they CAN do is wait
        // on `teardown` — and the coordinator does, before replacing this
        // supervisor with one that dials the same port.
        teardown = Task { @MainActor [weak self] in
            await self?.tearDown(process)
        }
    }

    /// SIGTERM, bounded wait, SIGKILL, bounded wait. No unbounded wait
    /// anywhere: an ssh wedged on a dead network is exactly the case this
    /// exists for, and a teardown that waits forever for it is a quit that
    /// hangs.
    /// SIGTERM has ALREADY been sent by `stop()` — sending it again here would
    /// be a second signal for the same request, which the fake counts and a
    /// real ssh would simply be handed twice.
    private func tearDown(_ process: any ClaudeRemoteForwardProcess) async {
        if await waitForExit(of: process, within: configuration.terminationGrace) { return }
        Log.claudeContext.error(
            "Claude remote forward for host \(self.configuration.hostID, privacy: .public) ignored SIGTERM; escalating to SIGKILL"
        )
        process.forceTerminate()
        if await waitForExit(of: process, within: configuration.killGrace) { return }
        // Nothing left to try. Say so loudly: from here the remote bind is held
        // by a process this app can no longer end, and the next start will
        // report the port as unavailable for a reason that IS this Mac.
        Log.claudeContext.error(
            "Claude remote forward for host \(self.configuration.hostID, privacy: .public) survived SIGKILL; the remote port may stay bound"
        )
    }

    /// True when the process exited within the limit. The loser of the race is
    /// abandoned rather than awaited — a task group would wait for BOTH
    /// children, which for a process that never exits is the hang this whole
    /// method exists to avoid.
    private func waitForExit(
        of process: any ClaudeRemoteForwardProcess, within limit: Duration
    ) async -> Bool {
        let resolved = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func resume(_ exited: Bool) {
                let isFirst = resolved.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { continuation.resume(returning: exited) }
            }
            Task {
                _ = await process.waitUntilExit()
                resume(true)
            }
            Task { [sleepFor] in
                try? await sleepFor(limit)
                resume(false)
            }
        }
    }

    /// The user's move after freeing the port. Clears a terminal state and
    /// tries again — nothing else does, on purpose.
    ///
    /// It waits for the teardown it just started: restarting while the old ssh
    /// still holds the remote bind is how a healthy host reports
    /// `portUnavailable` at ITSELF.
    public func retry() {
        guard state.isFailure else { return }
        stop()
        let pending = teardown
        Task { @MainActor [weak self] in
            await pending?.value
            self?.start()
        }
    }

    /// Make any in-flight settle window inert: cancel it AND move the
    /// generation past it. Cancellation alone loses the race whenever the task
    /// is already awake past its sleep.
    private func invalidateSettleWindow() {
        settleTask?.cancel()
        settleTask = nil
        runGeneration += 1
    }

    private func supervise() async {
        while !stoppingIntentionally, !Task.isCancelled {
            let process: any ClaudeRemoteForwardProcess
            do {
                process = try launch(configuration)
            } catch {
                Log.claudeContext.error(
                    "Claude remote forward launch failed for host \(self.configuration.hostID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                transition(to: .failed(summary: "Could not start ssh."))
                superviseTask = nil
                return
            }
            currentProcess = process
            let startedAt = now()

            // ssh with -N says nothing on success, so "forwarding" is the
            // absence of a complaint, not a positive ack. There is no ack to
            // be had: the remote never tells the client the bind took, beyond
            // not failing. Watching stderr is the whole instrument.
            let watcher = Task { @MainActor [weak self] in
                await self?.watchStandardError(of: process)
            }

            transitionIfNeeded(to: .connecting)
            // …so "up" is defined as "still alive after the settle window",
            // measured on the INJECTED clock. A bind failure under
            // `ExitOnForwardFailure=yes` kills the process in well under a
            // second, so this window is what keeps the pane from flashing
            // "Tunnel up." at a tunnel that was already refused.
            runGeneration += 1
            let generation = runGeneration
            let settle = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.sleepFor(self.configuration.settleDelay) } catch { return }
                // Cancellation is checked AFTER a sleep that already returned,
                // so it is not enough on its own: the generation is. Without
                // it, a process that died during its own settle window could
                // still be announced as "Tunnel up." on top of the
                // `.retrying` the loop had already published.
                guard !Task.isCancelled,
                      !self.stoppingIntentionally,
                      self.runGeneration == generation
                else { return }
                self.transitionIfNeeded(to: .forwarding)
            }
            settleTask = settle
            // stderr FIRST, exit status second, and never the other way round:
            // `remote port forwarding failed` arrives microseconds before the
            // exit it causes, so reading the status first and then cancelling
            // the watcher would drop the one line that explains everything.
            // The contract a `ClaudeRemoteForwardProcess` owes is therefore
            // that its stream finishes when the process does.
            let bindFailure = await watcher.value ?? nil
            let status = await process.waitUntilExit()
            currentProcess = nil
            // The process is DEAD. Retire its settle window here, while this
            // iteration's scope is still open — not in a `defer` that runs
            // only once the loop leaves the body, because the very next thing
            // this loop does is park on a backoff that keeps the scope open.
            // That parked window was the bug: the settle woke up carrying a
            // generation nothing had advanced, and painted "Tunnel up." over
            // the `.retrying` of a process that had already exited.
            invalidateSettleWindow()

            guard !stoppingIntentionally, !Task.isCancelled else {
                superviseTask = nil
                return
            }

            // A refusal for a port we never requested is the user's own stale
            // config block being inherited, not a contended port (issue #215's
            // migration leaves exactly this behind). Different cause, different
            // fix, so it must not be reported as a held port.
            if let refusedPort = bindFailure, refusedPort != configuration.remoteForwardPort {
                Log.claudeContext.error(
                    "Claude remote forward for host \(self.configuration.hostID, privacy: .public) inherited a stale RemoteForward for port \(refusedPort, privacy: .public); this Mac asked for \(self.configuration.remoteForwardPort, privacy: .public)"
                )
                transition(to: .staleConfiguredForward(port: refusedPort))
                superviseTask = nil
                return
            }

            if bindFailure != nil {
                // Terminal by design. Restarting would dial a port another
                // machine is holding, forever, silently.
                Log.claudeContext.error(
                    "Claude remote forward refused for host \(self.configuration.hostID, privacy: .public): port \(self.configuration.remoteForwardPort, privacy: .public) already bound on \(self.configuration.sshHostAlias, privacy: .public)"
                )
                transition(to: .portUnavailable)
                superviseTask = nil
                return
            }

            // A connection that was UP for a good while and then dropped is an
            // isolated incident, not the next step in a run of failures. Five
            // of those spread over five days used to accumulate into "keeps
            // dropping" and stop the tunnel for good, each retry inheriting a
            // backoff computed from failures that had nothing to do with each
            // other.
            //
            // Measured as observed uptime rather than by arming another timer:
            // the elapsed time is already known here, an injected clock makes
            // it exact in tests, and a timer would be one more thing racing the
            // exit it is trying to describe.
            let uptime = now().timeIntervalSince(startedAt)
            let healthyUptimeSeconds = Double(configuration.healthyUptime.components.seconds)
            if uptime >= healthyUptimeSeconds {
                if consecutiveFailures > 0 {
                    Log.claudeContext.info(
                        "Claude remote forward for host \(self.configuration.hostID, privacy: .public) had been up \(Int(uptime), privacy: .public)s; clearing \(self.consecutiveFailures, privacy: .public) earlier failure(s)"
                    )
                }
                consecutiveFailures = 0
            }

            consecutiveFailures += 1
            Log.claudeContext.info(
                "Claude remote forward for host \(self.configuration.hostID, privacy: .public) exited with status \(status, privacy: .public) (failure \(self.consecutiveFailures, privacy: .public))"
            )

            if consecutiveFailures >= max(1, configuration.maxConsecutiveFailures) {
                transition(
                    to: .failed(summary: "Tunnel to \(configuration.sshHostAlias) keeps dropping.")
                )
                superviseTask = nil
                return
            }

            transition(to: .retrying(attempt: consecutiveFailures))
            do {
                try await sleepFor(Self.backoff(attempt: consecutiveFailures))
            } catch {
                superviseTask = nil
                return
            }
        }
        superviseTask = nil
    }

    /// The port whose bind the remote refused, if it refused one.
    ///
    /// The PORT, not just a flag: `Warning: remote port forwarding failed for
    /// listen port 8473` on a supervisor that asked for 28511 is a completely
    /// different diagnosis from the same warning naming 28511.
    private func watchStandardError(
        of process: any ClaudeRemoteForwardProcess
    ) async -> UInt16? {
        var refusedPort: UInt16?
        for await line in process.standardErrorLines {
            let lowered = line.lowercased()
            if lowered.contains(ClaudeRemoteForwardPort.forwardFailureSignature) {
                // Fall back to our own port when the number is missing or
                // unparseable: the refusal is still real, and the
                // conservative reading is the port we asked for.
                refusedPort = Self.refusedPort(in: lowered) ?? configuration.remoteForwardPort
            }
            // The tail goes to the log, never to the pane: ssh stderr is
            // long, and it is exactly the kind of text the popover rule
            // exists to keep out of the UI.
            Log.claudeContext.info(
                "Claude remote forward ssh stderr [\(self.configuration.hostID, privacy: .public)]: \(line, privacy: .private)"
            )
        }
        return refusedPort
    }

    /// The listen port named in OpenSSH's refusal line, if it names one.
    ///
    /// Anchored on `listen port `, not "the last number on the line": the
    /// message also carries host names, and a hostname with digits in it must
    /// never be read as a port.
    static func refusedPort(in loweredLine: String) -> UInt16? {
        guard let marker = loweredLine.range(of: "listen port ") else { return nil }
        let digits = loweredLine[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : UInt16(digits)
    }

    /// Exponential, capped, same shape as the backend supervisor's: 0.5s, 1s,
    /// 2s, … up to 30s.
    static func backoff(attempt: Int) -> Duration {
        .seconds(min(30.0, 0.5 * pow(2.0, Double(max(0, attempt - 1)))))
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
        Log.claudeContext.info(
            "Claude remote forward state for host \(self.configuration.hostID, privacy: .public): \(String(describing: newState), privacy: .public)"
        )
    }

    private func transitionIfNeeded(to newState: State) {
        guard state != newState else { return }
        transition(to: newState)
    }
}
