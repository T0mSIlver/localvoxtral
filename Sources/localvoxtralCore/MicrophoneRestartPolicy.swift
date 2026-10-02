/// Whether a microphone start may keep the audio unit already running instead
/// of rebuilding it. Keeping it avoids a mic-indicator flicker while a
/// Bluetooth input renegotiates; the capture health monitor also restarts
/// through `start`, so a unit that reports running but delivers nothing must
/// be rebuilt, or the recovery does nothing.
package enum MicrophoneRestartPolicy {
    /// No captured chunk for this long means a unit that captured before has
    /// stalled. Matches the health monitor's tolerance for recent audio.
    package static let stalledAfterSeconds: Double = 1.2

    package static func keepsRunningUnit(
        isCapturing: Bool,
        onSameDevice: Bool,
        hasCapturedAudioInRun: Bool,
        hasRecentAudio: Bool
    ) -> Bool {
        guard isCapturing, onSameDevice else { return false }
        // A unit with no first chunk yet is kept: a Bluetooth input can take
        // seconds to deliver it, and a rebuild restarts that wait.
        return !hasCapturedAudioInRun || hasRecentAudio
    }
}
