import Foundation

/// The "spoken clipboard-paste macro": on an Overlay Buffer commit, a spoken
/// marker phrase ("paste clipboard", "colle le presse-papiers", …) is replaced
/// by the actual contents of the user's clipboard, formatted as inline code or
/// a fenced code block. Stack traces and error logs are the one thing you can't
/// dictate but always need in a coding-agent prompt.
///
/// Pure functions on `String`, mirroring `PolishTokenGuard` /
/// `TextMergingAlgorithms`. The two halves are deliberately separated across
/// the polish boundary:
///   1. `replaceMarkersWithPlaceholder` swaps each marker for the env-var-shaped
///      `placeholder`. That placeholder is what flows through the LLM polish
///      request and the persisted session record — never the payload.
///      Both profiles independently verify its occurrence count before commit;
///      model drift therefore fails safe by discarding the polish.
///   2. `substitutePayload` runs only at the very end, after polish and the
///      profile-specific guards, replacing the placeholder with the formatted
///      clipboard payload just before commit.
enum ClipboardPayloadMacro {
    /// Env-var-shaped so it is conspicuous to the model and unlikely to be
    /// confused with dictated prose. All markers collapse to this one string.
    static let placeholder = "$LV_CLIPBOARD_PAYLOAD"

    /// A single-line payload no longer than this (after trimming) is inlined as
    /// `` `payload` `` rather than fenced.
    static let inlineCharacterThreshold = 60

    /// Head cap on the payload inside a fenced block. A pasted 200 MB log must
    /// not blow up the overlay or the committed text; the head is what matters
    /// for an error/stack trace.
    static let payloadCharacterCap = 8000

    /// Appended as the final line inside the fence when the payload was capped.
    static let truncationMarker = "… [clipboard truncated]"

    // MARK: - Marker detection

    // Case-insensitive, `\b`-guarded so a marker is matched standalone and the
    // surrounding punctuation/commas the STT sprinkles in ("… — paste clipboard
    // — …", "paste the clipboard, I think") are left untouched. English bases
    // take an optional " here"/" contents"/" content" suffix, greedily, so
    // "paste the clipboard here" consumes the " here" (longest match). French
    // tolerates the STT dropping the hyphen ("presse papiers"). A static literal:
    // a bad pattern is a coding error we want to crash on immediately.
    private static let markerRegex = try! NSRegularExpression(
        pattern:
            "(?i)\\b(?:(?:paste|insert)(?: the)? clipboard(?: here| contents?)?"
            + "|(?:colle|insère) le presse[- ]papiers?)\\b"
    )

    /// Ranges of every marker phrase in `text`, left to right, non-overlapping.
    static func detectMarkers(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        return markerRegex
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Range($0.range, in: text) }
    }

    /// Replaces every marker phrase with `placeholder`, returning the rewritten
    /// text and the number of markers replaced.
    static func replaceMarkersWithPlaceholder(in text: String) -> (text: String, count: Int) {
        let ns = text as NSString
        let matches = markerRegex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return (text, 0) }

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += placeholder
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return (result, matches.count)
    }

    // MARK: - Placeholder integrity

    /// Standalone occurrences of `placeholder` in `text` — same body-char
    /// boundary rule as `PolishTokenGuard` (an occurrence with a letter/digit/
    /// `_`/`-` glued to either side is corruption, not an occurrence). The
    /// commit path compares this count before and after polishing: the guard
    /// only verifies the placeholder SURVIVED (dedup + at-least-once), so a
    /// model output that duplicated the placeholder (payload pasted twice) or
    /// dropped one of two would otherwise sail through.
    static func standalonePlaceholderCount(in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: placeholder, range: searchRange) {
            let standaloneBefore = found.lowerBound == text.startIndex
                || !PolishTokenGuard.isBodyCharacter(text[text.index(before: found.lowerBound)])
            let standaloneAfter = found.upperBound == text.endIndex
                || !PolishTokenGuard.isBodyCharacter(text[found.upperBound])
            if standaloneBefore && standaloneAfter { count += 1 }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    // MARK: - Payload substitution

    /// Replaces every `placeholder` occurrence in `text` with the formatted
    /// `payload`. A single-line, backtick-free payload ≤
    /// `inlineCharacterThreshold` chars is inlined as `` `payload` ``; anything
    /// else becomes a fenced code block, capped at `payloadCharacterCap` (head)
    /// with a truncation marker inside the fence when it bit. Per CommonMark,
    /// the fence is one backtick longer than the longest backtick run inside
    /// the payload (minimum 3), so a payload containing ``` can never close the
    /// fence early; a payload containing any backtick is never inlined (a
    /// single-backtick wrap would break). Fences get a leading/trailing newline
    /// only when the placeholder wasn't already at a line boundary, so the
    /// block always stands on its own lines without doubling blank lines.
    static func substitutePayload(in text: String, payload: String) -> String {
        guard text.contains(placeholder) else { return text }

        // The agent prompt correctly teaches the model to put environment
        // variables in code spans, so real inference normally returns
        // `$LV_CLIPBOARD_PAYLOAD` with one backtick on each side. The wrapper
        // describes the placeholder, not the eventual payload: consume an
        // exact wrapper before applying our own inline/fenced formatting.
        // Only the exact code span is normalized; a placeholder embedded in a
        // larger user-authored code span is left alone.
        let text = text.replacingOccurrences(
            of: "`\(placeholder)`",
            with: placeholder
        )

        let clean = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if !clean.contains("\n"), !clean.contains("`"),
           clean.count <= inlineCharacterThreshold
        {
            return text.replacingOccurrences(of: placeholder, with: "`\(clean)`")
        }

        let body: String
        if clean.count > payloadCharacterCap {
            body = String(clean.prefix(payloadCharacterCap)) + "\n" + truncationMarker
        } else {
            body = clean
        }
        let fenceMarker = String(
            repeating: "`",
            count: max(3, longestBacktickRun(in: body) + 1)
        )
        let fence = "\(fenceMarker)\n\(body)\n\(fenceMarker)"

        var result = ""
        var searchStart = text.startIndex
        while let range = text.range(of: placeholder, range: searchStart..<text.endIndex) {
            result += text[searchStart..<range.lowerBound]
            let atLineStart = range.lowerBound == text.startIndex
                || text[text.index(before: range.lowerBound)] == "\n"
            let atLineEnd = range.upperBound == text.endIndex
                || text[range.upperBound] == "\n"
            result += (atLineStart ? "" : "\n") + fence + (atLineEnd ? "" : "\n")
            searchStart = range.upperBound
        }
        result += text[searchStart..<text.endIndex]
        return result
    }

    /// Length of the longest run of consecutive backticks in `s` (0 when none).
    private static func longestBacktickRun(in s: String) -> Int {
        var longest = 0
        var current = 0
        for character in s {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
