import Foundation

/// Computes the incremental text to emit from a streaming transcript, guaranteeing that
/// the running emitted text only ever GROWS — a consumer can append each delta and never
/// has to un-type. Pure and Metal-free so it is unit-testable in the tier-0 lane.
///
/// Why this exists: the upstream `VoxtralRealtimeStreamSession` emitted the delta as
/// `fullText.dropFirst(emitted.count)` when `fullText` extended `emitted`, but re-emitted
/// the ENTIRE transcript otherwise. The "otherwise" fires routinely: when a multi-byte
/// UTF-8 character's bytes are split across two tokens, the first token decodes to a
/// trailing replacement char (U+FFFD), which the next token replaces with the real
/// character — so `fullText` is not a prefix-extension of the previous text, and the whole
/// transcript gets re-emitted. Our insertion path has no backspaces (terminals can't
/// support them), so that duplicates text on screen. Accented input (French) is the common
/// trigger.
///
/// The fix mirrors the app's hold-back philosophy: treat a trailing replacement char as
/// provisional and withhold it until it resolves. The stable prefix is then always a
/// forward extension of what was emitted before.
public enum StreamingDelta {
    public struct Result: Equatable, Sendable {
        /// Newly emitted text to append (never contradicts prior output).
        public let delta: String
        /// The full running emitted text after this step — pass back as `previouslyEmitted`.
        public let emitted: String
        /// True when `fullText` diverged from prior output beyond a provisional trailing
        /// char (should not happen at temperature 0; surfaced for observability rather than
        /// silently re-emitting).
        public let wasRewrite: Bool
    }

    /// A trailing run of U+FFFD is a multi-byte character still being assembled; hold it back.
    public static func stablePrefix(of text: String) -> Substring {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev] == "\u{FFFD}" { end = prev } else { break }
        }
        return text[text.startIndex..<end]
    }

    public static func next(previouslyEmitted: String, fullText: String) -> Result {
        let stable = String(stablePrefix(of: fullText))

        if stable.hasPrefix(previouslyEmitted) {
            return Result(
                delta: String(stable.dropFirst(previouslyEmitted.count)),
                emitted: stable,
                wasRewrite: false
            )
        }

        // Divergence beyond a provisional trailing char (should not happen at temperature 0).
        // The consumer has ALREADY typed `previouslyEmitted` and cannot un-type it, so we must
        // never move `emitted` backwards: doing so would let a later forward extension append a
        // suffix onto text the screen no longer matches, garbling it (e.g. "hello wXY" then
        // "hello world" → "hello wXYorld"). Instead hold: emit nothing and keep `emitted`
        // pinned to what was actually typed. Worst case is a stuck/slightly-wrong tail — strictly
        // safer than duplication for a no-backspace sink. `wasRewrite` surfaces it for logging.
        return Result(delta: "", emitted: previouslyEmitted, wasRewrite: true)
    }
}
