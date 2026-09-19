import Foundation

/// The script behind Combine: it runs the user's own status line command, then
/// this app's connection indicator, and prints both on one line.
///
/// The script is the only place the user's original command is kept, so
/// Remove can put it back exactly. The app writes the script, never edits it
/// in place: `isOurs` regenerates the whole text from what it parses and
/// compares, so a hand-edited script is never overwritten or deleted.
///
/// If the app is deleted, the `[ -x "$hook" ]` guard skips the indicator
/// and the user's own status line keeps working.
public enum ClaudeStatuslineCombine {
    /// Where the script lives, relative to home.
    public static let scriptRelativePath = ".claude/localvoxtral-statusline.sh"
    /// The `statusLine.command` a combined entry holds. Claude Code runs it
    /// through a shell, which expands the tilde.
    public static let settingsCommand = "~/" + scriptRelativePath

    static let originalPrefix = "original_command="
    static let hookPrefix = "hook="

    /// The script for `original` (the user's command, verbatim) and
    /// `hookPath` (this app's publisher binary).
    public static func script(original: String, hookPath: String) -> String {
        """
        #!/bin/sh
        # Written by localvoxtral: your status line, then its connection indicator.
        # Settings > Claude Code > Status line > Remove puts your command back.
        \(originalPrefix)\(shellQuote(original))
        \(hookPrefix)\(shellQuote(hookPath))
        input=$(cat)
        yours=$(printf '%s' "$input" | sh -c "$original_command")
        lvx=''
        if [ -x "$hook" ]; then
          lvx=$(printf '%s' "$input" | "$hook" --statusline)
        fi
        if [ -n "$yours" ] && [ -n "$lvx" ]; then
          printf '%s  %s\\n' "$yours" "$lvx"
        else
          printf '%s%s\\n' "$yours" "$lvx"
        fi

        """
    }

    /// The pieces of a script this app wrote, or nil when the text is not
    /// exactly what `script(original:hookPath:)` produces for them.
    public static func parse(_ text: String) -> (original: String, hookPath: String)? {
        guard
            let original = value(after: originalPrefix, until: hookPrefix, in: text),
            let hookPath = value(after: hookPrefix, until: "input=", in: text),
            script(original: original, hookPath: hookPath) == text
        else { return nil }
        return (original, hookPath)
    }

    /// `path` as one shell word: bare when it needs no quoting, single-quoted
    /// otherwise, so an app under `~/My Apps` still runs.
    public static func shellWord(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        return !path.isEmpty && path.allSatisfy(safe.contains) ? path : shellQuote(path)
    }

    /// One POSIX single-quoted word: `'` becomes `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The quoted value after `prefix` at the start of a line, up to the next
    /// line that starts with `terminator`. A quoted value may span lines (a
    /// user's command can hold newlines), so this never stops at the first
    /// newline.
    private static func value(after prefix: String, until terminator: String, in text: String) -> String? {
        guard let start = text.range(of: "\n" + prefix),
              let end = text.range(of: "\n" + terminator, range: start.upperBound..<text.endIndex)
        else { return nil }
        let words = ClaudeStatuslineInstallService.shellWords(String(text[start.upperBound..<end.lowerBound]))
        return words.count == 1 ? words[0] : nil
    }
}
