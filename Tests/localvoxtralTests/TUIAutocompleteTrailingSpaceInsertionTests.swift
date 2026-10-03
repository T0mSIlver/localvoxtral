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
final class TUIAutocompleteTrailingSpaceInsertionTests: XCTestCase {
    // MARK: - The pure policy

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

    // MARK: - Live Auto-Paste path (the regression)

    /// Field shape: "slash compact" into a terminal in Live Auto-Paste. The ASR
    /// segment carries a trailing space, the terminal stream buffers it, and the
    /// stop flush types it - dismissing the popup the user opened. Each row is
    /// a fresh Live Auto-Paste session into a terminal-like target.
    func testTerminalLiveSessionWithholdsOnlyTheTuiPopupTrailingSpace() {
        let cases: [(name: String, deltas: [String], typed: String)] = [
            // A lone slash command must reach the TUI without the space that
            // dismisses its popup.
            ("lone slash command", ["/compact "], "/compact"),
            // Same shape when the trailing space only arrives as its own delta.
            ("separate space delta", ["/rev", "iew", " "], "/review"),
            // An utterance ending on an `@file` mention: the file picker is
            // open and the trailing space would accept what it has highlighted.
            ("trailing mention", ["look at @Sources/Foo.swift "], "look at @Sources/Foo.swift"),
            // `/usr/bin` is a filesystem path: its space is dictated content.
            ("path-like token", ["/usr/bin "], "/usr/bin "),
            // Ordinary prose keeps every character the user dictated.
            ("sentence", ["run the tests and fix /compact "], "run the tests and fix /compact "),
            // The space between a command and the words after it is content.
            ("command followed by words", ["/compact ", "now"], "/compact now"),
        ]
        for row in cases {
            let typed = Box<[String]>([])
            let service = makeService(capturing: typed)
            service.beginLiveReplacementSession(
                dictionary: nil,
                preferredAppPID: nil,
                isTerminalLikeTarget: true
            )
            for delta in row.deltas {
                service.enqueueRealtimeInsertion(delta)
            }
            service.flushFinalLiveReplacementCorrections()
            XCTAssertEqual(typed.value.joined(), row.typed, row.name)
            service.endLiveReplacementSession()
        }
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

    // MARK: - Live Auto-Paste path (what must NOT change)

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
