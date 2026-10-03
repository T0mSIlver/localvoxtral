import Foundation
import Synchronization

/// Exits the helper when the supervising app dies, so a crashed or killed app can never leave
/// an orphaned model holding memory. Mirrors PolishHelper's watchdog and the `--parent-pid`
/// contract the Python voxmlx backend honored.
public final class ParentProcessWatchdog: @unchecked Sendable {
    private let source: DispatchSourceProcess
    private let fired = Mutex(false)
    private let onParentExit: @Sendable () -> Void

    public init(parentPID: pid_t, onParentExit: @escaping @Sendable () -> Void) {
        self.onParentExit = onParentExit
        self.source = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: DispatchQueue(label: "localvoxtral.speechd.watchdog")
        )
        source.setEventHandler { [weak self] in self?.fireOnce() }
        source.activate()

        // Registered-then-probed so there is no gap: if the parent died between spawn and
        // here, the kqueue registration won't fire, so catch it with a direct probe.
        if kill(parentPID, 0) != 0 && errno == ESRCH {
            fireOnce()
        }
    }

    /// Runs `operation` under a watchdog for `parentPID` (none when nil),
    /// installed before the operation starts so a parent that dies during a
    /// model load is noticed then (#1586). The watchdog lives until the
    /// operation returns: its deinit cancels the kqueue source, and a local
    /// whose last use comes early may be released early.
    public static func guarding<T>(
        parentPID: pid_t?,
        onParentExit: @escaping @Sendable () -> Void,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let watchdog = parentPID.map { ParentProcessWatchdog(parentPID: $0, onParentExit: onParentExit) }
        defer { withExtendedLifetime(watchdog) {} }
        return try await operation()
    }

    private func fireOnce() {
        let first = fired.withLock { value in
            let previous = value
            value = true
            return !previous
        }
        if first { onParentExit() }
    }

    deinit {
        source.cancel()
    }
}
