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
        XCTAssertEqual(stream.ingest("voxtral "), "")
        XCTAssertEqual(stream.ingest("rocks "), "localvoxtral ")
        XCTAssertEqual(stream.flushRemainder(), "rocks ")
    }

    func testMultiWordRuleHoldsBackPossiblePrefixWords() {
        var stream = makeStream(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
        ])
        // "cloud" alone must not be released: it could be the first word of
        // the two-word match that only completes with the next chunk.
        XCTAssertEqual(stream.ingest("use cloud "), "use ")
        // Once the match applies, everything but the trailing complete word
        // (a possible prefix of the next two-word match) is released.
        XCTAssertEqual(stream.ingest("code "), "Claude ")
        XCTAssertEqual(stream.flushRemainder(), "Code ")
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

    func testNewlineIsCollapsedToSingleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello\nworld "), "hello world ")
    }

    func testNewlineRunWithAdjacentSpacesProducesNoDoubleSpace() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello \n\n world "), "hello world ")
    }

    func testNewlineCollapseSpansReleaseBoundaries() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("hello\n"), "hello ")
        XCTAssertEqual(stream.ingest("\n world "), "world ")
    }

    func testLeadingNewlinesAreDropped() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("\n\nhello "), "hello ")
    }

    func testCarriageReturnsAreSanitized() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("a\r\nb\rc "), "a b c ")
    }

    func testFlushedRemainderIsSanitized() {
        var stream = makeStream(
            entries: [ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"])],
            sanitizesNewlines: true
        )
        // Two-word rule holds everything back so the newline reaches the
        // remainder flush; sanitization must still apply there.
        XCTAssertEqual(stream.ingest("run\nit"), "")
        XCTAssertEqual(stream.flushRemainder(), "run it")
    }

    func testSanitizationOffPreservesNewlines() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: false)
        XCTAssertEqual(stream.ingest("hello\nworld "), "hello\nworld ")
    }

    func testReplacementAndSanitizationCompose() {
        var stream = makeStream(entries: [voxtralEntry], sanitizesNewlines: true)
        XCTAssertEqual(stream.ingest("voxtral\nrocks "), "localvoxtral rocks ")
    }
}
