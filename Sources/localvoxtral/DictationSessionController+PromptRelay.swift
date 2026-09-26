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
        textInsertion.beginPromptRelay(context.agentPromptRoute, kept: { [weak self] _ in
            self?.lastError = StatusStrings.agentPromptTextKeptInHistory
        })
    }

    /// What the overlay commit inserts through: the relay while it is
    /// healthy, the keyboard otherwise.
    var overlayTextCommitter: any OverlayTextCommitting {
        guard textInsertion.promptRelayIsHealthy, let sink = textInsertion.promptRelaySink else {
            return textInsertion
        }
        return PromptRelayOverlayCommitter(sink: sink) { [weak self] text, pid in
            self?.commitOverlayTextThePromptRelayRefused(text, preferredAppPID: pid)
        }
    }

    /// The overlay's text the relay did not take, committed the way the
    /// overlay commits without one: keys, then Cmd+V, to the target the
    /// commit named when it handed the text off (the overlay may have reset
    /// since). Under Secure Keyboard Entry, or when no key lands, the text
    /// goes on the clipboard: the panel is gone, and it may exist nowhere
    /// else.
    private func commitOverlayTextThePromptRelayRefused(_ text: String, preferredAppPID pid: pid_t?) {
        if !TerminalTargetDetector.isSecureKeyboardEntryEnabled(),
           textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid).isSuccess
            || textInsertion.pasteUsingCommandV(text, preferredAppPID: pid) {
            Log.overlay.notice("overlay commit: relay refused; text inserted by keyboard")
            return
        }
        Log.overlay.error("overlay commit: relay refused and keyboard insertion unavailable; text copied")
        #if DEBUG
        // A test must never write the host's clipboard.
        if TerminalTargetDetector.isRunningUnderXCTest {
            lastError = StatusStrings.overlayCopiedToClipboard
            return
        }
        #endif
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        lastError = pasteboard.setString(text, forType: .string)
            ? StatusStrings.overlayCopiedToClipboard
            : "Unable to insert buffered text into the focused app."
    }
}

/// Commits the overlay by appending to the relay. The append is handed off,
/// not awaited: the relay delivers in order and gives a refused text back to
/// the keyboard. Secure Keyboard Entry does not stop it, since no key is
/// posted.
@MainActor
final class PromptRelayOverlayCommitter: OverlayTextCommitting {
    private let sink: AgentPromptSink
    private let refused: @MainActor (String, pid_t?) -> Void

    init(sink: AgentPromptSink, refused: @escaping @MainActor (String, pid_t?) -> Void) {
        self.sink = sink
        self.refused = refused
    }

    var isAccessibilityTrusted: Bool { true }
    var postsNoKeys: Bool { true }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult {
        let refused = self.refused
        sink.append(text) { refused($0, preferredAppPID) }
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
    }
}
