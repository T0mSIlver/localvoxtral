import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Kills forward `ssh` children a previous app run left behind, before this
/// run's forwards dial the same remote port.
///
/// The bug this closes (field report, 2026-08-05): quit-and-reopen sometimes
/// landed the pane on "Port held — close ssh sessions to that host." with a
/// Retry that could only fail. The holder was this Mac's own orphan — an
/// `ssh -N -R` from a run that ended without `applicationWillTerminate`
/// (crash, force-quit) or whose teardown outran the bounded quit drain. It
/// reparents to launchd, keepalives keep it healthy forever, and nothing else
/// ever kills it.
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
/// * **Only run while this instance holds the listener.** The caller
///   (`ClaudeRemoteForwardCoordinator`) gates the reap behind its listener
///   bind, which is what makes a SECOND app instance harmless: it cannot bind
///   8473 while the first instance lives, so it can never reap the first
///   instance's healthy tunnels.
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
    private let inspect: Inspect
    private let sendSignal: SendSignal
    private let sleepFor: SleepFor
    private let terminationGrace: Duration
    private let killGrace: Duration
    private let pollInterval: Duration

    public init(
        ledger: ClaudeRemoteForwardPidLedger,
        inspect: @escaping Inspect = { ClaudeRemoteForwardProcessIdentity.snapshot(pid: $0) },
        sendSignal: SendSignal? = nil,
        sleepFor: @escaping SleepFor = { try await Task.sleep(for: $0) },
        terminationGrace: Duration = .seconds(2),
        killGrace: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.ledger = ledger
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
        if Darwin.kill(pid, signalNumber) != 0, errno != ESRCH {
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
        guard let current = inspect(pid_t(record.pid)), current == record else {
            // Dead, or the pid now names some other process entirely. Either
            // way there is nothing of ours to kill — only a record to retire.
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        // Signal first, log second: the log call would otherwise sit inside
        // the verify-to-signal window the type comment promises is only
        // microseconds wide.
        sendSignal(pid_t(record.pid), SIGTERM)
        Log.claudeContext.notice(
            "Claude remote forward orphan from a previous run found for host \(hostID, privacy: .public) (pid \(record.pid, privacy: .public)); sent SIGTERM to free the remote port"
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
        guard let beforeKill = inspect(pid_t(record.pid)), beforeKill == record else {
            Log.claudeContext.info(
                "Claude remote forward orphan for host \(hostID, privacy: .public) exited before SIGKILL; record retired"
            )
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        Log.claudeContext.error(
            "Claude remote forward orphan pid \(record.pid, privacy: .public) ignored SIGTERM; escalating to SIGKILL"
        )
        sendSignal(pid_t(record.pid), SIGKILL)
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
            "Claude remote forward orphan pid \(record.pid, privacy: .public) survived SIGKILL; the remote port may stay bound"
        )
    }

    private func waitUntilGone(
        _ record: ClaudeRemoteForwardPidRecord, within limit: Duration? = nil
    ) async -> Bool {
        let limit = limit ?? terminationGrace
        for _ in 0..<Self.pollCount(limit: limit, interval: pollInterval) {
            if inspect(pid_t(record.pid)) != record { return true }
            do { try await sleepFor(pollInterval) } catch { break }
        }
        return inspect(pid_t(record.pid)) != record
    }

    /// How many interval sleeps cover `limit`, at least one.
    static func pollCount(limit: Duration, interval: Duration) -> Int {
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
