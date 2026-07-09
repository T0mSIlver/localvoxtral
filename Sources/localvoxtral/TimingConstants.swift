import Foundation

/// Centralised timing and interval constants for the dictation pipeline.
///
/// Gathered here so related values are visible side-by-side and
/// the rationale for each can be documented once.
enum TimingConstants {
    // MARK: - Audio Send Loop

    /// Interval at which buffered PCM chunks are drained and sent to the WebSocket.
    static let audioSendInterval: TimeInterval = 0.1

    /// Fixed cadence for periodic realtime commits (was a user setting, removed).
    static let commitInterval: TimeInterval = 0.9

    // MARK: - Connection

    /// How long to wait for a WebSocket to reach `.connected` before timing out.
    static let connectTimeout: TimeInterval = 1.0

    /// Short grace after the app-level connect timeout fires before presenting
    /// a timeout. This lets URLSession deliver a terminal socket error that
    /// raced the timer, so refused ports are not mislabeled as silent timeouts.
    static let connectTimeoutSocketErrorGrace: TimeInterval = 0.15

    /// Duration the "recent failure" indicator stays visible after a connection error.
    static let recentFailureIndicatorDuration: TimeInterval = 5.0

    // MARK: - Stop Finalization (Realtime API path)

    /// Hard timeout for the stop-finalization phase on the Realtime API path.
    /// After this, the WebSocket is force-disconnected and any pending partial
    /// text is promoted.
    static let stopFinalizationTimeout: TimeInterval = 7.0

    /// Minimum time the finalization phase stays open before the inactivity
    /// check kicks in. Prevents premature disconnect if the first transcript
    /// delta arrives slowly.
    static let finalizationMinimumOpen: TimeInterval = 1.5

    /// If no realtime event arrives within this window (after the minimum open
    /// period), finalization is considered idle and the session is closed.
    static let finalizationInactivityThreshold: TimeInterval = 0.7

    /// Interval at which the finalization loop polls for timeout/inactivity.
    static let finalizationPollInterval: TimeInterval = 0.1

    /// Minimum time to keep the overlay visible after the most recent
    /// visible overlay text update before committing/hiding.
    static let overlayFinalWordVisibilityMinimum: TimeInterval = 0.5

    /// How long the overlay's secure-input clipboard-fallback message stays
    /// readable before the panel dismisses itself (the text is already safe
    /// on the clipboard, so the panel must not persist like a real failure).
    static let overlayClipboardFallbackVisibility: TimeInterval = 4.0
}
