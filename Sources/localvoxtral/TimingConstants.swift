import Foundation

/// Centralised timing and interval constants for the dictation pipeline.
///
/// Gathered here so related values are visible side-by-side and
/// the rationale for each can be documented once.
enum TimingConstants {
    /// Target PCM sample rate for the audio pipeline (16 kHz mono).
    static let audioSampleRateHz: Double = 16_000

    // MARK: - Audio Send Loop

    /// Interval at which buffered PCM chunks are drained and sent to the WebSocket.
    static let audioSendInterval: TimeInterval = 0.1

    // MARK: - Connection

    /// How long to wait for a WebSocket to reach `.connected` before timing out.
    static let connectTimeout: TimeInterval = 2.0

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

    // MARK: - Stop Finalization (mlx-audio path)

    /// Hard timeout for the stop-finalization phase on the mlx-audio path.
    /// Longer than the Realtime API path because mlx inference on 6-12 s of
    /// audio can take 5+ seconds.
    static let mlxStopFinalizationTimeout: TimeInterval = 25.0

    /// Duration of silence appended after the user stops speaking, giving
    /// the mlx-audio server enough trailing context to finalize.
    static let mlxTrailingSilenceDuration: TimeInterval = 1.6

    /// Per-chunk duration for the trailing silence frames.
    static let mlxTrailingSilenceChunkDuration: TimeInterval = 0.1
}
