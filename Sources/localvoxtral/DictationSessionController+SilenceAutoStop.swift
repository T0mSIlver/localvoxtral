import Foundation
import os

/// Silence auto-stop (#318): an Overlay Buffer session started by a tap stops
/// once no new transcript text has arrived for
/// `settings.overlayBufferSilenceAutoStop`. The stop is the one a tapped
/// shortcut makes (`endDictation` → `stopDictation`), so the overlay commit,
/// polish and history run exactly as they do for a manual stop.
///
/// A hold session never arms it: its release is the stop. Live Auto-Paste
/// never arms it either. The timer sleeps on `dependencies.clock`, and the
/// setting is read once, when the session goes live.
///
/// A mid-dictation reconnect (#380) pauses it: no text can arrive while the
/// socket is down, and a stop then would end the session before the audio
/// buffered in the gap is replayed. The watch stops at the drop and starts
/// again, counting from zero, once the new socket is live.
extension DictationSessionController {
    /// A session started while a push-to-talk key or the modifier hold is
    /// down: its release event will stop it.
    var isHoldGestureSession: Bool {
        shortcuts.hasActivePushToTalkShortcutSession || shortcuts.isModifierOnlyHoldActive
    }

    /// Called when the session goes live. Decides once whether this session
    /// has a watch, and with what threshold.
    func armSilenceAutoStopIfEnabled() {
        disarmSilenceAutoStop()
        guard isOverlayBufferModeEnabled,
              !isHoldGestureSession,
              let threshold = settings.overlayBufferSilenceAutoStop.seconds
        else { return }

        silenceAutoStopThreshold = threshold
        Log.dictation.info(
            "silence auto-stop armed: \(Int(threshold), privacy: .public)s without new text stops this session"
        )
        startSilenceAutoStopWatch(threshold: threshold)
    }

    /// The socket dropped and a reconnect run started. The session keeps its
    /// threshold; only the running watch stops.
    func pauseSilenceAutoStopForReconnect() {
        guard silenceAutoStopThreshold != nil else { return }
        silenceAutoStopTask?.cancel()
        silenceAutoStopTask = nil
        lastTranscriptTextAt = nil
        Log.dictation.info("silence auto-stop paused while the realtime socket reconnects")
    }

    /// The reconnected socket is live: the watch starts again from now.
    func resumeSilenceAutoStopAfterReconnect() {
        guard let threshold = silenceAutoStopThreshold, isDictating else { return }
        Log.dictation.info("silence auto-stop resumed on the reconnected socket")
        startSilenceAutoStopWatch(threshold: threshold)
    }

    func noteTranscriptTextForSilenceAutoStop() {
        guard silenceAutoStopTask != nil, isDictating else { return }
        lastTranscriptTextAt = dependencies.clock.now()
    }

    func disarmSilenceAutoStop() {
        silenceAutoStopTask?.cancel()
        silenceAutoStopTask = nil
        lastTranscriptTextAt = nil
        silenceAutoStopThreshold = nil
    }

    private func startSilenceAutoStopWatch(threshold: TimeInterval) {
        silenceAutoStopTask?.cancel()
        let clock = dependencies.clock
        lastTranscriptTextAt = clock.now()
        silenceAutoStopTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled, self.isDictating,
                      !self.isReconnectingRealtimeSession,
                      let lastText = self.lastTranscriptTextAt
                else { return }
                let quiet = clock.now().timeIntervalSince(lastText)
                // Within a nanosecond counts as reached, as it does on
                // ManualSessionClock, so float sums cannot leave it just short.
                if quiet + 1e-9 >= threshold {
                    self.silenceAutoStopTask = nil
                    self.lastTranscriptTextAt = nil
                    Log.dictation.notice(
                        "silence auto-stop: no new text for \(Int(threshold), privacy: .public)s, stopping as if tapped"
                    )
                    self.stopDictation(reason: "silence auto-stop")
                    return
                }
                await clock.sleep(.seconds(threshold - quiet))
            }
        }
    }
}
