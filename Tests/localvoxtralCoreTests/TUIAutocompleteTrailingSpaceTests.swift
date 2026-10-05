import XCTest
@testable import localvoxtralCore

/// A coding-agent TUI (Claude Code, Codex CLI, …) opens its slash-command
/// autocomplete popup while the prompt line is a bare `/token`, and its file
/// picker while the line ends in an `@token`. In both, a SPACE after the token
/// confirms/dismisses the popup — so an invisible trailing space decides what
/// the user's next keystroke does.
///
/// These tests pin the policy; `TUIAutocompleteTrailingSpaceInsertionTests`
/// pins where it applies on the way to the focused app.
final class TUIAutocompleteTrailingSpaceTests: XCTestCase {
    // MARK: - The pure policy

    func testLoneSlashCommandLosesItsTrailingWhitespace() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compact "), "/compact")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compact  "), "/compact")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compact\n"), "/compact")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compact \n "), "/compact")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/review\t"), "/review")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/init "), "/init")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/agent-eval "), "/agent-eval")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/run_2 "), "/run_2")
        // Without trailing whitespace there is nothing to cut.
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compact"), "/compact")
    }

    /// Deliberate (documented on the type): leading whitespace is ignored when
    /// recognizing a shape and preserved in the result — only the tail is ever
    /// cut, and indentation the ASR happened to emit does not change the shape
    /// of the line the TUI sees.
    func testLeadingWhitespaceIsPreserved() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped(" /compact "), " /compact")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("  /compact "), "  /compact")
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped(" @Sources/Foo.swift "),
            " @Sources/Foo.swift"
        )
    }

    /// Same rule, host-independent via the injected existence seam: existence
    /// is decisive in BOTH directions — an existing path abstains, and a
    /// non-existing token (a real command like `/compact`, or nonsense like
    /// `/frobnicate`) is still treated as the command whose popup is open.
    func testExistenceSeamDecidesSingleComponentTokens() {
        let exists: (String) -> Bool = { ["/tmp", "/Applications"].contains($0) }
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("/tmp ", isExistingAbsolutePath: exists),
            "/tmp "
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped(" /Applications ", isExistingAbsolutePath: exists),
            " /Applications "
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("/compact ", isExistingAbsolutePath: exists),
            "/compact"
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("/frobnicate ", isExistingAbsolutePath: exists),
            "/frobnicate"
        )
    }

    /// Shapes that are neither a lone slash command nor a trailing mention keep
    /// every character.
    func testShapesThatAreNotALoneCommandOrTrailingMentionAreUntouched() {
        let untouched: [(name: String, text: String)] = [
            // A token holding a second `/` is a filesystem path, not a slash command.
            ("path /usr/bin", "/usr/bin "),
            ("path /tmp/x", "/tmp/x "),
            ("bare slash", "/ "),
            ("command with words", " /cmd extra words "),
            ("command after prose", "run /compact "),
            ("prose mentioning a path", "read Sources/App.swift then stop "),
            ("French prose", "Relis le fichier et corrige la faute. "),
            // Slash-command names are ASCII in every agent TUI we target:
            // abstain rather than guess on an accented token.
            ("accented command", "/compacté "),
            ("empty", ""),
            ("spaces only", "   "),
            ("newline only", "\n"),
            // A bare `@` proposes nothing; `a@b` is an email address, not a
            // mention; a token carrying prose punctuation is prose.
            ("bare at sign", "@ "),
            ("email fragment", "a@b "),
            ("email in prose", "mail him at dev@example.com "),
            ("mention with prose punctuation", "check @file, "),
            // A mention that is not the LAST token had its picker closed by
            // the words that followed it.
            ("mention in the middle", "@Sources/Foo.swift needs a test "),
        ]
        for row in untouched {
            XCTAssertEqual(
                TUIAutocompleteTrailingSpace.stripped(row.text), row.text,
                "must not rewrite: \(row.name)"
            )
        }
    }

    func testTrailingMentionLosesItsTrailingWhitespace() {
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("@Sources/Foo.swift "),
            "@Sources/Foo.swift"
        )
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@filename "), "@filename")
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("look at @Sources/Foo.swift "),
            "look at @Sources/Foo.swift"
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("regarde @src/main.rs\n"),
            "regarde @src/main.rs"
        )
    }

    /// A mention name must hold at least one name character: `.` and `/` are
    /// allowed so paths qualify, but a token made only of them names no file
    /// and opens no picker.
    func testPunctuationOnlyMentionNamesAreUntouched() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@. "), "@. ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@/ "), "@/ ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@~/ "), "@~/ ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@... "), "@... ")
        // A real path keeps working.
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@~/notes.md "), "@~/notes.md")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@./Package.swift "), "@./Package.swift")
    }

    // MARK: - Overlay Buffer commit path (characterization)

    /// The overlay stop-commit path has never had the bug: every commit goes
    /// through `insertionText(from:)`, which trims both edges before the text
    /// reaches `TextInsertionService`. Locked in here so a future change to the
    /// assembler cannot reintroduce it silently.
    func testOverlayCommitTextNeverCarriesTrailingWhitespace() {
        XCTAssertEqual(OverlayBufferTextAssembler.insertionText(from: "/compact "), "/compact")
        XCTAssertEqual(OverlayBufferTextAssembler.insertionText(from: "/compact\n"), "/compact")
        XCTAssertEqual(
            OverlayBufferTextAssembler.insertionText(from: "look at @Sources/Foo.swift "),
            "look at @Sources/Foo.swift"
        )
    }
}
