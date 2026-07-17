import Foundation

/// Reads the controlling TTY of the FOCUSED terminal pane, so the Claude join
/// can resolve from the process table instead of the window title.
///
/// The title is a fought-over channel: Claude Code writes its own
/// conversation-derived titles and clobbers the `lvx-` marker whenever it is
/// responding (field finding, 2026-07-17), so a title read mid-turn abstains
/// even though the session is right there. A pane's TTY has no such war: the
/// hook publisher already reports the session's controlling TTY
/// (`ClaudeHookProcessInfo.tty`), Ghostty ≥ 1.4 exposes the focused pane's TTY
/// over AppleScript (ghostty-org/ghostty#11922), and equality is exact — two
/// sessions in the same repo sit on different TTYs, which is precisely the case
/// the workspace lookup abstains on. The marker join stays as the fallback for
/// older Ghostty and as the ONLY join for SSH-remote sessions, whose TTY names
/// a device on another machine.
@MainActor
protocol TerminalFocusedTTYReading {
    /// The `/dev/ttysNNN` path of the focused pane of `bundleID`'s frontmost
    /// window, or nil when the app is unsupported, too old to expose `tty`,
    /// Automation is denied, or the read failed. Nil means "fall back to the
    /// marker", never "guess".
    func focusedTerminalTTY(bundleID: String) -> String?
}

/// The live reader: one bounded AppleScript question to Ghostty.
@MainActor
struct GhosttyFocusedTerminalTTYReader: TerminalFocusedTTYReading {
    /// `with timeout` bounds the Apple event wait so a wedged Ghostty cannot
    /// hold dictation start hostage — the same budget discipline as the AX
    /// reader's per-message timeouts. `tell application id` of the frontmost
    /// app never launches anything: the caller only asks about an app it just
    /// observed as frontmost.
    private static let source = """
    with timeout of 1 second
        tell application id "\(TerminalScreenAllowlist.ghosttyBundleID)"
            get tty of focused terminal of selected tab of front window
        end tell
    end timeout
    """

    func focusedTerminalTTY(bundleID: String) -> String? {
        // Ghostty-only, exact match: the script is Ghostty's dictionary, and
        // sending it anywhere else is at best an error and at worst a prompt
        // to automate an app the user never pointed us at.
        guard bundleID == TerminalScreenAllowlist.ghosttyBundleID else { return nil }
        guard let script = NSAppleScript(source: Self.source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // Code only, never the message — AppleScript error strings can
            // quote window titles, and a title is content.
            // -1700: `tty` not in the dictionary (Ghostty < 1.4).
            // -1743: the user declined the Automation prompt.
            let code = (error[NSAppleScriptErrorNumber] as? Int) ?? 0
            Log.claudeContext.info(
                "Focused-pane tty unavailable (AppleScript error \(code, privacy: .public))"
            )
            return nil
        }
        return Self.validatedTTY(result.stringValue)
    }

    /// Accepts only a plausible pty device path. The value crosses from another
    /// process into a registry lookup; a reply that is not shaped like
    /// `/dev/tty…` (empty, a title, an injection attempt via a renamed app)
    /// must read as "no answer", not as a key.
    static func validatedTTY(_ raw: String?) -> String? {
        guard let raw,
              raw.hasPrefix("/dev/tty"),
              raw.count <= 64,
              raw.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else { return nil }
        return raw
    }
}
