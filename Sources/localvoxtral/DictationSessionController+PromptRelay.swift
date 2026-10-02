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
        promptRelaySessionID = sessionID
        textInsertion.beginPromptRelay(context.agentPromptRoute, kept: { [weak self] _ in
            self?.lastError = StatusStrings.agentPromptTextKeptInHistory
            self?.forgetLanding(ofSession: sessionID)
        })
    }

    /// What the overlay commit inserts through: the route while it takes
    /// text, the keyboard otherwise.
    var overlayTextCommitter: any OverlayTextCommitting {
        guard textInsertion.promptRelayTakesText, let sink = textInsertion.promptRelaySink else {
            return textInsertion
        }
        // Read now: an answer that comes after the next dictation armed its
        // own relay still belongs to this one.
        let sessionID = promptRelaySessionID
        return PromptRelayOverlayCommitter(sink: sink) { [weak self] text, pid in
            self?.commitOverlayTextThePromptRelayRefused(text, preferredAppPID: pid, sessionID: sessionID)
        }
    }

    /// The overlay's text the relay did not take, committed the way the
    /// overlay commits without one: keys, then Cmd+V, to the target the
    /// commit named when it handed the text off (the overlay may have reset
    /// since). Under Secure Keyboard Entry, or when no key lands, the text
    /// goes on the clipboard: the panel is gone, and it may exist nowhere
    /// else. The session's mod (#1409) gives its refusals back here too.
    func commitOverlayTextThePromptRelayRefused(
        _ text: String, preferredAppPID pid: pid_t?, sessionID: String?
    ) {
        if !TerminalTargetDetector.isSecureKeyboardEntryEnabled(),
           textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid).isSuccess
            || textInsertion.pasteUsingCommandV(text, preferredAppPID: pid) {
            Log.overlay.notice("overlay commit: relay refused; text inserted by keyboard")
            return
        }
        Log.overlay.error("overlay commit: relay refused and keyboard insertion unavailable; text copied")
        forgetLanding(ofSession: sessionID)
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

    /// The commit recorded its landing when it handed the text off. Text the
    /// relay then left on the clipboard or in History is not in the prompt,
    /// so the next commit there must not continue it: a leading space would
    /// turn `/compact` into text (docs/agent/invariants.md, "An Overlay
    /// Buffer commit starts with a space only when it continues the unsent
    /// prompt").
    private func forgetLanding(ofSession sessionID: String?) {
        guard let sessionID, lastOverlayCommitLanding?.sessionID == sessionID
        else { return }
        Log.overlay.notice("overlay commit: relay text not in the prompt; next commit adds no space")
        lastOverlayCommitLanding = nil
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
