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
package enum ClaudeStatuslineCombine {
    /// Where the script lives, relative to home.
    package static let scriptRelativePath = ".claude/localvoxtral-statusline.sh"
    /// The `statusLine.command` a combined entry holds. Claude Code runs it
    /// through a shell, which expands the tilde.
    package static let settingsCommand = "~/" + scriptRelativePath

    static let originalPrefix = "original_command="
    static let hookPrefix = "hook="

    /// The script for `original` (the user's command, verbatim) and
    /// `hookPath` (this app's publisher binary).
    package static func script(original: String, hookPath: String) -> String {
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
    package static func parse(_ text: String) -> (original: String, hookPath: String)? {
        guard
            let parsed = assignments(in: text),
            script(original: parsed.original, hookPath: parsed.hookPath) == text
        else { return nil }
        return parsed
    }

    /// `path` as one shell word: bare when it needs no quoting, single-quoted
    /// otherwise, so an app under `~/My Apps` still runs.
    package static func shellWord(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        return !path.isEmpty && path.allSatisfy(safe.contains) ? path : shellQuote(path)
    }

    /// One POSIX single-quoted word: `'` becomes `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The value `shellQuote` wrote, read quote by quote from `index`: a run
    /// of `'…'` pieces joined by `\'`, ending at the newline after the last
    /// closing quote. Newlines inside the quotes belong to the value (a
    /// user's command can hold them, even a line starting `hook=`). Returns
    /// the value and the index just past that newline.
    private static func quotedValue(
        in text: String, from start: String.Index
    ) -> (value: String, next: String.Index)? {
        var index = start
        var value = ""
        while true {
            guard index < text.endIndex, text[index] == "'" else { return nil }
            index = text.index(after: index)
            guard let close = text[index...].firstIndex(of: "'") else { return nil }
            value += text[index..<close]
            index = text.index(after: close)
            if text[index...].hasPrefix("\\'") {
                value += "'"
                index = text.index(index, offsetBy: 2)
                continue
            }
            guard index < text.endIndex, text[index] == "\n" else { return nil }
            return (value, text.index(after: index))
        }
    }

    /// The two assignments, read in order: the hook line must start right
    /// where the user's command ends.
    private static func assignments(in text: String) -> (original: String, hookPath: String)? {
        guard let start = text.range(of: "\n" + originalPrefix),
              let original = quotedValue(in: text, from: start.upperBound),
              text[original.next...].hasPrefix(hookPrefix),
              let hook = quotedValue(
                  in: text, from: text.index(original.next, offsetBy: hookPrefix.count)
              )
        else { return nil }
        return (original.value, hook.value)
    }
}
