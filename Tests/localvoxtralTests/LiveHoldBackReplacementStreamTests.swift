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

    // MARK: - Replacement + hold-back policy

    func testSingleWordRuleReleasesPromptlyAtWordBoundary() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.ingest("voxtral "), "localvoxtral ")
    }

    func testTrailingPartialWordIsHeldAcrossChunks() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.ingest("vox"), "")
        XCTAssertEqual(stream.ingest("tral"), "")
        XCTAssertEqual(stream.ingest(" "), "localvoxtral ")
    }

    func testNonMatchingTextReleasesWithZeroExtraHold() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.ingest("hello world "), "hello world ")
    }

    func testMultiWordRuleSpanningIngestChunksMatches() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"]),
        ])
        XCTAssertEqual(stream.ingest("local "), "")
        // "localvoxtral" is a prefix of no rule, so it releases at once.
        XCTAssertEqual(stream.ingest("voxtral "), "localvoxtral ")
        XCTAssertEqual(stream.ingest("rocks "), "rocks ")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    func testMultiWordRuleHoldsBackPossiblePrefixWords() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
        ])
        // "cloud" alone must not be released: it could be the first word of
        // the two-word match that only completes with the next chunk.
        XCTAssertEqual(stream.ingest("use cloud "), "use ")
        // Once the match applies, neither "Claude" nor "Code" can begin a
        // rule, so both release immediately.
        XCTAssertEqual(stream.ingest("code "), "Claude Code ")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    // MARK: - Viable-prefix hold-back bound

    func testLongRuleDoesNotDelayUnrelatedWords() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["the quick brown fox"]),
        ])
        // A four-word rule used to hold three complete words of every
        // dictation. Text that begins no rule is released with no extra hold.
        XCTAssertEqual(stream.ingest("hello there wide world "), "hello there wide world ")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    func testOnlyWordsThatCanBeginARuleAreHeld() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["the quick brown fox"]),
        ])
        // "the quick" is a live prefix of the rule, so it is held; the words
        // before it are not, so they go out immediately.
        XCTAssertEqual(stream.ingest("hello world the quick "), "hello world ")
        // The match fails at "slow" — nothing here begins the rule anymore.
        XCTAssertEqual(stream.ingest("slow "), "the quick slow ")
    }

    func testMatchStartAfterPunctuationIsHeldBack() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "VOXTRAL ROCKS", matches: ["voxtral rocks"]),
        ])
        // The rule's lookbehind only forbids a preceding letter or digit, so a
        // match can start inside a whitespace-delimited word: "voxtral" here
        // begins after the hyphen. Releasing "foo-voxtral " would let the
        // correction reach back into already-typed text.
        XCTAssertEqual(stream.ingest("foo-voxtral "), "foo-")
        XCTAssertEqual(stream.ingest("rocks "), "VOXTRAL ROCKS ")
    }

    func testMatchStartAfterCombiningMarkIsHeldBack() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "VOXTRAL ROCKS", matches: ["voxtral rocks"]),
        ])
        // Decomposed "é" is a letter grapheme, but the code point immediately
        // before the match is a combining mark (category Mn), which the
        // lookbehind accepts. The candidate scan must accept it too.
        XCTAssertEqual(stream.ingest("e\u{0301}voxtral "), "e\u{0301}")
        XCTAssertEqual(stream.ingest("rocks "), "VOXTRAL ROCKS ")
    }

    func testCaseInsensitivePrefixIsHeld() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
        ])
        XCTAssertEqual(stream.ingest("use CLOUD "), "use ")
        XCTAssertEqual(stream.ingest("Code "), "Claude Code ")
    }

    func testFullCaseFoldingExpansionIsHeld() {
        // NSRegularExpression full-case-folds literals, so the rule `foo ßx`
        // matches the text "foo ssx". A literal prefix check would judge the
        // tail "foo s" dead ("ßx" does not start with "s") and release it, and
        // the correction would then rewrite text already typed.
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "X", matches: ["foo ßx"]),
        ])
        XCTAssertEqual(stream.ingest("foo s"), "")
        XCTAssertEqual(stream.ingest("sx "), "X ")
    }

    func testFullCaseFoldingLigatureIsHeld() {
        // "ﬁ" folds to "fi", so the rule `fix it` matches the text "ﬁx it".
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "REPAIRED", matches: ["fix it"]),
        ])
        XCTAssertEqual(stream.ingest("ﬁx "), "")
        XCTAssertEqual(stream.ingest("it "), "REPAIRED ")
    }

    func testKelvinSignFoldsToKAndIsHeld() {
        // U+212A KELVIN SIGN folds to "k".
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "TEMP", matches: ["kelvin scale"]),
        ])
        XCTAssertEqual(stream.ingest("\u{212A}elvin "), "")
        XCTAssertEqual(stream.ingest("scale "), "TEMP ")
    }

    func testSingleWordRuleAmongMultiWordRulesStillReleasesPromptly() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
        ])
        // maxRuleWordCount is 2, but "hello" begins neither rule.
        XCTAssertEqual(stream.ingest("hello voxtral "), "hello localvoxtral ")
    }

    func testPunctuationBoundaryCompletesMatchButHoldsUntilWhitespace() {
        var stream = makeStream(entries: [voxtralEntry])
        // "voxtral." could still grow into a different word ("voxtral.x"),
        // so it stays held until whitespace or the final flush.
        XCTAssertEqual(stream.ingest("voxtral."), "")
        XCTAssertEqual(stream.ingest(" "), "localvoxtral. ")
    }

    func testFlushRemainderAppliesFinalUnboundedWordMatch() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.ingest("voxtral"), "")
        XCTAssertEqual(stream.flushRemainder(), "localvoxtral")
    }

    func testEmojiGraphemeMatchIsReplaced() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "developer", matches: ["👩‍💻"]),
        ])
        XCTAssertEqual(stream.ingest("👩‍💻 "), "developer ")
    }

    func testNoRulesReleasesEverythingImmediately() {
        var stream = makeStream(entries: [])
        XCTAssertEqual(stream.ingest("partial-word-no-boundary"), "partial-word-no-boundary")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    func testEmptyAndWhitespaceOnlyIngest() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.ingest(""), "")
        XCTAssertEqual(stream.ingest("   "), "   ")
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    func testFlushRemainderOnEmptyStreamIsEmpty() {
        var stream = makeStream(entries: [voxtralEntry])
        XCTAssertEqual(stream.flushRemainder(), "")
    }

    // MARK: - Newline sanitization

    // Trailing spaces are buffered until the next non-whitespace character
    // (or the remainder flush) decides whether their run collapses, so the
    // sanitize-ON assertions below check ingest and flush outputs jointly.

    func testNewlineIsCollapsedToSingleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello\nworld "), "hello world")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testNewlineRunWithAdjacentSpacesProducesNoDoubleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello \n\n world "), "hello world")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testNewlineCollapseSpansReleaseBoundaries() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello\n"), "hello")
        XCTAssertEqual(stream.ingest("\n world "), " world")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testLeadingNewlinesAreDropped() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("\n\nhello "), "hello")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testCarriageReturnsAreSanitized() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("a\r\nb\rc "), "a b c")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testTabBeforeNewlineCollapsesToSingleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        // The tab precedes the newline: the whole run (tab + newline) must
        // still collapse to exactly one space.
        XCTAssertEqual(stream.ingest("cmd\t\nnext "), "cmd next")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testSpacesBeforeNewlineAcrossChunksCollapse() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        // The spaces are buffered at the chunk edge; the newline arriving in
        // the next chunk retroactively collapses the whole run.
        XCTAssertEqual(stream.ingest("cmd "), "cmd")
        XCTAssertEqual(stream.ingest("\nls "), " ls")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testStandaloneTabCollapsesToSingleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        // A synthetic Tab keystroke triggers shell completion UI — same
        // terminal-state hazard class as Enter.
        XCTAssertEqual(stream.ingest("a\tb "), "a b")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testTabRunCollapsesToSingleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("a\t\tb "), "a b")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testWhitespaceHeldAtChunkEdgeIsReleasedIntactWhenNoNewlineFollows() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("cmd "), "cmd")
        XCTAssertEqual(stream.ingest("ls "), " ls")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testPlainSpaceRunsAreReemittedVerbatim() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("a  b "), "a  b")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

    func testFlushedRemainderIsSanitized() {
        var stream = makeStream(
            entries: [ReplacementEntry(replaceWith: "X", matches: ["run something"])],
            sanitizesNewlines: true
        )
        // "run so" stays a live prefix of the rule, so everything is held back
        // and the newline reaches the remainder flush; sanitization must still
        // apply there.
        XCTAssertEqual(stream.ingest("run\nso"), "")
        XCTAssertEqual(stream.flushRemainder(), "run so")
    }

    func testCollapsedNewlineRunSpansAnEarlyRelease() {
        var stream = makeStream(
            entries: [ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"])],
            sanitizesNewlines: true
        )
        // "run" begins no rule, so it is released before the newline's fate is
        // known. The collapsed space is emitted with the next release.
        XCTAssertEqual(stream.ingest("run\nit"), "run")
        XCTAssertEqual(stream.flushRemainder(), " it")
    }

    func testSanitizationOffPreservesNewlines() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: false)
        XCTAssertEqual(stream.ingest("hello\nworld "), "hello\nworld ")
    }

    func testSanitizationOffPreservesTabs() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: false)
        XCTAssertEqual(stream.ingest("a\tb "), "a\tb ")
    }

    func testReplacementAndSanitizationCompose() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("voxtral\nrocks "), "localvoxtral rocks")
        XCTAssertEqual(stream.flushRemainder(), " ")
    }

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
