import Foundation
import Synchronization

/// Exits the helper when the supervising app dies, so a crashed or killed app
/// can never leave an orphaned model holding memory. Reproduces the
/// `--parent-pid` watchdog the mlx-lm fork implemented on the Python side.
public final class ParentProcessWatchdog: @unchecked Sendable {
    private let source: DispatchSourceProcess
    private let fired = Mutex(false)
    private let onParentExit: @Sendable () -> Void

    public init(parentPID: pid_t, onParentExit: @escaping @Sendable () -> Void) {
        self.onParentExit = onParentExit
        self.source = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: DispatchQueue(label: "localvoxtral.polishd.watchdog")
        )
        source.setEventHandler { [weak self] in self?.fireOnce() }
        source.activate()

        // The kqueue registration only fires for a live process; if the
        // parent died between spawn and here, catch it with a direct probe
        // (registered-then-probed, so there is no gap). Some libdispatch
        // versions ALSO simulate the exit event for an already-dead pid —
        // `fireOnce` collapses the two paths to a single callback.
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
