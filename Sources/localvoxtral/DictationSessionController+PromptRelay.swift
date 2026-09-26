import AppKit
import Foundation
import os

/// Writing through the focused opencode pane's prompt relay (#719) instead
/// of typing: no keystroke, so a focus change mid-dictation, Secure Keyboard
/// Entry or the clipboard cannot take the text elsewhere. Any failed call
/// sends the text back to the keyboard path, and the rest of the dictation
/// with it. docs/agent/invariants.md, "The app writes into an agent only
/// through opencode's prompt relay".
extension DictationSessionController {
    /// Connect time, once per dictation: hands the relay resolved at start to
    /// the insertion service, or disarms the previous one.
    func armPromptRelayForSession() {
        let relay = context.opencodePromptRelay
        if isOverlayBufferModeEnabled {
            textInsertion.beginPromptRelay(relay) { [weak self] text in
                self?.commitOverlayTextThePromptRelayRefused(text)
            }
        } else {
            textInsertion.beginPromptRelay(relay)
        }
    }

    /// What the overlay commit inserts through: the relay while it is
    /// healthy, the keyboard otherwise.
    var overlayTextCommitter: any OverlayTextCommitting {
        guard textInsertion.promptRelayIsHealthy, let sink = textInsertion.promptRelaySink else {
            return textInsertion
        }
        return PromptRelayOverlayCommitter(sink: sink)
    }

    /// The overlay's text the relay did not take, committed the way the
    /// overlay commits without one: keys, then Cmd+V, to the commit target.
    private func commitOverlayTextThePromptRelayRefused(_ text: String) {
        let pid = overlayBufferCoordinator.commitTargetAppPID
        if textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid).isSuccess
            || textInsertion.pasteUsingCommandV(text, preferredAppPID: pid) {
            Log.overlay.notice("overlay commit: relay refused; text inserted by keyboard")
            return
        }
        Log.overlay.error("overlay commit: relay refused and keyboard insertion failed")
        lastError = "Unable to insert buffered text into the focused app."
    }
}

/// Commits the overlay by appending to the relay. The append is handed off,
/// not awaited: the relay delivers in order and gives a refused text back to
/// the keyboard. Secure Keyboard Entry does not stop it, since no key is
/// posted.
@MainActor
final class PromptRelayOverlayCommitter: OverlayTextCommitting {
    private let sink: OpencodePromptRelaySink

    init(sink: OpencodePromptRelaySink) {
        self.sink = sink
    }

    var isAccessibilityTrusted: Bool { true }
    var postsNoKeys: Bool { true }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID _: pid_t?) -> TextInsertResult {
        sink.append(text)
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
    }
}
