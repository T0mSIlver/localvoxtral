import XCTest
@testable import localvoxtral

#if DEBUG
/// A coding-agent TUI (Claude Code, Codex CLI, …) opens its slash-command
/// autocomplete popup while the prompt line is a bare `/token`, and its file
/// picker while the line ends in an `@token`. In both, a SPACE after the token
/// confirms/dismisses the popup — so an invisible trailing space decides what
/// the user's next keystroke does.
///
/// These tests pin where such a space can reach the focused app.
@MainActor
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
    }

    func testLoneSlashCommandWithoutTrailingWhitespaceIsUntouched() {
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

    /// A token holding a second `/` is a filesystem path, not a slash command.
    func testPathsAreNotSlashCommands() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/usr/bin "), "/usr/bin ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/tmp/x "), "/tmp/x ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/ "), "/ ")
    }

    /// A SINGLE-component token satisfies the slash-command syntax too, but
    /// `/tmp` or `/Applications` is a filesystem path the user dictated, not a
    /// command (codex review of #198, finding 2). The default existence seam
    /// is the real filesystem: `/tmp` and `/Applications` exist on every macOS
    /// host this suite runs on, so their trailing space must stay.
    func testSingleComponentExistingAbsolutePathKeepsItsTrailingSpace() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/tmp "), "/tmp ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/bin "), "/bin ")
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("/Applications "),
            "/Applications "
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

    func testMultiWordTextIsUntouched() {
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped(" /cmd extra words "),
            " /cmd extra words "
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("run /compact "),
            "run /compact "
        )
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("read Sources/App.swift then stop "),
            "read Sources/App.swift then stop "
        )
    }

    func testFrenchProseIsUntouched() {
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("Relis le fichier et corrige la faute. "),
            "Relis le fichier et corrige la faute. "
        )
        // Slash-command names are ASCII in every agent TUI we target: abstain
        // rather than guess on an accented token.
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("/compacté "), "/compacté ")
    }

    func testEmptyAndWhitespaceOnlyTextIsUntouched() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped(""), "")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("   "), "   ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("\n"), "\n")
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

    /// A bare `@` proposes nothing; `a@b` is an email address, not a mention;
    /// a token carrying prose punctuation is prose.
    func testNonMentionAtSignsAreUntouched() {
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("@ "), "@ ")
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("a@b "), "a@b ")
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("mail him at dev@example.com "),
            "mail him at dev@example.com "
        )
        XCTAssertEqual(TUIAutocompleteTrailingSpace.stripped("check @file, "), "check @file, ")
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

    /// A mention that is not the LAST token had its picker closed by the words
    /// that followed it.
    func testMentionInTheMiddleIsUntouched() {
        XCTAssertEqual(
            TUIAutocompleteTrailingSpace.stripped("@Sources/Foo.swift needs a test "),
            "@Sources/Foo.swift needs a test "
        )
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

    // MARK: - Live Auto-Paste path (the regression)

    /// Field shape: "slash compact" into a terminal in Live Auto-Paste. The ASR
    /// segment carries a trailing space, the terminal stream buffers it, and the
    /// stop flush types it — dismissing the popup the user opened.
    func testTerminalLoneSlashCommandDoesNotTypeTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/compact ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(
            typed.value.joined(), "/compact",
            "a lone slash command must reach the TUI without the space that dismisses its popup"
        )
        service.endLiveReplacementSession()
    }

    /// Same shape when the trailing space only arrives as its own delta.
    func testTerminalLoneSlashCommandWithSeparateSpaceDeltaDoesNotTypeTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/rev")
        service.enqueueRealtimeInsertion("iew")
        service.enqueueRealtimeInsertion(" ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "/review")
        service.endLiveReplacementSession()
    }

    /// The subtlest interaction: the slash command is assembled across SEVERAL
    /// releases, so the stop flush can only recognize it by consulting
    /// `liveTypedTextForSession` — the text already handed to the field. The
    /// tail space is withheld and every earlier release is left exactly as it
    /// was typed (there are no backspaces in the insertion path).
    func testTerminalSlashCommandAssembledAcrossFlushesWithholdsOnlyTheTailSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/comp")
        XCTAssertEqual(typed.value, ["/comp"], "the first release reaches the field immediately")
        service.enqueueRealtimeInsertion("act ")
        XCTAssertEqual(
            typed.value, ["/comp", "act"],
            "the second release types the word; its trailing space is buffered"
        )

        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(
            typed.value, ["/comp", "act"],
            "the stop flush must add nothing: already-typed releases are untouched "
                + "and the buffered tail space is withheld"
        )
        XCTAssertEqual(typed.value.joined(), "/compact")
        service.endLiveReplacementSession()
    }

    /// An utterance ending on an `@file` mention: the file picker is open and
    /// the trailing space would accept whatever it has highlighted.
    func testTerminalTrailingMentionDoesNotTypeTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("look at @Sources/Foo.swift ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "look at @Sources/Foo.swift")
        service.endLiveReplacementSession()
    }

    // MARK: - Live Auto-Paste path (what must NOT change)

    /// `/usr/bin` is a filesystem path, not a slash command — its trailing
    /// space is dictated content and stays.
    func testTerminalPathLikeTokenKeepsItsTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/usr/bin ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "/usr/bin ")
        service.endLiveReplacementSession()
    }

    /// Ordinary prose keeps every character the user dictated.
    func testTerminalSentenceKeepsItsTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("run the tests and fix /compact ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "run the tests and fix /compact ")
        service.endLiveReplacementSession()
    }

    /// The space between a slash command and the words that follow it is
    /// dictated content and must be typed as the session goes.
    func testTerminalSlashCommandFollowedByWordsKeepsTheInteriorSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/compact ")
        service.enqueueRealtimeInsertion("now")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "/compact now")
        service.endLiveReplacementSession()
    }

    /// ACCEPTED LIMITATION, pinned (codex review of #198, finding 1): the
    /// stop-flush verdict sees only THIS session's text. Here the focused
    /// field already holds a hand-typed "fix " before dictation starts — the
    /// real prompt line is "fix /compact", mid-line, no popup open — but the
    /// insertion path cannot read field content and no popup-state signal
    /// exists, so the dictated "/compact " still looks like a lone slash
    /// command and its trailing space is withheld. Accepted because mid-line
    /// command-shaped dictation into a pre-populated prompt is rare and the
    /// dismissed-popup case the policy exists for is the common one. If this
    /// test starts failing, someone changed that judgment — make sure it was
    /// a conscious decision, not a refactor side effect.
    func testPrePopulatedFieldTextCannotRescueTheTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        // Nothing models the pre-existing "fix " on purpose: there is no seam
        // through which the service could ever observe it.
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("/compact ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(
            typed.value.joined(), "/compact",
            "the session-local verdict must strip: field content is invisible by design"
        )
        service.endLiveReplacementSession()
    }

    /// No autocomplete popup exists outside a terminal, so a regular editor
    /// keeps exactly what was dictated.
    func testNonTerminalTargetKeepsTheTrailingSpace() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        service.enqueueRealtimeInsertion("/compact ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "/compact ")
        service.endLiveReplacementSession()
    }

    // MARK: - Harness

    private func makeService(capturing typed: Box<[String]>) -> TextInsertionService {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
        return service
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
