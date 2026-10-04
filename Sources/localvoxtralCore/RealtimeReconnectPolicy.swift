import Foundation

/// How a realtime WebSocket that dropped on its own — a Wi-Fi blip, a sleeping
/// NIC, a restarted speechd — is retried while the user is still speaking
/// (#380). A value type with no clock of its own, so the schedule is
/// assertable without a session.
package struct RealtimeReconnectPolicy: Sendable, Equatable {
    /// Connect attempts one drop is allowed before the session gives up.
    package let maxAttempts: Int
    /// Wait before the first attempt.
    package let initialBackoff: TimeInterval
    /// Applied to each subsequent wait.
    package let backoffMultiplier: Double
    /// Ceiling for a single wait, so late attempts stay within a few seconds
    /// of each other instead of running away.
    package let maxBackoff: TimeInterval
    /// How long one attempt may take to reach a ready session before it is
    /// abandoned. Above `RealtimeAPIWebSocketClient.sessionCreatedFallbackDelay`:
    /// a server that never sends `session.created` is ready only when the
    /// compatibility fallback fires. A socket that fails outright reports
    /// back sooner and cuts this short.
    package let attemptTimeout: TimeInterval
    /// Cadence at which an attempt re-reads the client's connection state.
    package let pollInterval: TimeInterval
    /// How long one run may wait, in all, for the bundled helper to finish
    /// restarting before it dials anyway (#1583). speechd binds its port only
    /// once its model is loaded, so until then every connect is refused at
    /// once and would spend the attempts in seconds. Charged no attempt, and
    /// counted in `worstCaseDuration`, which the audio buffer outlasts.
    package let managedHelperStartBudget: TimeInterval

    package static let `default` = RealtimeReconnectPolicy(
        maxAttempts: 4,
        initialBackoff: 0.25,
        backoffMultiplier: 3,
        maxBackoff: 2.0,
        attemptTimeout: 4.0,
        pollInterval: 0.05,
        managedHelperStartBudget: 20.0
    )

    /// Wait preceding `attempt` (1-based).
    package func backoff(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return initialBackoff }
        let grown = initialBackoff * pow(backoffMultiplier, Double(attempt - 1))
        return min(grown, maxBackoff)
    }

    /// Longest a full run can take: the whole wait for a restarting helper,
    /// then every attempt timing out silently. `AudioChunkBuffer
    /// .maxRetainedSeconds` is sized against this: a run that succeeds within
    /// the cap replays every second the gap swallowed.
    package var worstCaseDuration: TimeInterval {
        (1...max(1, maxAttempts)).reduce(managedHelperStartBudget) { total, attempt in
            total + backoff(beforeAttempt: attempt) + attemptTimeout
        }
    }
}
