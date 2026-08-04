import Foundation

/// Trailing-whitespace policy for text dictated into a coding-agent TUI.
///
/// Terminal agents (Claude Code, Codex CLI, …) open a slash-command
/// autocomplete popup while the prompt line is a bare `/token`, and a file
/// picker while the line ends in an `@token`. In both, a SPACE after the token
/// confirms or dismisses that popup — so an invisible trailing space decides
/// what the user's next keystroke does.
///
/// Dictation adds exactly that space without the user ever speaking it: ASR
/// segments carry token-trailing spaces, so "slash compact" reaches the field
/// as `/compact ` and the popup is gone before the user can pick anything.
///
/// The policy is deliberately narrow — the repo's abstain-over-guess rule. It
/// removes only whitespace, only from the end, and only for two shapes:
///
/// - **Lone slash command**: the whole text is `/` followed by one run of
///   `[A-Za-z0-9_-]`. A token holding a SECOND `/` is a filesystem path
///   (`/usr/bin`, `/tmp/x`), never a slash command, and is left alone — as is
///   any text with other words in it (`fix /compact please`), where the popup
///   is already closed and the trailing space is dictated content. A
///   single-component token satisfies the same syntax, so a token naming an
///   EXISTING absolute path (`/tmp`, `/Applications`) abstains too: no agent
///   TUI ships a command that collides with a root-level entry on the same
///   machine, so existence is decisive, and a NON-existing token stays a
///   command — dictating a path to a file that is not there is far rarer than
///   dictating the command whose popup is open. Slash
///   command names are ASCII by construction in every agent TUI we target, so
///   a non-ASCII token (`/compacté`) abstains rather than guessing.
/// - **Trailing mention**: the last whitespace-separated token is `@` plus a
///   run of filename characters holding at least one name character. A bare
///   `@` proposes nothing and `a@b` is an email address, not a mention:
///   neither opens a picker, so neither is touched. A token carrying trailing
///   punctuation (`@file,`) is prose, and abstains too. The name-character
///   floor rejects degenerate punctuation-only tokens (`@.`, `@/`, `@~/`) that
///   name no file and would otherwise pass the filename-character test.
///
/// LEADING whitespace is ignored when recognizing a shape and preserved in the
/// result, so `"  /compact "` is recognized and returns `"  /compact"`. That is
/// deliberate: only the tail is ever cut, and the shape of the line the TUI
/// sees does not change with indentation the ASR happened to emit.
///
/// Nothing else is ever modified, and no character the user dictated is ever
/// removed.
enum TUIAutocompleteTrailingSpace {
    /// Characters a slash-command NAME may contain. `/` is deliberately absent:
    /// that is what separates `/compact` from the path `/usr/bin`.
    private static let slashCommandNameCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    /// Characters a mention token may contain after its `@` — filename-ish, so
    /// paths and extensions qualify while prose punctuation does not.
    private static let mentionNameCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./~"
    )

    /// The subset a mention name must contain at least one of. Without this
    /// floor, punctuation-only tokens like `@.` or `@/` — which name no file
    /// and open no picker — would satisfy the filename-character test.
    private static let mentionRequiredCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    /// Returns `text` with its trailing whitespace removed when the text is one
    /// of the two autocomplete shapes above; otherwise returns `text` unchanged.
    ///
    /// `isExistingAbsolutePath` is the filesystem-existence seam for the
    /// single-component-path abstention (tests inject a fixed set so they do
    /// not depend on the host filesystem); production uses the default, one
    /// `FileManager` stat on the stop flush.
    static func stripped(
        _ text: String,
        isExistingAbsolutePath: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var body = text
        while let last = body.last, last.isWhitespace {
            body.removeLast()
        }
        // Nothing to strip: never rewrite text that has no trailing whitespace.
        guard body.count != text.count else { return text }

        // Leading whitespace belongs to neither shape's recognition (and is
        // preserved either way — only the tail is ever cut).
        let candidate = body.drop(while: \.isWhitespace)
        if isLoneSlashCommand(candidate) {
            // `/tmp` passes the syntax test but names a root-level entry: it
            // is the path the user dictated, not a command (see the type doc).
            return isExistingAbsolutePath(String(candidate)) ? text : body
        }
        guard endsWithMentionToken(candidate) else {
            return text
        }
        return body
    }

    private static func isLoneSlashCommand(_ text: Substring) -> Bool {
        guard text.first == "/" else { return false }
        let name = text.dropFirst()
        guard !name.isEmpty else { return false }
        return name.allSatisfy { slashCommandNameCharacters.contains($0) }
    }

    private static func endsWithMentionToken(_ text: Substring) -> Bool {
        guard let token = text.split(whereSeparator: \.isWhitespace).last else { return false }
        guard token.first == "@" else { return false }
        let name = token.dropFirst()
        guard name.contains(where: { mentionRequiredCharacters.contains($0) }) else {
            return false
        }
        return name.allSatisfy { mentionNameCharacters.contains($0) }
    }
}
