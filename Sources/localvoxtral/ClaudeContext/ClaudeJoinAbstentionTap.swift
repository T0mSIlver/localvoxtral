import Synchronization

/// Collects the resolver's abstention causes for the duration of one resolve.
///
/// The resolver reduces every abstention to a log line and returns `nil`, so by
/// the time an answer comes back the reason it took that answer is gone. A
/// dogfood build already taps that (`DogfoodCaptureTap`), but that tap does not
/// exist in a shipping build — and `--probe-surface` has to run in a shipping
/// build, because a diagnostic that requires a special binary cannot diagnose
/// the binary the user is actually running.
///
/// Disarmed by default and therefore inert in normal operation: `note` takes an
/// uncontended lock, sees no collector, and returns. Nothing accumulates when
/// nobody is collecting, which is what keeps this from becoming an unbounded
/// buffer in a process that runs for weeks.
///
/// Scoped rather than global-with-a-reset (`collecting(_:)` arms, runs, and
/// disarms) so a collection can never outlive the call that wanted it — the
/// failure mode of the leaked-slot kind that `DogfoodCaptureTap.beginSession`
/// exists to bound.
enum ClaudeJoinAbstentionTap {
    private struct State {
        var collecting = false
        var causes: [String] = []
    }

    /// A resolve visits at most a couple of dozen abstention sites; the cap is
    /// a backstop against a future loop, not a budget anyone should reach.
    private static let maxCauses = 64

    private static let state = Mutex(State())

    /// Records one arm's abstention cause, e.g. `"tty: stale"`. A no-op unless
    /// a `collecting(_:)` call is in progress.
    static func note(_ cause: String) {
        state.withLock {
            guard $0.collecting, $0.causes.count < maxCauses else { return }
            $0.causes.append(cause)
        }
    }

    /// Runs `body` with the tap armed and returns its value alongside every
    /// cause noted while it ran, oldest first.
    ///
    /// Not reentrant, and it does not need to be: the only caller is the probe
    /// verb, which resolves exactly once per process.
    ///
    /// `isolation` inherits the caller's actor so a `@MainActor` resolve can be
    /// passed in directly — without it the closure would have to cross an
    /// isolation boundary it has no reason to cross.
    static func collecting<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> T
    ) async -> (T, [String]) {
        state.withLock { $0 = State(collecting: true) }
        let value = await body()
        let causes = state.withLock { current -> [String] in
            let causes = current.causes
            current = State()
            return causes
        }
        return (value, causes)
    }
}
