import Foundation

/// What "Copy last dictation" puts on the clipboard (#526).
package enum LastDictationCopy {
    /// The text the dictation ended up as, or its transcript when polishing
    /// failed: a failed polish leaves nothing a model wrote, and the
    /// transcript is what the user said. Nil when there is no text at all.
    ///
    /// A dictation cut short (a socket that could not reconnect, a new
    /// dictation started over the polish) is saved with the text transcribed
    /// up to that point, so it goes through the same choice.
    ///
    /// History never stores the clipboard a "paste clipboard" dictation
    /// pulled in, only `ClipboardPayloadMacro.placeholder`. A text still
    /// holding it cannot be copied as it was inserted, so the transcript is.
    package static func text(
        rawText: String,
        polishedText: String?,
        polishFailed: Bool
    ) -> String? {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !polishFailed,
           let polished = polishedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !polished.isEmpty,
           !polished.contains(ClipboardPayloadMacro.placeholder)
        {
            return polished
        }
        return raw.isEmpty ? nil : raw
    }
}
