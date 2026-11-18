/// Where one dictation is in its lifecycle. A session is in exactly one of
/// these at a time; `DictationSessionController.phase` holds it.
///
///     idle ─▶ awaitingMicrophonePermission ─▶ idle
///     idle ─▶ connecting ─▶ dictating ─▶ finalizing ─▶ idle
///                  │
///                  └─▶ idle   (refused, failed or cancelled connect)
///
/// A reconnect run is not a phase: it runs under `dictating` (a drop
/// mid-dictation) or `finalizing` (a stop that reconnects for its tail).
package enum DictationPhase: String, Sendable, Equatable {
    /// Nothing runs; a start may begin.
    case idle
    /// The microphone prompt is open, from a start or from the launch
    /// probe. Starts are refused until the user answers or it times out.
    case awaitingMicrophonePermission
    /// The managed backends warm up or the socket opens. The microphone
    /// already captures into the chunk buffer (#527).
    case connecting
    /// The socket is open and audio streams to it.
    case dictating
    /// Stopped: the stop waits for the backend's last words, then commits,
    /// polishes and saves. Escape still cancels it.
    case finalizing

    /// Whether the session may move from `self` to `next`. A move this
    /// refuses is logged as a fault: it means two code paths disagree about
    /// where the session is.
    package func canMove(to next: DictationPhase) -> Bool {
        switch (self, next) {
        case (.idle, .awaitingMicrophonePermission), (.idle, .connecting),
             (.awaitingMicrophonePermission, .idle),
             (.connecting, .idle), (.connecting, .dictating),
             (.dictating, .finalizing),
             (.finalizing, .idle):
            return true
        default:
            return self == next
        }
    }
}
