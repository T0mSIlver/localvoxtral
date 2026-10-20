import AppKit
import Foundation
import os

/// What a route that writes into an agent's prompt answered for one
/// overlay commit.
enum PromptDeliveryOutcome: Equatable {
    /// The target took the text. `submitted`: it submitted the prompt too.
    /// `status` is the popover's line when the answer says more than that.
    case delivered(submitted: Bool, status: String?)
    /// Surely not landed: nothing changed in the prompt.
    case refused
    /// The target got the text and did not answer: it may have landed.
    case mayHaveLanded

    var isDelivered: Bool {
        if case .delivered = self { true } else { false }
    }
}

extension DictationSessionController {
    /// The one place an overlay commit's text goes when its route did not
    /// take it. Once the next dictation started, the keys serve that
    /// dictation, so the text is kept, never typed (#1466, #1657), and the
    /// status line stays the new dictation's. Text that may have landed is
    /// kept rather than going in twice. A refused text is typed only when
    /// `keysReachPrompt` (keys typed now would reach the same prompt),
    /// kept otherwise. Unless keys put the text in, the next commit does
    /// not continue it. docs/agent/invariants.md, "The app writes into an
    /// agent only through its routes".
    ///
    /// - Returns: whether keys put the text in.
    @discardableResult
    func settleUndeliveredOverlayText(
        _ text: String,
        outcome: PromptDeliveryOutcome,
        keysReachPrompt: Bool,
        sessionID: String?,
        generation: UInt64,
        preferredAppPID pid: pid_t?
    ) -> Bool {
        guard sessionStartGeneration == generation else {
            Log.overlay.notice("overlay commit: refused after the next dictation started; text kept")
            _ = keepUndeliveredAgentText(text, of: generation)
            forgetLanding(ofSession: sessionID, generation: generation)
            return false
        }
        var inserted = false
        switch outcome {
        case .delivered:
            return false
        case .mayHaveLanded:
            lastError = keepUndeliveredAgentText(text, of: generation)
        case .refused where keysReachPrompt:
            inserted = typeUndeliveredOverlayText(text, generation: generation, preferredAppPID: pid)
        case .refused:
            Log.overlay.notice("overlay commit: the route did not take the text and keys would not reach its prompt; text kept")
            lastError = keepUndeliveredAgentText(text, of: generation)
        }
        if !inserted {
            forgetLanding(ofSession: sessionID, generation: generation)
        }
        return inserted
    }

    /// A refused text, committed the way the overlay commits without a
    /// route: keys, then Cmd+V, to the target the commit named when it
    /// handed the text off (the overlay may have reset since). Under Secure
    /// Keyboard Entry, or when no key lands, the text goes on the
    /// clipboard once no paste reads it: the panel is gone, and it may
    /// exist nowhere else.
    ///
    /// - Returns: whether keys put the text in.
    private func typeUndeliveredOverlayText(_ text: String, generation: UInt64, preferredAppPID pid: pid_t?) -> Bool {
        if !TerminalTargetDetector.isSecureKeyboardEntryEnabled(),
           textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid).isSuccess
            || textInsertion.pasteUsingCommandV(text, preferredAppPID: pid) {
            Log.overlay.notice("overlay commit: relay refused; text inserted by keyboard")
            return true
        }
        Log.overlay.error("overlay commit: relay refused and keyboard insertion unavailable; text copied")
        // Set first: a copy that fails at once replaces it.
        lastError = StatusStrings.overlayCopiedToClipboard
        _ = copyUntypedText(text) { [weak self] in
            guard let self, self.sessionStartGeneration == generation else { return }
            self.lastError = "Unable to insert buffered text into the focused app."
        }
        return false
    }
}
