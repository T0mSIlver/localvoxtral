import Foundation

/// The time a dictation runs on. Every timer a session arms — the connect
/// timeout and its socket-error grace, the microphone prompt's timeout, the
/// failure indicator's reset, the stop's finalization poll and watchdog, the
/// audio send and commit loops — sleeps on `sleep` and reads `now`.
///
/// The app runs on the wall clock. A test passes a clock it advances by hand,
/// so no session in a unit suite arms a real timer.
package struct SessionClock: Sendable {
    /// Returns when `duration` has passed, or early when the calling task is
    /// cancelled — the same contract as `try? await Task.sleep(for:)`.
    package var sleep: @Sendable (Duration) async -> Void
    package var now: @Sendable () -> Date

    package init(
        sleep: @escaping @Sendable (Duration) async -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.sleep = sleep
        self.now = now
    }

    package static let live = SessionClock(
        sleep: { try? await Task.sleep(for: $0) },
        now: { Date() }
    )
}
