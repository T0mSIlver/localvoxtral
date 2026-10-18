import AppKit
import Foundation
import os

/// Writing through a route into the joined agent's prompt (opencode's
/// prompt relay, #719) instead of typing: no keystroke, so a focus change
/// mid-dictation, Secure Keyboard Entry or the clipboard cannot take the
/// text elsewhere. Any failed call sends the text back to the keyboard path,
/// and the rest of the dictation with it. docs/agent/invariants.md, "The app
/// writes into an agent only through its routes".
extension DictationSessionController {
    /// Connect time, once per dictation: hands the relay resolved at start to
    /// the insertion service, or disarms the previous one.
    func armPromptRelayForSession() {
        let sessionID = context.agentPromptRoute == nil ? nil : context.claudeSessionJoin?.snapshot.sessionID
        let generation = sessionStartGeneration
        promptRelaySessionID = sessionID
        let kept = UndeliveredAgentText()
        textInsertion.beginPromptRelay(context.agentPromptRoute, kept: { [weak self] text in
            kept.text += text
            guard let self else { return }
            self.lastError = self.keepUndeliveredAgentText(kept.text)
            self.forgetLanding(ofSession: sessionID, generation: generation)
        })
    }

    /// Where the overlay commit goes without a mod: the route while it
    /// takes text, the keyboard otherwise. The append is handed off, not
    /// awaited: the relay delivers in order and gives a refused text back
    /// to the keyboard.
    var overlayTextDestination: OverlayCommitDestination {
        guard textInsertion.promptRelayTakesText, let sink = textInsertion.promptRelaySink else {
            return .keyboard(textInsertion)
        }
        // Read now: an answer that comes after the next dictation armed its
        // own relay still belongs to this one.
        let sessionID = promptRelaySessionID
        let generation = sessionStartGeneration
        return .route { [weak self] text, pid in
            sink.append(text) { refused in
                guard let self else { return }
                guard self.sessionStartGeneration == generation else {
                    self.keepOverlayTextOfARetiredDictation(refused, sessionID: sessionID, generation: generation)
                    return
                }
                self.commitOverlayTextThePromptRelayRefused(
                    refused, preferredAppPID: pid, sessionID: sessionID, generation: generation
                )
            }
        }
    }

    /// An overlay commit's text that the relay or the mod gave back after
    /// the next dictation started: the keys serve that dictation now, so the
    /// text is kept, never typed (#1466, #1657). The status line is the new
    /// dictation's.
    func keepOverlayTextOfARetiredDictation(_ text: String, sessionID: String?, generation: UInt64) {
        Log.overlay.notice("overlay commit: refused after the next dictation started; text kept")
        _ = keepUndeliveredAgentText(text)
        forgetLanding(ofSession: sessionID, generation: generation)
    }

    /// The overlay's text the relay did not take, committed the way the
    /// overlay commits without one: keys, then Cmd+V, to the target the
    /// commit named when it handed the text off (the overlay may have reset
    /// since). Under Secure Keyboard Entry, or when no key lands, the text
    /// goes on the clipboard: the panel is gone, and it may exist nowhere
    /// else. The session's mod (#1409) gives its refusals back here too.
    ///
    /// - Returns: whether keys put the text in.
    @discardableResult
    func commitOverlayTextThePromptRelayRefused(
        _ text: String, preferredAppPID pid: pid_t?, sessionID: String?, generation: UInt64
    ) -> Bool {
        if !TerminalTargetDetector.isSecureKeyboardEntryEnabled(),
           textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid).isSuccess
            || textInsertion.pasteUsingCommandV(text, preferredAppPID: pid) {
            Log.overlay.notice("overlay commit: relay refused; text inserted by keyboard")
            return true
        }
        Log.overlay.error("overlay commit: relay refused and keyboard insertion unavailable; text copied")
        forgetLanding(ofSession: sessionID, generation: generation)
        #if DEBUG
        // A test must never write the host's clipboard.
        if TerminalTargetDetector.isRunningUnderXCTest {
            lastError = StatusStrings.overlayCopiedToClipboard
            return false
        }
        #endif
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        lastError = pasteboard.setString(text, forType: .string)
            ? StatusStrings.overlayCopiedToClipboard
            : "Unable to insert buffered text into the focused app."
        return false
    }

    /// The commit recorded its landing when it handed the text off. Text the
    /// relay then left on the clipboard or in History is not in the prompt,
    /// so the next commit there must not continue it: a leading space would
    /// turn `/compact` into text (docs/agent/invariants.md, "An Overlay
    /// Buffer commit starts with a space only when it continues the unsent
    /// prompt"). Only the landing of the dictation that handed the text off:
    /// a refusal that answers after a later commit to the same session must
    /// not forget that commit's landing.
    func forgetLanding(ofSession sessionID: String?, generation: UInt64) {
        guard let sessionID, let landing = lastOverlayCommitLanding,
              landing.sessionID == sessionID, landing.generation == generation
        else { return }
        Log.overlay.notice("overlay commit: handed-off text not in the prompt; next commit adds no space")
        lastOverlayCommitLanding = nil
    }
}
