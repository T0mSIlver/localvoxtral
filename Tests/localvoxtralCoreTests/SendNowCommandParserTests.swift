import XCTest
@testable import localvoxtralCore

final class SendNowCommandParserTests: XCTestCase {
    func testParseTable() {
        // Cases from @eastokes's fork, plus the word-boundary and
        // end-of-segment edges.
        let cases: [(input: String, expected: SendNowCommandAction, line: UInt)] = [
            ("explain the error", .insertText("explain the error"), #line),
            ("   ", .none, #line),
            ("", .none, #line),
            ("send now", .pressReturn, #line),
            ("Send now.", .pressReturn, #line),
            ("  SEND IT!  ", .pressReturn, #line),
            ("send, it.", .pressReturn, #line),
            ("show me the failing test send now",
             .insertTextAndPressReturn("show me the failing test"), #line),
            ("run the focused test, send now.",
             .insertTextAndPressReturn("run the focused test"), #line),
            ("Fix the build. Send it.",
             .insertTextAndPressReturn("Fix the build"), #line),
            ("run tests\nthen report send it",
             .insertTextAndPressReturn("run tests\nthen report"), #line),
            // Leading punctuation must not shift where the text is cut.
            ("...hello send it", .insertTextAndPressReturn("...hello"), #line),
            // Word boundary: the trigger must be whole words.
            ("resend now", .insertText("resend now"), #line),
            ("please resend it", .insertText("please resend it"), #line),
            ("send item", .insertText("send item"), #line),
            ("send-it", .insertText("send-it"), #line),
            // End of segment only.
            ("send it to the reviewer", .insertText("send it to the reviewer"), #line),
            ("send now or later", .insertText("send now or later"), #line),
            ("send", .insertText("send"), #line),
            ("it", .insertText("it"), #line),
            // Codex review of #494: a punctuation-only last token is not a
            // word, so it neither hides the trigger nor moves the cut.
            ("send it .", .pressReturn, #line),
            ("Send now !", .pressReturn, #line),
            ("run the tests, send it .",
             .insertTextAndPressReturn("run the tests"), #line),
            ("run the tests send now ... !",
             .insertTextAndPressReturn("run the tests"), #line),
            ("send it later .", .insertText("send it later ."), #line),
        ]
        for testCase in cases {
            XCTAssertEqual(
                SendNowCommandParser.parse(testCase.input),
                testCase.expected,
                "input: \(testCase.input.debugDescription)",
                line: testCase.line
            )
        }
    }

    func testCustomTriggerPhrase() {
        XCTAssertEqual(
            SendNowCommandParser.parse("run the focused test ship it", triggerPhrases: ["ship it"]),
            .insertTextAndPressReturn("run the focused test")
        )
        XCTAssertEqual(
            SendNowCommandParser.parse("run it send it", triggerPhrases: ["ship it"]),
            .insertText("run it send it")
        )
    }

    func testBlankTriggerPhrasesDisableParsing() {
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrases: ["   "]),
            .insertText("send now")
        )
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrases: []),
            .insertText("send now")
        )
    }

    func testPressesReturn() {
        XCTAssertTrue(SendNowCommandAction.pressReturn.pressesReturn)
        XCTAssertTrue(SendNowCommandAction.insertTextAndPressReturn("x").pressesReturn)
        XCTAssertFalse(SendNowCommandAction.insertText("x").pressesReturn)
        XCTAssertFalse(SendNowCommandAction.none.pressesReturn)
    }

    func testNormalizedSegmentIgnoresCasePunctuationAndSpacing() {
        XCTAssertEqual(
            SendNowCommandParser.normalizedSegment("  Run the tests,   SEND IT. "),
            "run the tests send it"
        )
        XCTAssertEqual(
            SendNowCommandParser.normalizedSegment("run the tests send it"),
            SendNowCommandParser.normalizedSegment("Run the tests, send it!")
        )
    }
}
