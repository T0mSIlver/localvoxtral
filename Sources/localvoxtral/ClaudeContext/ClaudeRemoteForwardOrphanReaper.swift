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
///   equals what the ledger captured at spawn. A reused pid cannot match, so
///   an innocent process cannot be signalled, and a mismatch just retires the
///   record.
/// * **Only run while this instance holds the listener.** The caller
///   (`ClaudeRemoteForwardCoordinator`) gates the reap behind its listener
///   bind, which is what makes a SECOND app instance harmless: it cannot bind
///   8473 while the first instance lives, so it can never reap the first
///   instance's healthy tunnels.
/// * **Escalate like the supervisor does.** SIGTERM, a bounded wait, SIGKILL,
///   a bounded wait — on the injected clock, since the supervisor's own suite
///   set the no-wall-clock rule for this subsystem. A survivor of SIGKILL
///   keeps its record, so the next launch tries again.
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
        sendSignal: @escaping SendSignal = { pid, signalNumber in
            #if canImport(Darwin)
            _ = Darwin.kill(pid, signalNumber)
            #endif
        },
        sleepFor: @escaping SleepFor = { try await Task.sleep(for: $0) },
        terminationGrace: Duration = .seconds(2),
        killGrace: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.ledger = ledger
        self.inspect = inspect
        self.sendSignal = sendSignal
        self.sleepFor = sleepFor
        self.terminationGrace = terminationGrace
        self.killGrace = killGrace
        self.pollInterval = pollInterval
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
        Log.claudeContext.notice(
            "Claude remote forward orphan from a previous run found for host \(hostID, privacy: .public) (pid \(record.pid, privacy: .public)); terminating it to free the remote port"
        )
        sendSignal(pid_t(record.pid), SIGTERM)
        if await waitUntilGone(record) {
            ledger.forget(hostID: hostID, pid: record.pid)
            return
        }
        Log.claudeContext.error(
            "Claude remote forward orphan pid \(record.pid, privacy: .public) ignored SIGTERM; escalating to SIGKILL"
        )
        sendSignal(pid_t(record.pid), SIGKILL)
        if await waitUntilGone(record, within: killGrace) {
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
