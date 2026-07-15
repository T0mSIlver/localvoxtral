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

        // Divergence beyond a provisional trailing char. Never emit contradicting text:
        // extend only along the longest common prefix, and flag the rewrite.
        let common = commonPrefixCount(previouslyEmitted, stable)
        let emitted = String(stable.prefix(common))
        return Result(
            delta: String(emitted.dropFirst(min(previouslyEmitted.count, emitted.count))),
            emitted: emitted,
            wasRewrite: true
        )
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }
}
