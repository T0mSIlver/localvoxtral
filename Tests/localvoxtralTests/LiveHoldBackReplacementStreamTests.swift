import XCTest
@testable import localvoxtral

final class LiveHoldBackReplacementStreamTests: XCTestCase {
    private func makeStream(
        entries: [ReplacementEntry],
        sanitizesNewlines: Bool = false
    ) -> LiveHoldBackReplacementStream {
        LiveHoldBackReplacementStream(
            dictionary: ReplacementDictionary(entries: entries),
            sanitizesNewlines: sanitizesNewlines
        )
    }

    private var voxtralEntry: ReplacementEntry {
        ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"])
    }

    /// A stream built from `entries`, fed `steps` in order: each chunk with the
    /// text its `ingest` must release, then the expected `flushRemainder()`
    /// (nil: the case never flushes).
    private struct StreamCase {
        let name: String
        let entries: [ReplacementEntry]
        let steps: [(chunk: String, released: String)]
        let flush: String?
    }

    private func assertStreamCases(
        _ cases: [StreamCase],
        sanitizesNewlines: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            var stream = makeStream(entries: testCase.entries, sanitizesNewlines: sanitizesNewlines)
            for (index, step) in testCase.steps.enumerated() {
                XCTAssertEqual(
                    stream.ingest(step.chunk),
                    step.released,
                    "\(testCase.name): ingest #\(index + 1)",
                    file: file,
                    line: line
                )
            }
            if let flush = testCase.flush {
                XCTAssertEqual(
                    stream.flushRemainder(), flush, "\(testCase.name): flushRemainder", file: file, line: line
                )
            }
        }
    }

    // MARK: - Replacement + hold-back policy

    func testReplacementHoldBackPolicy() {
        let cases: [StreamCase] = [
            StreamCase(
                name: "SingleWordRuleReleasesPromptlyAtWordBoundary",
                entries: [voxtralEntry],
                steps: [("voxtral ", "localvoxtral ")],
                flush: nil
            ),
            StreamCase(
                name: "TrailingPartialWordIsHeldAcrossChunks",
                entries: [voxtralEntry],
                steps: [("vox", ""), ("tral", ""), (" ", "localvoxtral ")],
                flush: nil
            ),
            StreamCase(
                name: "NonMatchingTextReleasesWithZeroExtraHold",
                entries: [voxtralEntry],
                steps: [("hello world ", "hello world ")],
                flush: nil
            ),
            // "localvoxtral" is a prefix of no rule, so it releases at once.
            StreamCase(
                name: "MultiWordRuleSpanningIngestChunksMatches",
                entries: [ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"])],
                steps: [("local ", ""), ("voxtral ", "localvoxtral "), ("rocks ", "rocks ")],
                flush: ""
            ),
            // "cloud" alone must not be released: it could be the first word of
            // the two-word match that only completes with the next chunk.
            // Once the match applies, neither "Claude" nor "Code" can begin a
            // rule, so both release immediately.
            StreamCase(
                name: "MultiWordRuleHoldsBackPossiblePrefixWords",
                entries: [ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"])],
                steps: [("use cloud ", "use "), ("code ", "Claude Code ")],
                flush: ""
            ),
        ]
        assertStreamCases(cases)
    }

    // MARK: - Viable-prefix hold-back bound

    func testViablePrefixHoldBackBound() {
        let cases: [StreamCase] = [
            // A four-word rule used to hold three complete words of every
            // dictation. Text that begins no rule is released with no extra hold.
            StreamCase(
                name: "LongRuleDoesNotDelayUnrelatedWords",
                entries: [ReplacementEntry(replaceWith: "Claude Code", matches: ["the quick brown fox"])],
                steps: [("hello there wide world ", "hello there wide world ")],
                flush: ""
            ),
            // "the quick" is a live prefix of the rule, so it is held; the words
            // before it are not, so they go out immediately.
            // The match fails at "slow" — nothing here begins the rule anymore.
            StreamCase(
                name: "OnlyWordsThatCanBeginARuleAreHeld",
                entries: [ReplacementEntry(replaceWith: "Claude Code", matches: ["the quick brown fox"])],
                steps: [("hello world the quick ", "hello world "), ("slow ", "the quick slow ")],
                flush: nil
            ),
            // The rule's lookbehind only forbids a preceding letter or digit, so a
            // match can start inside a whitespace-delimited word: "voxtral" here
            // begins after the hyphen. Releasing "foo-voxtral " would let the
            // correction reach back into already-typed text.
            StreamCase(
                name: "MatchStartAfterPunctuationIsHeldBack",
                entries: [ReplacementEntry(replaceWith: "VOXTRAL ROCKS", matches: ["voxtral rocks"])],
                steps: [("foo-voxtral ", "foo-"), ("rocks ", "VOXTRAL ROCKS ")],
                flush: nil
            ),
            // Decomposed "é" is a letter grapheme, but the code point immediately
            // before the match is a combining mark (category Mn), which the
            // lookbehind accepts. The candidate scan must accept it too.
            StreamCase(
                name: "MatchStartAfterCombiningMarkIsHeldBack",
                entries: [ReplacementEntry(replaceWith: "VOXTRAL ROCKS", matches: ["voxtral rocks"])],
                steps: [("e\u{0301}voxtral ", "e\u{0301}"), ("rocks ", "VOXTRAL ROCKS ")],
                flush: nil
            ),
            StreamCase(
                name: "CaseInsensitivePrefixIsHeld",
                entries: [ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"])],
                steps: [("use CLOUD ", "use "), ("Code ", "Claude Code ")],
                flush: nil
            ),
            // NSRegularExpression full-case-folds literals, so the rule `foo ßx`
            // matches the text "foo ssx". A literal prefix check would judge the
            // tail "foo s" dead ("ßx" does not start with "s") and release it, and
            // the correction would then rewrite text already typed.
            StreamCase(
                name: "FullCaseFoldingExpansionIsHeld",
                entries: [ReplacementEntry(replaceWith: "X", matches: ["foo ßx"])],
                steps: [("foo s", ""), ("sx ", "X ")],
                flush: nil
            ),
            // "ﬁ" folds to "fi", so the rule `fix it` matches the text "ﬁx it".
            StreamCase(
                name: "FullCaseFoldingLigatureIsHeld",
                entries: [ReplacementEntry(replaceWith: "REPAIRED", matches: ["fix it"])],
                steps: [("ﬁx ", ""), ("it ", "REPAIRED ")],
                flush: nil
            ),
            // U+212A KELVIN SIGN folds to "k".
            StreamCase(
                name: "KelvinSignFoldsToKAndIsHeld",
                entries: [ReplacementEntry(replaceWith: "TEMP", matches: ["kelvin scale"])],
                steps: [("\u{212A}elvin ", ""), ("scale ", "TEMP ")],
                flush: nil
            ),
            // `apply()` resumes scanning past the inserted replacement text, so a
            // replacement that reproduces its own key cannot be re-matched forever.
            // If that ever regresses, the app hangs mid-dictation rather than
            // failing a test — pin it here.
            StreamCase(
                name: "ReplacementContainingItsOwnKeyTerminates",
                entries: [ReplacementEntry(replaceWith: "big foo", matches: ["foo"])],
                steps: [("foo bar ", "big foo bar ")],
                flush: nil
            ),
            StreamCase(
                name: "ReplacementContainingItsOwnKeyTerminates_nested",
                entries: [ReplacementEntry(replaceWith: "xyz abc def", matches: ["abc def"])],
                steps: [("abc def tail ", "xyz abc def tail ")],
                flush: nil
            ),
            // maxRuleWordCount is 2, but "hello" begins neither rule.
            StreamCase(
                name: "SingleWordRuleAmongMultiWordRulesStillReleasesPromptly",
                entries: [
                    ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                    ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
                ],
                steps: [("hello voxtral ", "hello localvoxtral ")],
                flush: nil
            ),
            // "voxtral." could still grow into a different word ("voxtral.x"),
            // so it stays held until whitespace or the final flush.
            StreamCase(
                name: "PunctuationBoundaryCompletesMatchButHoldsUntilWhitespace",
                entries: [voxtralEntry],
                steps: [("voxtral.", ""), (" ", "localvoxtral. ")],
                flush: nil
            ),
            StreamCase(
                name: "FlushRemainderAppliesFinalUnboundedWordMatch",
                entries: [voxtralEntry],
                steps: [("voxtral", "")],
                flush: "localvoxtral"
            ),
            StreamCase(
                name: "EmojiGraphemeMatchIsReplaced",
                entries: [ReplacementEntry(replaceWith: "developer", matches: ["👩‍💻"])],
                steps: [("👩‍💻 ", "developer ")],
                flush: nil
            ),
            StreamCase(
                name: "NoRulesReleasesEverythingImmediately",
                entries: [],
                steps: [("partial-word-no-boundary", "partial-word-no-boundary")],
                flush: ""
            ),
            StreamCase(
                name: "EmptyAndWhitespaceOnlyIngest",
                entries: [voxtralEntry],
                steps: [("", ""), ("   ", "   ")],
                flush: ""
            ),
            StreamCase(
                name: "FlushRemainderOnEmptyStreamIsEmpty",
                entries: [voxtralEntry],
                steps: [],
                flush: ""
            ),
        ]
        assertStreamCases(cases)
    }

    // MARK: - Newline sanitization

    // Trailing spaces are buffered until the next non-whitespace character
    // (or the remainder flush) decides whether their run collapses, so the
    // sanitize-ON assertions below check ingest and flush outputs jointly.

    func testNewlineSanitization() {
        let cases: [StreamCase] = [
            StreamCase(
                name: "NewlineIsCollapsedToSingleSpace",
                entries: [voxtralEntry],
                steps: [("hello\nworld ", "hello world")],
                flush: " "
            ),
            StreamCase(
                name: "NewlineRunWithAdjacentSpacesProducesNoDoubleSpace",
                entries: [voxtralEntry],
                steps: [("hello \n\n world ", "hello world")],
                flush: " "
            ),
            StreamCase(
                name: "NewlineCollapseSpansReleaseBoundaries",
                entries: [voxtralEntry],
                steps: [("hello\n", "hello"), ("\n world ", " world")],
                flush: " "
            ),
            StreamCase(
                name: "LeadingNewlinesAreDropped",
                entries: [voxtralEntry],
                steps: [("\n\nhello ", "hello")],
                flush: " "
            ),
            StreamCase(
                name: "CarriageReturnsAreSanitized",
                entries: [voxtralEntry],
                steps: [("a\r\nb\rc ", "a b c")],
                flush: " "
            ),
            // The tab precedes the newline: the whole run (tab + newline) must
            // still collapse to exactly one space.
            StreamCase(
                name: "TabBeforeNewlineCollapsesToSingleSpace",
                entries: [voxtralEntry],
                steps: [("cmd\t\nnext ", "cmd next")],
                flush: " "
            ),
            // The spaces are buffered at the chunk edge; the newline arriving in
            // the next chunk retroactively collapses the whole run.
            StreamCase(
                name: "SpacesBeforeNewlineAcrossChunksCollapse",
                entries: [voxtralEntry],
                steps: [("cmd ", "cmd"), ("\nls ", " ls")],
                flush: " "
            ),
            // A synthetic Tab keystroke triggers shell completion UI — same
            // terminal-state hazard class as Enter.
            StreamCase(
                name: "StandaloneTabCollapsesToSingleSpace",
                entries: [voxtralEntry],
                steps: [("a\tb ", "a b")],
                flush: " "
            ),
            StreamCase(
                name: "TabRunCollapsesToSingleSpace",
                entries: [voxtralEntry],
                steps: [("a\t\tb ", "a b")],
                flush: " "
            ),
            StreamCase(
                name: "WhitespaceHeldAtChunkEdgeIsReleasedIntactWhenNoNewlineFollows",
                entries: [voxtralEntry],
                steps: [("cmd ", "cmd"), ("ls ", " ls")],
                flush: " "
            ),
            StreamCase(
                name: "PlainSpaceRunsAreReemittedVerbatim",
                entries: [voxtralEntry],
                steps: [("a  b ", "a  b")],
                flush: " "
            ),
            // French typography: the NBSP before `?` is dictated content. It is
            // buffered like a plain space (so no release ends in whitespace) and
            // re-emitted VERBATIM — sanitization must not rewrite it to an ASCII
            // space, which would change the user's French spacing.
            StreamCase(
                name: "NonBreakingSpaceIsBufferedAndReemittedVerbatim",
                entries: [voxtralEntry],
                steps: [("oui\u{00A0}", "oui"), ("? ", "\u{00A0}?")],
                flush: " "
            ),
            // An NBSP adjacent to a newline joins the run: the whole run collapses
            // to exactly one ASCII space, same as adjacent plain spaces.
            StreamCase(
                name: "NonBreakingSpaceAdjacentToNewlineCollapsesWithTheRun",
                entries: [voxtralEntry],
                steps: [("a\u{00A0}\nb ", "a b")],
                flush: " "
            ),
            // "run so" stays a live prefix of the rule, so everything is held back
            // and the newline reaches the remainder flush; sanitization must still
            // apply there.
            StreamCase(
                name: "FlushedRemainderIsSanitized",
                entries: [ReplacementEntry(replaceWith: "X", matches: ["run something"])],
                steps: [("run\nso", "")],
                flush: "run so"
            ),
            // "run" begins no rule, so it is released before the newline's fate is
            // known. The collapsed space is emitted with the next release.
            StreamCase(
                name: "CollapsedNewlineRunSpansAnEarlyRelease",
                entries: [ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"])],
                steps: [("run\nit", "run")],
                flush: " it"
            ),
            StreamCase(
                name: "ReplacementAndSanitizationCompose",
                entries: [voxtralEntry],
                steps: [("voxtral\nrocks ", "localvoxtral rocks")],
                flush: " "
            ),
        ]
        assertStreamCases(cases, sanitizesNewlines: true)
    }

    func testSanitizationOffPreservesWhitespace() {
        let cases: [StreamCase] = [
            StreamCase(
                name: "SanitizationOffPreservesNewlines",
                entries: [voxtralEntry],
                steps: [("hello\nworld ", "hello\nworld ")],
                flush: nil
            ),
            StreamCase(
                name: "SanitizationOffPreservesTabs",
                entries: [voxtralEntry],
                steps: [("a\tb ", "a\tb ")],
                flush: nil
            ),
        ]
        assertStreamCases(cases, sanitizesNewlines: false)
    }

    // MARK: - Mid-session releases never end in whitespace (sanitize ON)

    // Load-bearing invariant, not an incidental property: because the
    // sanitizer buffers every trailing whitespace run until the next
    // non-whitespace character, NO `ingest` output can end in whitespace when
    // sanitization is on. That makes `flushRemainder()` the single point where
    // a terminal can ever receive a trailing space — which is exactly what
    // `TextInsertionService`'s TUI-autocomplete trailing-space policy relies on
    // to strip that space without ever needing to un-type text
    // (`TUIAutocompleteTrailingSpace`). Reordering the whitespace flush would
    // silently reintroduce the dismissed-popup bug, so pin it here.
    func testSanitizingIngestNeverReturnsTextEndingInWhitespace() {
        let chunkSequences: [[String]] = [
            ["/compact "],
            ["/comp", "act "],
            ["hello world "],
            ["hello\n"],
            ["hello\t"],
            ["hello \n\n "],
            ["a\r\n"],
            ["run the tests   "],
            ["look at @Sources/Foo.swift "],
            ["voxtral "],
            ["voxtral\nrocks "],
            ["one ", "two ", "three "],
            ["trailing", " ", " ", " "],
            ["\n\nleading "],
            [" "],
            ["\t\n "],
            // Non-ASCII whitespace (codex review of #198, finding 3): French
            // typography puts NBSP (U+00A0) / narrow NBSP (U+202F) before
            // `?!:;`, and the ASR path never normalizes them away — they are
            // whitespace and must be buffered exactly like a plain space,
            // never emitted at the tail of a mid-session release.
            ["mot\u{00A0}"],
            ["/compact\u{00A0}"],
            ["continuer\u{202F}"],
            ["oui\u{00A0}", "? "],
        ]

        for chunks in chunkSequences {
            var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
            for chunk in chunks {
                let released = stream.ingest(chunk)
                XCTAssertFalse(
                    released.last?.isWhitespace ?? false,
                    "mid-session release \(released.debugDescription) ends in whitespace "
                        + "for chunks \(chunks) — flushRemainder() must stay the only "
                        + "path that emits a trailing space to a terminal"
                )
            }
        }
    }

    // The same invariant does NOT hold with sanitization off — that path
    // releases whitespace as it arrives, which is why the trailing-space policy
    // is scoped to terminal-like targets only.
    func testNonSanitizingIngestCanReturnTextEndingInWhitespace() {
        var stream = makeStream(entries: [], sanitizesNewlines: false)
        XCTAssertEqual(stream.ingest("/compact "), "/compact ")
    }

    // MARK: - Rule chaining (a correction rewrites held text into rule-key words)

    /// PR #100 review finding, exact repro: rules `"x y" -> "bar"` and
    /// `"foo bar z" -> "FOO"`. The viable-prefix bound used to release "foo "
    /// after chunk 1 (the scan saw only "x ", no live prefix at "foo x"),
    /// chunk 2 then corrected the held "x y " into "bar ", and chunk 3
    /// matched "foo bar z" starting inside RELEASED text — a correction that
    /// would rewrite text already typed into the user's app. The rule set has
    /// chaining potential, so the stream must hold to the word-count floor:
    /// nothing is released until the chain resolves, and the final output is
    /// the fully corrected text with no rewrite of released offsets.
    func testChainedRuleMatchNeverReachesReleasedText() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "bar", matches: ["x y"]),
            ReplacementEntry(replaceWith: "FOO", matches: ["foo bar z"]),
        ])
        XCTAssertEqual(stream.ingest("foo x "), "")
        XCTAssertEqual(stream.ingest("y "), "")
        XCTAssertEqual(stream.ingest("z "), "")
        XCTAssertEqual(stream.flushRemainder(), "FOO ")
        #if DEBUG
            XCTAssertEqual(stream.debugDroppedCorrectionCount, 0)
        #endif
    }

    /// A rule can chain with ITSELF when its replacement reproduces an
    /// interior word of its own key: with `"a b c" -> "b"`, correcting
    /// "a a b c " turns the held tail into "b " right after the released
    /// "a ", and the next "c " completes a fresh "a b c" match starting at
    /// offset 0 — inside released text. Batch semantics for the whole
    /// transcript "a a b c c " are "b ".
    func testSelfChainingRuleMatchNeverReachesReleasedText() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "b", matches: ["a b c"]),
        ])
        XCTAssertEqual(stream.ingest("a a "), "")
        XCTAssertEqual(stream.ingest("b c "), "")
        XCTAssertEqual(stream.ingest("c "), "")
        XCTAssertEqual(stream.flushRemainder(), "b ")
        #if DEBUG
            XCTAssertEqual(stream.debugDroppedCorrectionCount, 0)
        #endif
    }

    /// Second review round, finding 1: a DELETION rule (`um -> ""`) has no
    /// replacement words for chaining detection to compare, but it chains by
    /// BRIDGING — deleting the word between two key words lets the other
    /// key's `\s+` separators match across the release boundary. "hello "
    /// must not be released before the deletion resolves, and the output
    /// must equal the batch result "HW ".
    func testDeletionRuleBridgingNeverReachesReleasedText() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "", matches: ["um"]),
            ReplacementEntry(replaceWith: "HW", matches: ["hello world"]),
        ])
        XCTAssertEqual(stream.ingest("hello um"), "")
        XCTAssertEqual(stream.ingest(" world "), "")
        XCTAssertEqual(stream.flushRemainder(), "HW ")
        #if DEBUG
            XCTAssertEqual(stream.debugDroppedCorrectionCount, 0)
        #endif
    }

    /// Second review round, finding 2: the word floor is NOT correct under
    /// deletion rules — `lookbackStart` counts words in POST-deletion text,
    /// so deleting held words lets a later lookback cross the release
    /// boundary even in floor mode. The unrelated `p q -> r2` / `r2 s -> S`
    /// pair forces floor mode; the deletion rule must escalate the whole set
    /// to hold-until-flush, and the output must equal the batch result "RK ".
    func testDeletionRuleDefeatsWordFloorNeverReachesReleasedText() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "", matches: ["aa bb cc"]),
            ReplacementEntry(replaceWith: "RK", matches: ["r k"]),
            ReplacementEntry(replaceWith: "r2", matches: ["p q"]),
            ReplacementEntry(replaceWith: "S", matches: ["r2 s"]),
        ])
        XCTAssertEqual(stream.ingest("r aa bb cc"), "")
        XCTAssertEqual(stream.ingest(" k "), "")
        XCTAssertEqual(stream.flushRemainder(), "RK ")
        #if DEBUG
            XCTAssertEqual(stream.debugDroppedCorrectionCount, 0)
        #endif
    }

    func testDeletionRuleSetHoldsEverythingUntilFlush() {
        // A deletion rule selects hold-until-flush: even text no rule could
        // ever match stays held mid-session and is released only at flush.
        var deleting = makeStream(entries: [
            ReplacementEntry(replaceWith: "", matches: ["um"]),
        ])
        XCTAssertEqual(deleting.ingest("hello world "), "")
        XCTAssertEqual(deleting.flushRemainder(), "hello world ")

        // Same rule shape with a word-bearing replacement keeps the prior
        // bounds — here the viable-prefix bound, releasing immediately.
        var keeping = makeStream(entries: [
            ReplacementEntry(replaceWith: "uh", matches: ["um"]),
        ])
        XCTAssertEqual(keeping.ingest("hello world "), "hello world ")
        XCTAssertEqual(keeping.flushRemainder(), "")
    }

    func testDeletionRuleDetection() {
        func hasDeletionRule(_ entries: [ReplacementEntry]) -> Bool {
            LiveReplacementCorrector(dictionary: ReplacementDictionary(entries: entries))
                .hasDeletionRule
        }
        XCTAssertTrue(hasDeletionRule([
            ReplacementEntry(replaceWith: "", matches: ["um"]),
        ]))
        // Whitespace-only replacements delete their match's words just the same.
        XCTAssertTrue(hasDeletionRule([
            ReplacementEntry(replaceWith: "  ", matches: ["um"]),
        ]))
        XCTAssertFalse(hasDeletionRule([
            ReplacementEntry(replaceWith: "uh", matches: ["um"]),
        ]))
    }

    private var chainingEntries: [ReplacementEntry] {
        [
            ReplacementEntry(replaceWith: "bar", matches: ["x y"]),
            ReplacementEntry(replaceWith: "FOO", matches: ["foo bar z"]),
        ]
    }

    func testChainingRuleSetFallsBackToWordFloor() {
        var stream = makeStream(entries: chainingEntries)
        // maxRuleWordCount is 3, so the old global floor holds the last two
        // complete words of even unrelated text.
        XCTAssertEqual(stream.ingest("hello there world "), "hello ")
        XCTAssertEqual(stream.flushRemainder(), "there world ")
    }

    func testNonChainingRuleSetKeepsViablePrefixBound() {
        // Same key shapes as `chainingEntries`, but no replacement word feeds
        // any rule key — unrelated text must keep releasing with no extra hold.
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "QQ", matches: ["x y"]),
            ReplacementEntry(replaceWith: "FOO", matches: ["foo bar z"]),
        ])
        XCTAssertEqual(stream.ingest("hello there world "), "hello there world ")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    // MARK: - Chaining detection

    private func hasChainingPotential(_ entries: [ReplacementEntry]) -> Bool {
        LiveReplacementCorrector(dictionary: ReplacementDictionary(entries: entries))
            .hasChainingPotential
    }

    func testChainingDetectionFlagsReplacementWordInAnotherRulesKey() {
        XCTAssertTrue(hasChainingPotential(chainingEntries))
    }

    func testChainingDetectionIgnoresDisjointRuleSets() {
        XCTAssertFalse(hasChainingPotential([
            ReplacementEntry(replaceWith: "QQ", matches: ["x y"]),
            ReplacementEntry(replaceWith: "FOO", matches: ["foo bar z"]),
        ]))
        // The suite's shared invariant dictionary must stay on the fast bound,
        // or the batch-equivalence tests would silently stop covering it.
        XCTAssertFalse(
            LiveReplacementCorrector(dictionary: invariantDictionary).hasChainingPotential
        )
    }

    func testChainingDetectionComparesWithFullCaseFolding() {
        // Simple case folding: replacement "BAR" feeds the key word "bar".
        XCTAssertTrue(hasChainingPotential([
            ReplacementEntry(replaceWith: "BAR", matches: ["x y"]),
            ReplacementEntry(replaceWith: "FOO", matches: ["foo bar z"]),
        ]))
        // Full case folding: "ßx" and "ssx" are the same folded word, exactly
        // as the matcher sees them.
        XCTAssertTrue(hasChainingPotential([
            ReplacementEntry(replaceWith: "ssx", matches: ["hello"]),
            ReplacementEntry(replaceWith: "X", matches: ["a ßx b"]),
        ]))
    }

    func testChainingDetectionIgnoresOwnKeyEdgeWords() {
        // Echo-style replacements reproduce their own key's first/last words;
        // those cannot chain (see `hasChainingPotential`) and must not push
        // the rule set onto the slow floor.
        XCTAssertFalse(hasChainingPotential([
            ReplacementEntry(replaceWith: "big foo", matches: ["foo"]),
        ]))
        XCTAssertFalse(hasChainingPotential([
            ReplacementEntry(replaceWith: "xyz abc def", matches: ["abc def"]),
        ]))
    }

    func testChainingDetectionFlagsOwnKeyInteriorWord() {
        XCTAssertTrue(hasChainingPotential([
            ReplacementEntry(replaceWith: "b", matches: ["a b c"]),
        ]))
    }

    #if DEBUG
        /// Backstop for any gap in chaining detection: with the viable-prefix
        /// bound forced back on, the chained "foo bar z" correction reaches
        /// offset 0 after "foo " was already released. It must be dropped —
        /// released text is in the user's app and can never be un-typed — so
        /// the final output keeps the released words verbatim instead of
        /// rewriting them. (In production this path also logs an error; the
        /// old `assert` was compiled out of release builds entirely.)
        func testCorrectionReachingReleasedTextIsDroppedNeverApplied() {
            var stream = makeStream(entries: chainingEntries)
            stream.debugForceViablePrefixBound = true
            XCTAssertEqual(stream.ingest("foo x "), "foo ")
            XCTAssertEqual(stream.ingest("y "), "")
            // The chained correction is dropped; the held tail releases
            // uncorrected — the best end state achievable without un-typing.
            XCTAssertEqual(stream.ingest("z "), "bar z ")
            XCTAssertEqual(stream.flushRemainder(), "")
            XCTAssertEqual(stream.debugDroppedCorrectionCount, 1)
        }
    #endif

    // MARK: - Never-un-type invariant

    /// The dictionary the invariant tests run against.
    ///
    /// `cloud code` deliberately has no single-word `cloud` rule: a shorter
    /// rule matching the multi-word rule's first word would fire at that word's
    /// boundary and rewrite the text, so the multi-word rule could never reach
    /// back across a release and the hazard would never be generated.
    private var invariantDictionary: ReplacementDictionary {
        ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
            ReplacementEntry(replaceWith: "FOX", matches: ["the quick brown fox"]),
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            // Full-case-folding expansion: matches the text "gross ssx".
            ReplacementEntry(replaceWith: "SS", matches: ["gross ßx"]),
            // A replacement that reproduces its own key's first word. A
            // correction rewriting released text could still reproduce it
            // verbatim, so only the in-stream assertion catches that.
            ReplacementEntry(replaceWith: "foo baz", matches: ["foo bar"]),
        ])
    }

    /// The stream only ever appends released text, so text released early can
    /// never be taken back. Releasing too early therefore shows up as a final
    /// output that disagrees with correcting the whole transcript in one pass.
    /// This is the hold-back bound's core invariant: for ANY chunking, the
    /// concatenated releases must equal the batch result.
    private func assertReleasedTextMatchesBatch(
        _ text: String,
        chunkSizes: [Int] = [1, 2, 3, 5, 1024],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let dictionary = invariantDictionary
        let batch = LiveReplacementCorrector.completedBoundaryCorrectedText(
            text,
            dictionary: dictionary,
            includeFinalUnboundedWord: true
        )

        for size in chunkSizes {
            var stream = LiveHoldBackReplacementStream(
                dictionary: dictionary,
                sanitizesNewlines: false
            )
            var released = ""
            var remaining = Substring(text)
            while !remaining.isEmpty {
                let take = min(size, remaining.count)
                released += stream.ingest(String(remaining.prefix(take)))
                remaining = remaining.dropFirst(take)
            }
            released += stream.flushRemainder()

            XCTAssertEqual(
                released,
                batch,
                "chunk size \(size) diverged for input \(String(reflecting: text))",
                file: file,
                line: line
            )
            #if DEBUG
                // A dropped correction is the invariant guard firing — output
                // equality alone could mask a violation whose rewrite happens
                // to reproduce the released text.
                XCTAssertEqual(
                    stream.debugDroppedCorrectionCount,
                    0,
                    "chunk size \(size) dropped a correction for input \(String(reflecting: text))",
                    file: file,
                    line: line
                )
            #endif
        }
    }

    func testReleasedTextMatchesBatchCorrectionForAdversarialInputs() {
        // Match starts that are not whitespace-delimited word starts, near
        // misses, case folding, and a decomposed combining mark.
        for text in [
            "foo-cloud code ",
            "e\u{0301}cloud code ",
            "hello foo-cloud code world ",
            "foo-cloud code",
            "CLOUD Code ",
            "cloud. code ",
            "the quick brown fox ",
            "hello the quick brown slow ",
            "the quick brown fox",
            "cloud cloud code ",
            "voxtral foo-cloud code ",
            "gross ssx ",
            "gross s",
            "hello gross ssx world ",
            "foo bar ",
            "foo bar foo bar ",
            "ﬁx it ",
        ] {
            assertReleasedTextMatchesBatch(text)
        }
    }

    func testReleasedTextMatchesBatchCorrectionForRandomChunkings() {
        let vocabulary = [
            "cloud", "code", "the", "quick", "brown", "fox", "hello", "world",
            "clouds", "codes", "foo-cloud", "e\u{0301}cloud", "CLOUD", "cloud.",
            "voxtral", "local", "gross", "ssx", "ßx", "foo", "bar", "baz",
        ]

        var generator = SeededGenerator(seed: 0x5EED_1234)
        for _ in 0 ..< 400 {
            let wordCount = Int.random(in: 1 ... 9, using: &generator)
            var text = ""
            for _ in 0 ..< wordCount {
                text += vocabulary.randomElement(using: &generator)! + " "
            }
            if Bool.random(using: &generator) {
                text = String(text.dropLast())
            }
            let size = Int.random(in: 1 ... 4, using: &generator)
            assertReleasedTextMatchesBatch(text, chunkSizes: [size])
        }
    }
}

/// Deterministic RNG: the suite forbids wall-clock and other nondeterminism,
/// and a failing property case must be reproducible from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var result = state
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}
