import Foundation

/// The text rules for a terminal screen read, apart from the AX round trip in
/// `TerminalScreenAXReader`, so the socket-pane and AppleScript readers apply
/// the same sanitization without AppKit.
package enum TerminalScreenText {
    /// Absolute character cap on a screen read. A tall Ghostty window on a
    /// 6K display is ~200×80 ≈ 16k characters, so this admits the full visible
    /// screen with headroom while bounding both the AX payload we retain and
    /// what a later caller could put in a prompt. Generous on purpose: the
    /// downstream excerpt cap is the prompt-budget decision, this is the
    /// safety ceiling.
    ///
    /// This bounds what a read may return into MEMORY for vocabulary matching,
    /// which is local and free. It is emphatically NOT a prompt budget — a
    /// rendered excerpt rides the grant `PolishContextBudget` allocates across
    /// every context source for one request, which is an order of magnitude
    /// smaller.
    package static let screenCharacterCap = 24_000

    /// Sanitizes and caps a raw AX string. Split out so tests can exercise the
    /// text rules without any AX involvement, and so the DEBUG seam's canned
    /// text goes through exactly the same path as live text.
    ///
    /// Control scalars are stripped through the shared clipboard sanitizer
    /// (newlines and tabs survive, so the grid's line structure does), then the
    /// head is capped. Returns nil for text that is empty or whitespace-only —
    /// a freshly cleared terminal is not context.
    package static func sanitizedScreenText(_ raw: String) -> String? {
        // Chrome stripping needs trailing-trimmed lines to match, and can
        // leave a blank run where the frame stood — hence compaction on both
        // sides. Both passes are deterministic, so identical screens still
        // sanitize identically (the reconcile comparison depends on that).
        let sanitized = compactedGridWhitespace(
            strippedIdleInputChrome(
                compactedGridWhitespace(
                    PolishContextClipboardReader.sanitizeControlCharacters(raw)
                )
            )
        )
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sanitized.count > screenCharacterCap
            ? String(sanitized.prefix(screenCharacterCap))
            : sanitized
    }

    /// Claude Code's idle input frame: a box-drawing separator row, a bare `❯`
    /// prompt, a second separator, and optionally the shortcut-hint row under
    /// it (`⏵⏵ auto mode on …`). With the input EMPTY the frame is pure
    /// chrome — no term to ground, the hint row is the pane's one perpetually
    /// animating line, and rendered into a prompt it reads as stray dividers
    /// (field report 2026-07-21). A frame with typed text (`❯ fix the bug`)
    /// is content and is kept. Lone separator rows are also kept: Claude Code
    /// uses the same rule between conversation turns, and only the exact
    /// empty-input triple is chrome. The match is STRUCTURAL, not semantic:
    /// content that reproduces the exact triple (a heredoc or pasted mock of
    /// this very UI) is stripped too — accepted, it is indistinguishable by
    /// construction. The hint row is matched by its `\u{23F5}\u{23F5}` prefix
    /// because its text varies with the mode cycle.
    package static func strippedIdleInputChrome(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var index = 0
        while index < lines.count {
            if index + 2 < lines.count,
               isInputFrameSeparator(lines[index]),
               lines[index + 1] == "❯",
               isInputFrameSeparator(lines[index + 2])
            {
                index += 3
                if index < lines.count,
                   lines[index].drop(while: { $0 == " " }).hasPrefix("⏵⏵")
                {
                    index += 1
                }
                continue
            }
            kept.append(lines[index])
            index += 1
        }
        return kept.joined(separator: "\n")
    }

    private static func isInputFrameSeparator(_ line: Substring) -> Bool {
        line.count >= 10 && line.allSatisfy { $0 == "─" }
    }

    /// The AX grid pads rows toward the pane width and reports every blank
    /// viewport row, so a mostly-empty pane arrives as kilobytes of spaces
    /// (field report 2026-07-20: an idle pane rendered ~40 blank padded lines
    /// into the polish prompt). Trailing whitespace carries no term to ground
    /// and a run of blank rows no structure worth more than one line, so both
    /// are compacted — and BEFORE the cap, where padding could otherwise evict
    /// real text from the capped head. Applied at the single sanitization seam
    /// so matching, start/stop comparison, and the rendered excerpt all see
    /// the same form (compaction is deterministic: identical screens stay
    /// identical).
    package static func compactedGridWhitespace(_ text: String) -> String {
        var lines: [Substring] = []
        var pendingBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var trimmed = line
            // Every trailing whitespace scalar except newline is padding: plain
            // space/tab, NBSP (U+00A0, which grids use for padding that must not
            // wrap), and the wider Unicode space separators (U+2000–U+200A,
            // U+3000) a terminal may emit. `isWhitespace` minus newline is that
            // class — we split on "\n" already, so a line-internal newline is
            // out of scope and preserved. A line that is ALL such whitespace
            // trims to empty and is treated as blank below, so blank-line
            // detection widens with the trim, at no extra cost.
            while let last = trimmed.last, last.isWhitespace, !last.isNewline {
                trimmed = trimmed.dropLast()
            }
            if trimmed.isEmpty {
                // Leading and trailing blank runs vanish entirely (pending is
                // only flushed when a later non-blank line arrives).
                pendingBlank = !lines.isEmpty
            } else {
                if pendingBlank {
                    lines.append("")
                    pendingBlank = false
                }
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }
}
