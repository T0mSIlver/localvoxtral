import Foundation

#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#endif

/// Kills forward `ssh` children a previous app run left behind, before this
/// run starts hook `-R` or herdr `-L` forwards.
///
/// The bug this closes (field report, 2026-08-05): quit-and-reopen sometimes
/// landed the pane on the port-held status with a Retry that could only fail. The holder was this Mac's own orphan — an
/// `ssh -N -R` from a run that ended without `applicationWillTerminate`
/// (crash, force-quit) or whose teardown outran the bounded quit drain. It
/// reparents to launchd, keepalives keep it healthy forever, and nothing else
/// ever kills it. Persistent `-L` children share the same ledger and reaper;
/// their records carry a process-group id so ProxyJump descendants are reaped
/// with the checked group leader.
///
/// Safety rules, in order of importance:
///
/// * **Never kill by pid alone.** A record is actioned only when the pid's
///   CURRENT kernel identity — start time and resolved executable path —
///   equals what the ledger captured at spawn, re-verified immediately before
///   each signal. A mismatch retires the record without signalling. What
///   remains is the microsecond window between a verify and its signal, in
///   which the kernel would have to reap the orphan AND re-issue its pid —
///   stated because a single inspect-then-act cannot close it, not because it
///   is reachable in practice (macOS allocates pids incrementally and skips
///   recently used ones).
/// * **Only a dead copy's forward, and only this install's.** A record names
///   the copy of the app that spawned it (`ClaudeRemoteForwardOwner`). While
///   that copy runs, its forward is its own to stop; and a forward another
///   install left behind (a try-pr build, a CI launch smoke's temporary copy)
///   is that install's to reap on its next launch. The listener gate
///   (`ClaudeRemoteForwardCoordinator` reaps only after binding) is not
///   enough on its own: a copy that lost the port stops its forwards but
///   keeps running, and any copy launched after the holder quit binds the
///   port. On 2026-09-27 three CI launch smokes did exactly that and each
///   SIGTERMed the forward the ledger named (#892). Records from before the
///   owner was recorded are reaped as before.
/// * **Escalate like the supervisor does.** SIGTERM, a bounded wait, SIGKILL,
///   a bounded wait — on the injected clock, since the supervisor's own suite
///   set the no-wall-clock rule for this subsystem. A survivor of SIGKILL
///   keeps its record, so the next launch tries again.
///
/// Records reap sequentially, so the worst case — every enrolled host left a
/// live orphan that ignores SIGTERM — holds the forwards for
/// `hosts × (terminationGrace + killGrace)`. Accepted: real orphan counts are
/// one or two, the common path returns at the first inspect, and only the
/// forwards wait on it (the listener is already up).
public struct ClaudeRemoteForwardOrphanReaper: Sendable {
    public typealias Inspect = @Sendable (pid_t) -> ClaudeRemoteForwardPidRecord?
    public typealias SendSignal = @Sendable (pid_t, Int32) -> Void
    public typealias SleepFor = @Sendable (Duration) async throws -> Void

    private let ledger: ClaudeRemoteForwardPidLedger
    private let ownCopy: ClaudeRemoteForwardOwner?
    private let inspect: Inspect
    private let sendSignal: SendSignal
    private let sleepFor: SleepFor
    private let terminationGrace: Duration
    private let killGrace: Duration
    private let pollInterval: Duration

    /// - Parameter ownCopy: this copy of the app. Nil reaps no record that
    ///   names an owner, since no install can be shown to be this one.
    public init(
        ledger: ClaudeRemoteForwardPidLedger,
        ownCopy: ClaudeRemoteForwardOwner? = .current,
        inspect: @escaping Inspect = { ClaudeRemoteForwardProcessIdentity.snapshot(pid: $0) },
        sendSignal: SendSignal? = nil,
        sleepFor: @escaping SleepFor = { try await Task.sleep(for: $0) },
        terminationGrace: Duration = .seconds(2),
        killGrace: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.ledger = ledger
        self.ownCopy = ownCopy
        self.inspect = inspect
        // In the body, not as a default argument value: the default needs
        // `Log`, which is internal, and a public init's default arguments may
        // only name public symbols.
        self.sendSignal = sendSignal ?? Self.defaultSendSignal
        self.sleepFor = sleepFor
        self.terminationGrace = terminationGrace
        self.killGrace = killGrace
        self.pollInterval = pollInterval
    }

    /// Loud on failure (repo rule for lifecycle paths): a discarded EPERM
    /// would otherwise surface later as the WRONG failure — "survived SIGKILL"
    /// about a signal that was never delivered. ESRCH is not a failure here;
    /// the poll reads it as "gone".
    private static let defaultSendSignal: SendSignal = { pid, signalNumber in
        #if canImport(Darwin)
        if LibC.kill(pid, signalNumber) != 0, errno != ESRCH {
            Log.claudeContext.error(
                "Claude remote forward orphan reaper could not signal pid \(pid, privacy: .public): errno \(errno, privacy: .public)"
            )
        }
        #endif
    }

    public func reap() async {
        let records = ledger.records()
        guard !records.isEmpty else { return }
        for (hostID, record) in records {
            await reap(hostID: hostID, record: record)
        }
    }

    private func reap(hostID: String, record: ClaudeRemoteForwardPidRecord) async {
        guard record.matchesProcessIdentity(inspect(pid_t(record.pid))) else {
            // Dead, or the pid now names some other process entirely. Either
            // way there is nothing of ours to kill — only a record to retire.
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        guard isOrphanOfThisInstall(hostID: hostID, record: record) else { return }
        // Signal first, log second: the log call would otherwise sit inside
        // the verify-to-signal window the type comment promises is only
        // microseconds wide.
        sendSignal(signalTarget(for: record), SIGTERM)
        Log.claudeContext.notice(
            "Claude remote forward orphan from a previous run found for key \(hostID, privacy: .public) (pid \(record.pid, privacy: .public)); sent SIGTERM"
        )
        if await waitUntilGone(record) {
            Log.claudeContext.info(
                "Claude remote forward orphan for host \(hostID, privacy: .public) honoured SIGTERM; record retired"
            )
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        // Re-verify before escalating. `waitUntilGone`'s last poll saw a
        // matching identity at most one interval ago, but SIGKILL is the one
        // signal nothing can decline, so it gets its own fresh check.
        guard record.matchesProcessIdentity(inspect(pid_t(record.pid))) else {
            Log.claudeContext.info(
                "Claude remote forward orphan for host \(hostID, privacy: .public) exited before SIGKILL; record retired"
            )
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        Log.claudeContext.error(
            "Claude remote forward orphan pid \(record.pid, privacy: .public) ignored SIGTERM; escalating to SIGKILL"
        )
        sendSignal(signalTarget(for: record), SIGKILL)
        if await waitUntilGone(record, within: killGrace) {
            Log.claudeContext.info(
                "Claude remote forward orphan for host \(hostID, privacy: .public) killed; record retired"
            )
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        // Keep the record: it still names OUR process (identity-checked every
        // poll), and the next launch retrying costs nothing. Forgetting here
        // would make a SIGKILL survivor permanently invisible.
        Log.claudeContext.error(
            "Claude remote forward orphan pid \(record.pid, privacy: .public) survived SIGKILL; its forwarding resource may stay bound"
        )
    }

    /// Whether a live forward is this install's orphan. Anything else keeps
    /// its record: its owner forgets it on stop, or reaps it on relaunch.
    private func isOrphanOfThisInstall(hostID: String, record: ClaudeRemoteForwardPidRecord) -> Bool {
        guard let owner = record.owner else { return true }
        if owner.isRunning(as: inspect(pid_t(owner.pid))) {
            Log.claudeContext.notice(
                "Claude remote forward for key \(hostID, privacy: .public) (pid \(record.pid, privacy: .public)) belongs to another running copy (pid \(owner.pid, privacy: .public)); left alone"
            )
            return false
        }
        guard let ownCopy, owner.executablePath == ownCopy.executablePath else {
            Log.claudeContext.notice(
                "Claude remote forward for key \(hostID, privacy: .public) (pid \(record.pid, privacy: .public)) was left by another install (\(owner.executablePath, privacy: .public)); left alone"
            )
            return false
        }
        return true
    }

    private func waitUntilGone(
        _ record: ClaudeRemoteForwardPidRecord, within limit: Duration? = nil
    ) async -> Bool {
        let limit = limit ?? terminationGrace
        for _ in 0..<Self.pollCount(limit: limit, interval: pollInterval) {
            if !record.matchesProcessIdentity(inspect(pid_t(record.pid))) { return true }
            do { try await sleepFor(pollInterval) } catch { break }
        }
        return !record.matchesProcessIdentity(inspect(pid_t(record.pid)))
    }

    /// Negative pid means the whole process group. Only records created by the
    /// checked POSIX_SPAWN_SETPGROUP path carry this metadata.
    private func signalTarget(for record: ClaudeRemoteForwardPidRecord) -> pid_t {
        if let processGroupID = record.processGroupID, processGroupID > 1 {
            return -pid_t(processGroupID)
        }
        return pid_t(record.pid)
    }

    /// How many interval sleeps cover `limit`, at least one.
    package static func pollCount(limit: Duration, interval: Duration) -> Int {
        let limitNanos = max(Int64(1), nanoseconds(of: limit))
        let intervalNanos = max(Int64(1), nanoseconds(of: interval))
        return Int(max(1, (limitNanos + intervalNanos - 1) / intervalNanos))
    }

    private static func nanoseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000
            + Int64(components.attoseconds / 1_000_000_000)
    }
}
