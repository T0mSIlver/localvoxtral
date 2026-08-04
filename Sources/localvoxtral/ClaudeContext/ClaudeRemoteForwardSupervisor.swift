import Foundation
import Observation

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
    /// Ask it to stop. Must be safe to call more than once, and after exit.
    func terminate()
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
/// * `ClearAllForwardings=yes` before `-R`: the ssh config block for this alias
///   already declares a `RemoteForward`, and inheriting it would make this
///   process request the port TWICE — the second request failing, which under
///   `ExitOnForwardFailure=yes` kills the very process meant to hold it.
/// What the coordinator actually depends on.
///
/// A protocol so a test can drive the coordinator's decisions — which hosts get
/// a forward, and when — without a supervisor that would spawn ssh. The
/// supervisor's own behavior has its own suite, against a fake process.
@MainActor
public protocol ClaudeRemoteForwarding: AnyObject {
    var state: ClaudeRemoteForwardSupervisor.State { get }
    var onStateChange: (@MainActor (ClaudeRemoteForwardSupervisor.State) -> Void)? { get set }
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
            case .portUnavailable: return "Port already held on the host."
            case .failed: return "Tunnel stopped."
            }
        }

        public var isFailure: Bool {
            switch self {
            case .stopped, .connecting, .forwarding, .retrying: return false
            case .portUnavailable, .failed: return true
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

        public init(
            hostID: String,
            sshHostAlias: String,
            remoteForwardPort: UInt16,
            listenerPort: UInt16,
            maxConsecutiveFailures: Int = 5,
            settleDelay: Duration = .seconds(2)
        ) {
            self.hostID = hostID
            self.sshHostAlias = sshHostAlias
            self.remoteForwardPort = remoteForwardPort
            self.listenerPort = listenerPort
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.settleDelay = settleDelay
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
                "-o", "ClearAllForwardings=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-R", "\(remoteForwardPort):127.0.0.1:\(listenerPort)",
                "--", sshHostAlias,
            ]
        }
    }

    public typealias Launch = @MainActor (Configuration) throws -> any ClaudeRemoteForwardProcess
    public typealias SleepClosure = @Sendable (Duration) async throws -> Void

    public private(set) var state: State = .stopped

    /// Called synchronously on every transition, on the main actor. The
    /// coordinator mirrors state into the pane through this rather than through
    /// observation tracking, whose `onChange` fires before the write lands.
    @ObservationIgnored public var onStateChange: (@MainActor (State) -> Void)?

    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored private let launch: Launch
    @ObservationIgnored private let sleepFor: SleepClosure
    @ObservationIgnored private var superviseTask: Task<Void, Never>?
    @ObservationIgnored private var currentProcess: (any ClaudeRemoteForwardProcess)?
    @ObservationIgnored private var stoppingIntentionally = false
    /// Bumped per launch. The settle task carries the generation it belongs to
    /// so a stale one cannot report a dead process as up.
    @ObservationIgnored private var runGeneration = 0

    public init(
        configuration: Configuration,
        launch: @escaping Launch,
        sleepFor: @escaping SleepClosure = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.launch = launch
        self.sleepFor = sleepFor
    }

    public func start() {
        guard superviseTask == nil else { return }
        stoppingIntentionally = false
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
        currentProcess?.terminate()
        currentProcess = nil
        transition(to: .stopped)
    }

    /// The user's move after freeing the port. Clears a terminal state and
    /// tries again — nothing else does, on purpose.
    public func retry() {
        guard state.isFailure else { return }
        stop()
        start()
    }

    private func supervise() async {
        var consecutiveFailures = 0

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
            defer { settle.cancel() }
            // stderr FIRST, exit status second, and never the other way round:
            // `remote port forwarding failed` arrives microseconds before the
            // exit it causes, so reading the status first and then cancelling
            // the watcher would drop the one line that explains everything.
            // The contract a `ClaudeRemoteForwardProcess` owes is therefore
            // that its stream finishes when the process does.
            let sawBindFailure = await watcher.value ?? false
            let status = await process.waitUntilExit()
            currentProcess = nil

            guard !stoppingIntentionally, !Task.isCancelled else {
                superviseTask = nil
                return
            }

            if sawBindFailure {
                // Terminal by design. Restarting would dial a port another
                // machine is holding, forever, silently.
                Log.claudeContext.error(
                    "Claude remote forward refused for host \(self.configuration.hostID, privacy: .public): port \(self.configuration.remoteForwardPort, privacy: .public) already bound on \(self.configuration.sshHostAlias, privacy: .public)"
                )
                transition(to: .portUnavailable)
                superviseTask = nil
                return
            }

            consecutiveFailures += 1
            Log.claudeContext.info(
                "Claude remote forward for host \(self.configuration.hostID, privacy: .public) exited with status \(status, privacy: .public) (failure \(consecutiveFailures, privacy: .public))"
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

    /// True if ssh reported that the remote refused the bind.
    private func watchStandardError(of process: any ClaudeRemoteForwardProcess) async -> Bool {
        var sawBindFailure = false
        for await line in process.standardErrorLines {
            let lowered = line.lowercased()
            if lowered.contains(ClaudeRemoteForwardPort.forwardFailureSignature) {
                sawBindFailure = true
            }
            // The tail goes to the log, never to the pane: ssh stderr is
            // long, and it is exactly the kind of text the popover rule
            // exists to keep out of the UI.
            Log.claudeContext.info(
                "Claude remote forward ssh stderr [\(self.configuration.hostID, privacy: .public)]: \(line, privacy: .private)"
            )
        }
        return sawBindFailure
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
