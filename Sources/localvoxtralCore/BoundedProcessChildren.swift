#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// The app-lifetime owner of `BoundedProcess` children (#1225). A child
/// outlives the app unless something kills it: the headless agent CLIs
/// (drafting, project terms) would be reparented to launchd and keep reading
/// files and spending tokens, with the deadline gone with the app's thread.
/// Quit calls `terminateAll`.
package final class BoundedProcessChildren: Sendable {
    package static let shared = BoundedProcessChildren()

    private let state = Mutex<(pids: Set<pid_t>, closed: Bool)>(([], false))
    private let onRegister: (@Sendable (pid_t) -> Void)?

    /// `onRegister` tells a test which child is running.
    package init(onRegister: (@Sendable (pid_t) -> Void)? = nil) {
        self.onRegister = onRegister
    }

    /// False once `terminateAll` has run: the caller kills the child itself.
    func register(_ pid: pid_t) -> Bool {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.pids.insert(pid)
            return true
        }
        onRegister?(pid)
        return accepted
    }

    /// Called once the child is reaped (or abandoned), so a later
    /// `terminateAll` never signals a pid the kernel may have reused.
    func unregister(_ pid: pid_t) {
        state.withLock { _ = $0.pids.remove(pid) }
    }

    /// SIGTERM to every running child, SIGKILL to any still running after
    /// `grace`, then waits for them to be reaped, up to `within` in all.
    /// Bounded: a quit must never hang on a child stuck in the kernel.
    /// Children launched after this call are killed as they start.
    package func terminateAll(grace: TimeInterval, within: TimeInterval) {
        let start = DispatchTime.now()
        let count = signalAll(SIGTERM, closing: true)
        guard count > 0 else { return }
        Log.polishing.info("quit: stopping \(count, privacy: .public) agent or git run(s)")
        guard !waitUntilEmpty(until: start + grace) else { return }
        let survivors = signalAll(SIGKILL, closing: false)
        Log.polishing.info("quit: \(survivors, privacy: .public) run(s) ignored SIGTERM; killing")
        if !waitUntilEmpty(until: start + within) {
            Log.polishing.info("quit: a run did not exit after SIGKILL; leaving it")
        }
    }

    /// Signals under the lock, so `unregister` cannot race it. A pid can
    /// still be stale only between the reap and the termination handler
    /// that removes it, the same window `Process.terminate` has.
    private func signalAll(_ signal: Int32, closing: Bool) -> Int {
        state.withLock { state in
            if closing { state.closed = true }
            for pid in state.pids { kill(pid, signal) }
            return state.pids.count
        }
    }

    private func waitUntilEmpty(until deadline: DispatchTime) -> Bool {
        while DispatchTime.now() < deadline {
            if state.withLock({ $0.pids.isEmpty }) { return true }
            usleep(10_000)
        }
        return state.withLock { $0.pids.isEmpty }
    }
}
