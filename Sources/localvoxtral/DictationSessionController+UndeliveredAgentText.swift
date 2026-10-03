import Foundation

/// Text the app did not deliver to an agent and must not type again, since
/// it may have landed (docs/agent/invariants.md). History keeps it when
/// History is on. When it is off, only Copy last dictation holds it, and the
/// next dictation replaces that, so it goes on the clipboard (#1499).
extension DictationSessionController {
    /// Keeps `text`, the whole of what was not delivered this dictation.
    ///
    /// - Returns: the popover's sentence saying where it is.
    func keepUndeliveredAgentText(_ text: String) -> String {
        guard !(settings.dictationHistoryRetention.savesDictations && sessionStore != nil) else {
            return StatusStrings.agentPromptTextKeptInHistory
        }
        Log.dictation.notice("agent text not delivered and History is off; text copied")
        dependencies.pasteboardWriter(text)
        return StatusStrings.overlayCopiedToClipboard
    }
}

/// The text a dictation's prompt relay kept, in order: the relay keeps it
/// one append at a time, and the clipboard must hold all of it.
@MainActor
final class UndeliveredAgentText {
    var text = ""
}
