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
extension DictationSessionController {
    /// A session started while a push-to-talk key or the modifier hold is
    /// down: its release event will stop it.
    var isHoldGestureSession: Bool {
        shortcuts.hasActivePushToTalkShortcutSession || shortcuts.isModifierOnlyHoldActive
    }

    func armSilenceAutoStopIfEnabled() {
        disarmSilenceAutoStop()
        guard isOverlayBufferModeEnabled,
              !isHoldGestureSession,
              let threshold = settings.overlayBufferSilenceAutoStop.seconds
        else { return }

        let clock = dependencies.clock
        lastTranscriptTextAt = clock.now()
        Log.dictation.info(
            "silence auto-stop armed: \(Int(threshold), privacy: .public)s without new text stops this session"
        )
        silenceAutoStopTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled, self.isDictating,
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

    func noteTranscriptTextForSilenceAutoStop() {
        guard silenceAutoStopTask != nil, isDictating else { return }
        lastTranscriptTextAt = dependencies.clock.now()
    }

    func disarmSilenceAutoStop() {
        silenceAutoStopTask?.cancel()
        silenceAutoStopTask = nil
        lastTranscriptTextAt = nil
    }
}
