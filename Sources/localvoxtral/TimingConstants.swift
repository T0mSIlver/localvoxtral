import Foundation

/// Centralised timing and interval constants for the dictation pipeline.
///
/// Gathered here so related values are visible side-by-side and
/// the rationale for each can be documented once.
enum TimingConstants {
    // MARK: - Audio Send Loop

    /// Interval at which buffered PCM chunks are drained and sent to the WebSocket.
    /// 80 ms is the managed helper's smallest step: one Voxtral token, one
    /// Nemotron encoder frame. Sending less often would make its steps larger.
    static let audioSendInterval: TimeInterval = 0.08

    /// Fixed cadence for periodic realtime commits (was a user setting, removed).
    static let commitInterval: TimeInterval = 0.9

    // MARK: - Connection

    /// How long to wait for a WebSocket to reach `.connected` before timing out.
    static let connectTimeout: TimeInterval = 1.0

    /// How long a start waits on a microphone prompt nobody answers.
    static let microphonePermissionPromptTimeout: TimeInterval = 120

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

    /// The same bound for the stop the Mac's sleep makes (#1584). macOS
    /// promises no time between `willSleep` and suspending the process, so
    /// the helper gets one second to return its tail; past it the stop keeps
    /// what arrived, as it did when sleep skipped the final commit.
    static let sleepStopFinalizationTimeout: TimeInterval = 1.0

    /// The same bound for the stop a quit makes (#1756): the quit waits this
    /// long for the helper's tail, then saves what arrived.
    static let quitStopFinalizationTimeout: TimeInterval = 1.0

    /// Minimum time the finalization phase stays open, counted from when the
    /// final commit left for the server, before the inactivity check kicks
    /// in. Prevents premature disconnect if the first transcript delta
    /// arrives slowly.
    static let finalizationMinimumOpen: TimeInterval = 1.5

    /// If no realtime event arrives within this window (after the minimum open
    /// period), finalization is considered idle and the session is closed.
    static let finalizationInactivityThreshold: TimeInterval = 0.7

    /// Interval at which the finalization loop polls for timeout/inactivity.
    static let finalizationPollInterval: TimeInterval = 0.1

    /// Minimum time to keep the overlay visible after the most recent
    /// visible overlay text update before committing/hiding.
    static let overlayFinalWordVisibilityMinimum: TimeInterval = 0.5

    /// The same hold when polish changed words (#1074): the marks on them
    /// need a moment to be seen. It runs after the insertion, so the text
    /// reaches the focused field no later.
    static let overlayPolishedVisibility: TimeInterval = 1.2

    /// How long the overlay's secure-input clipboard-fallback message stays
    /// readable before the panel dismisses itself (the text is already safe
    /// on the clipboard, so the panel must not persist like a real failure).
    static let overlayClipboardFallbackVisibility: TimeInterval = 4.0
}
