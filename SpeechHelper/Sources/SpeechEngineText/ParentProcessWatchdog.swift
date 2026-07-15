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
