import Foundation
import os

/// Stopping by voice (#839): an Overlay Buffer dictation whose words end in
/// a send phrase, with no new text for `SpokenStopRule.silenceWindow`, stops
/// exactly as the stop key would (`stopDictation`). The stop then cuts the
/// phrase, polishes, commits and sends through the one commit path
/// (`stripOverlaySpokenSendTrigger`); a quick capture saves to the Inbox
/// without the phrase and presses nothing.
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
    /// modifier hold still down means held, and #840's destination switch
    /// may turn a running dictation into a capture.
    var spokenStopGesture: SpokenStopRule.Gesture {
        if isHoldGestureSession { return .held }
        return sessionIsQuickCapture || sessionDraftReview != nil ? .quickCapture : .toggled
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
        spokenStopTask = Task { @MainActor [weak self] in
            await clock.sleep(SpokenStopRule.silenceWindow)
            guard let self, !Task.isCancelled else { return }
            self.spokenStopTask = nil
            self.spokenStopArmedWords = nil
            self.fireSpokenStop()
        }
        Log.dictation.info("spoken stop armed: a send phrase ends the dictation")
    }

    func disarmSpokenStop() {
        spokenStopTask?.cancel()
        spokenStopTask = nil
        spokenStopArmedWords = nil
    }

    private func fireSpokenStop() {
        guard isDictating, !isFinalizingStop, !isReconnectingRealtimeSession,
              isOverlayBufferModeEnabled,
              spokenStopWouldStop(transcript.overlayDisplayText)
        else {
            Log.dictation.info("spoken stop: no longer applies when the silence ended")
            return
        }
        sessionStoppedBySpokenPhrase = true
        Log.dictation.notice(
            "spoken stop: a send phrase and \(Int(SpokenStopRule.silenceWindow.components.seconds), privacy: .public)s without new text; stopping as if pressed quick_capture=\(self.sessionIsQuickCapture, privacy: .public)"
        )
        stopDictation(reason: "spoken stop")
    }

    /// The whole decision, asked on arming and again on firing.
    private func spokenStopWouldStop(_ text: String) -> Bool {
        let gesture = spokenStopGesture
        guard SpokenStopRule.stopsByVoice(gesture) else { return false }
        switch gesture {
        case .quickCapture:
            if sessionDraftReview != nil { return draftReviewStopsByVoice(text) }
            // The Inbox never presses Return, so no send gate applies.
            return settings.overlaySpokenSendEnabled
                && SpokenStopRule.endsInSendPhrase(text, phrases: settings.spokenSendTriggerPhrases)
        case .toggled, .held:
            // Only a stop that will send: a phrase the commit would keep as
            // text must not end the dictation.
            if case .send = planOverlaySpokenSend(for: text) { return true }
            return false
        }
    }

    /// A capture stopped by its send phrase is saved without it.
    func quickCaptureTextWithoutSpokenStopPhrase(_ text: String) -> String {
        guard sessionStoppedBySpokenPhrase else { return text }
        switch SendNowCommandParser.parse(text, triggerPhrases: settings.spokenSendTriggerPhrases) {
        case .pressReturn: return ""
        case .insertTextAndPressReturn(let remainder): return remainder
        case .insertText, .none: return text
        }
    }
}
