import Foundation

/// How a realtime WebSocket that dropped on its own — a Wi-Fi blip, a sleeping
/// NIC, a restarted speechd — is retried while the user is still speaking
/// (#380). A value type with no clock of its own, so the schedule is
/// assertable without a session.
struct RealtimeReconnectPolicy: Sendable, Equatable {
    /// Connect attempts one drop is allowed before the session gives up.
    let maxAttempts: Int
    /// Wait before the first attempt.
    let initialBackoff: TimeInterval
    /// Applied to each subsequent wait.
    let backoffMultiplier: Double
    /// Ceiling for a single wait, so late attempts stay within a few seconds
    /// of each other instead of running away.
    let maxBackoff: TimeInterval
    /// How long one attempt may sit in `connecting` before it is abandoned.
    /// A socket that fails outright reports back sooner and cuts this short.
    let attemptTimeout: TimeInterval
    /// Cadence at which an attempt re-reads the client's connection state.
    let pollInterval: TimeInterval

    static let `default` = RealtimeReconnectPolicy(
        maxAttempts: 4,
        initialBackoff: 0.25,
        backoffMultiplier: 3,
        maxBackoff: 2.0,
        attemptTimeout: 2.5,
        pollInterval: 0.05
    )

    /// Wait preceding `attempt` (1-based).
    func backoff(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return initialBackoff }
        let grown = initialBackoff * pow(backoffMultiplier, Double(attempt - 1))
        return min(grown, maxBackoff)
    }

    /// Longest a full run can take when every attempt times out silently.
    /// `AudioChunkBuffer.maxRetainedSeconds` is sized against this: a run that
    /// succeeds within the cap replays every second the gap swallowed.
    var worstCaseDuration: TimeInterval {
        (1...max(1, maxAttempts)).reduce(0) { total, attempt in
            total + backoff(beforeAttempt: attempt) + attemptTimeout
        }
    }
}
