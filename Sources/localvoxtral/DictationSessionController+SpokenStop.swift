import Foundation
import os

/// Stopping by voice (#839): an Overlay Buffer dictation whose words end in
/// a send phrase, with no new text for `settings.spokenStopWait`, stops
/// exactly as the stop key would (`stopDictation`). The stop then cuts the
/// phrase, polishes, commits and sends through the one commit path
/// (`stripOverlaySpokenSendTrigger`).
///
/// Armed only when the commit would send: the same gates the stop applies
/// (`planOverlaySpokenSend`), read again when the timer fires. A held
/// dictation never arms: its release is the stop. The words watched are the
/// overlay's (settled segments plus the partial in flight), because the
/// Mistral API sends no final before the stop; any change to them re-decides,
/// and a final that only confirms the same words keeps the timer running.
/// The timer sleeps on `dependencies.clock`.
extension DictationSessionController {
    /// How this dictation was started, read live: a push-to-talk key or the
    /// modifier hold still down means held.
    var spokenStopGesture: SpokenStopRule.Gesture {
        isHoldGestureSession ? .held : .toggled
    }

    /// After every transcript change of an Overlay Buffer dictation.
    func reconsiderSpokenStop() {
        guard isOverlayBufferModeEnabled, isDictating, !isFinalizingStop else { return }
        let text = transcript.overlayDisplayText
        let words = Self.spokenWords(text)
        if spokenStopTask != nil, words == spokenStopArmedWords { return }
        disarmSpokenStop()
        guard spokenStopWouldStop(text) else { return }
        spokenStopArmedWords = words
        let clock = dependencies.clock
        let wait = settings.spokenStopWait
        spokenStopTask = Task { @MainActor [weak self] in
            await clock.sleep(wait.duration)
            guard let self, !Task.isCancelled else { return }
            self.spokenStopTask = nil
            self.spokenStopArmedWords = nil
            self.fireSpokenStop(after: wait)
        }
        Log.dictation.info("spoken stop armed: a send or stop phrase ends the dictation after \(wait.displayName, privacy: .public)")
    }

    func disarmSpokenStop() {
        spokenStopTask?.cancel()
        spokenStopTask = nil
        spokenStopArmedWords = nil
    }

    private func fireSpokenStop(after wait: SpokenStopWait) {
        guard isDictating, !isFinalizingStop, !isReconnectingRealtimeSession,
              isOverlayBufferModeEnabled,
              spokenStopWouldStop(transcript.overlayDisplayText)
        else {
            Log.dictation.info("spoken stop: no longer applies when the silence ended")
            return
        }
        sessionStoppedBySpokenPhrase = true
        Log.dictation.notice(
            "spoken stop: a send or stop phrase and \(wait.displayName, privacy: .public) without new text; stopping as if pressed"
        )
        stopDictation(reason: "spoken stop")
    }

    /// The whole decision, asked on arming and again on firing.
    private func spokenStopWouldStop(_ text: String) -> Bool {
        guard SpokenStopRule.stopsByVoice(spokenStopGesture) else { return false }
        // A stop phrase said alone ends the joined session's turn at the
        // stop (#1696).
        if isSpokenAbort(text) { return true }
        // Only a stop that will send: a phrase the commit would keep as text
        // must not end the dictation.
        if case .send = planOverlaySpokenSend(for: text) { return true }
        return false
    }
}
