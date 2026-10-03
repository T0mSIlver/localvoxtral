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
        keepUntypedText(text, status: StatusStrings.agentPromptTextKeptInHistory)
    }

    /// Keeps `text`, which a stop saved as not inserted and typed nowhere: a
    /// send to a name several panes share or to a session with no route, or
    /// a picked destination that left the front (#1546).
    ///
    /// - Returns: `status` while History keeps the text; the clipboard's
    ///   sentence when it was copied instead.
    func keepUntypedText(_ text: String, status: String) -> String {
        guard !text.isEmpty,
              !(settings.dictationHistoryRetention.savesDictations && sessionStore != nil)
        else { return status }
        Log.dictation.notice("text not inserted and History is off; text copied")
        // A Cmd+V paste may still read the clipboard (#1467). The relay
        // keeps the whole text each time, so a later write may replace a
        // held one.
        textInsertion.writeClipboardAfterPendingPastes { [weak self] in
            self?.dependencies.pasteboardWriter(text)
        }
        return StatusStrings.overlayCopiedToClipboard
    }
}

/// The text a dictation's prompt relay kept, in order: the relay keeps it
/// one append at a time, and the clipboard must hold all of it.
@MainActor
final class UndeliveredAgentText {
    var text = ""
}
