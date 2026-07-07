import Foundation

/// Exits the helper when the supervising app dies, so a crashed or killed app
/// can never leave an orphaned model holding memory. This reproduces the
/// `--parent-pid` watchdog the mlx-lm fork implemented on the Python side.
public final class ParentProcessWatchdog: @unchecked Sendable {
    private let source: DispatchSourceProcess
    private let onParentExit: @Sendable () -> Void

    public init(parentPID: pid_t, onParentExit: @escaping @Sendable () -> Void) {
        self.onParentExit = onParentExit
        self.source = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: DispatchQueue(label: "localvoxtral.polishd.watchdog")
        )
        source.setEventHandler { onParentExit() }
        source.activate()

        // The kqueue registration only fires for a live process; if the
        // parent died between spawn and here, catch it with a direct probe
        // (registered-then-probed, so there is no gap).
        if kill(parentPID, 0) != 0 && errno == ESRCH {
            onParentExit()
        }
    }

    deinit {
        source.cancel()
    }
}
