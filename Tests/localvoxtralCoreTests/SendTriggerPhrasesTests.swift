import XCTest
@testable import localvoxtralCore

final class SendTriggerPhrasesTests: XCTestCase {
    func testAListIsNormalizedAndDeduplicated() {
        XCTAssertEqual(
            SendTriggerPhrases.validate(SendTriggerPhrases.split("Ship It!, over and out,\nship it, ")),
            .success(["ship it", "over and out"])
        )
    }

    func testUnsafePhrasesAreRefusedWithAReason() {
        let cases: [(String, SendTriggerPhrases.Refusal, UInt)] = [
            ("", .empty, #line),
            (" , ,", .empty, #line),
            ("send it, ...", .empty, #line),
            ("done", .commonWord("done"), #line),
            ("send it, Go", .commonWord("Go"), #line),
            ("ok", .commonWord("ok"), #line),
            ("please send this one now", .tooLong("please send this one now"), #line),
            ((1...9).map { "phrase number \($0)" }.joined(separator: ","), .tooMany, #line),
        ]
        for (input, refusal, line) in cases {
            XCTAssertEqual(
                SendTriggerPhrases.validate(SendTriggerPhrases.split(input)), .failure(refusal), line: line)
        }
        XCTAssertEqual(
            SendTriggerPhrases.Refusal.commonWord("done").message,
            "\u{201C}done\u{201D} is too common a word: it would send in the middle of what you say."
        )
    }

    /// A one-word phrase that is not a common word is allowed.
    func testARareSingleWordIsAccepted() {
        XCTAssertEqual(SendTriggerPhrases.validate(["dispatch"]), .success(["dispatch"]))
    }

    func testAStoredListThatNoLongerValidatesLoadsAsTheDefault() {
        XCTAssertEqual(SendTriggerPhrases.loaded(nil), SendNowCommandParser.defaultTriggerPhrases)
        XCTAssertEqual(SendTriggerPhrases.loaded(["done"]), SendNowCommandParser.defaultTriggerPhrases)
        XCTAssertEqual(SendTriggerPhrases.loaded(["ship it"]), ["ship it"])
    }

    /// A custom phrase triggers, and the default then does not.
    func testACustomPhraseReplacesTheDefault() {
        let phrases = ["ship it"]
        XCTAssertEqual(
            SendNowCommandParser.parse("run the tests, ship it.", triggerPhrases: phrases),
            .insertTextAndPressReturn("run the tests")
        )
        XCTAssertEqual(
            SendNowCommandParser.parse("run the tests, send it.", triggerPhrases: phrases),
            .insertText("run the tests, send it.")
        )
    }

    func testOnlyAToggledOrCapturedDictationStopsByVoice() {
        XCTAssertTrue(SpokenStopRule.stopsByVoice(.toggled))
        XCTAssertTrue(SpokenStopRule.stopsByVoice(.quickCapture))
        XCTAssertFalse(SpokenStopRule.stopsByVoice(.held))
    }

    func testOnlyATrailingPhraseEndsTheDictation() {
        let phrases = SendNowCommandParser.defaultTriggerPhrases
        XCTAssertTrue(SpokenStopRule.endsInSendPhrase("run the tests, send it.", phrases: phrases))
        XCTAssertFalse(SpokenStopRule.endsInSendPhrase("saying send it in the overlay", phrases: phrases))
    }
}
