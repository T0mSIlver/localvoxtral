import XCTest

@testable import localvoxtral

final class OverlayStableLineWrapperTests: XCTestCase {
    /// Ten points per character, so a line's capacity is stated in characters.
    private func makeWrapper(
        lineCharacters: Int, reserveCharacters: Int
    ) -> OverlayStableLineWrapper {
        OverlayStableLineWrapper(
            availableWidth: CGFloat(lineCharacters) * 10,
            reserveWidth: CGFloat(reserveCharacters) * 10,
            safetyMargin: 0,
            widthOf: { CGFloat($0.count) * 10 }
        )
    }

    /// Line index of every word, in order, for the wrapped text.
    private func wordLines(_ wrapped: String) -> [Int] {
        wrapped.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .flatMap { index, line in line.split(separator: " ").map { _ in index } }
    }

    // MARK: - The regression: words moving between lines mid-dictation

    /// The reported bug, as the stream produces it: deltas arrive mid-word, and
    /// a word that fits at the end of a line while half-typed is re-wrapped
    /// onto the next one as the rest of it lands.
    ///
    /// Streamed one character at a time, no word may ever change line.
    func testStreamedTextNeverMovesAWordToAnotherLine() {
        var wrapper = makeWrapper(lineCharacters: 20, reserveCharacters: 6)
        let transcript = "hello there my friend this is a stable buffer now ok"
        var lastSeen: [Int] = []

        for length in 1 ... transcript.count {
            let streamed = String(transcript.prefix(length))
            let lines = wordLines(wrapper.wrapped(streamed))
            for (word, line) in zip(lastSeen, lines) {
                XCTAssertEqual(
                    word, line,
                    "a word already on screen moved lines at \"\(streamed)\""
                )
            }
            lastSeen = lines
        }
    }

    /// The behavior a plain text engine has, and the bug as it was seen: with
    /// no reserve, a half-typed word starts at the end of the line and is
    /// re-wrapped onto the next one as the rest of it arrives.
    func testWithoutTheReserveAGrowingWordIsTheOneThatMoves() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 0)

        XCTAssertEqual(wrapper.wrapped("aaa bbb c"), "aaa bbb c")
        XCTAssertEqual(wrapper.wrapped("aaa bbb ccc"), "aaa bbb\nccc")
    }

    func testGrowingWordStartingWithLittleRoomGoesStraightToTheNextLine() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)

        // Room left after "aaa bbb" is 2 characters, under the reserve, so the
        // word that just started streams on the next line instead of at the edge.
        XCTAssertEqual(wrapper.wrapped("aaa bbb c"), "aaa bbb\nc")
        XCTAssertEqual(wrapper.wrapped("aaa bbb cc"), "aaa bbb\ncc")
    }

    func testForcedBreakSurvivesTheWordBeingCompleted() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)
        XCTAssertEqual(wrapper.wrapped("aaa bbb c"), "aaa bbb\nc")

        // "aaa bbb cc" fits a 10-character line exactly, so plain greedy
        // wrapping would pull the word back up — the same jump, upwards.
        XCTAssertEqual(wrapper.wrapped("aaa bbb cc "), "aaa bbb\ncc")
    }

    func testResetForgetsTheSessionsBreaks() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)
        XCTAssertEqual(wrapper.wrapped("aaa bbb c"), "aaa bbb\nc")

        wrapper.reset()

        XCTAssertEqual(
            wrapper.wrapped("aaa bbb cc "), "aaa bbb cc",
            "a new session wraps from scratch"
        )
    }

    // MARK: - Words the stream has finished

    func testFinishedWordsWrapTightly() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)

        // The reserve applies to the word still being streamed, not to finished
        // ones — otherwise every line would end early.
        XCTAssertEqual(wrapper.wrapped("aaa bbb cc ddd"), "aaa bbb cc\nddd")
    }

    func testTailEndedByPunctuationCountsAsFinished() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)

        XCTAssertEqual(wrapper.wrapped("aaa bbb c."), "aaa bbb c.")
    }

    func testWordLongerThanTheLineKeepsItsOwnLine() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)

        // Nothing to decide: it cannot fit anywhere, so it goes on its own line
        // and the text engine soft-wraps it.
        XCTAssertEqual(wrapper.wrapped("aaa bbbbbbbbbbbb"), "aaa\nbbbbbbbbbbbb")
    }

    func testEmptyAndWhitespaceOnlyTextAreLeftAlone() {
        var wrapper = makeWrapper(lineCharacters: 10, reserveCharacters: 3)

        XCTAssertEqual(wrapper.wrapped(""), "")
        XCTAssertEqual(wrapper.wrapped("   "), "")
    }
}
