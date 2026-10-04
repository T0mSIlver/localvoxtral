import XCTest
@testable import localvoxtralCore

final class SpokenAbortPhrasesTests: XCTestCase {
    private let send = SendNowCommandParser.defaultTriggerPhrases

    func testAnEmptyListIsValidAndStopsNothing() {
        XCTAssertEqual(SpokenAbortPhrases.validate(SendTriggerPhrases.split(" , "), sendPhrases: send), .success([]))
        XCTAssertFalse(SpokenAbortPhrases.isStopPhrase("stop", phrases: []))
    }

    func testAListIsNormalizedAndDeduplicated() {
        XCTAssertEqual(
            SpokenAbortPhrases.validate(SendTriggerPhrases.split("Stop, Claude!, stop,\nstop claude"), sendPhrases: send),
            .success(["stop", "stop claude"])
        )
    }

    func testUnsafePhrasesAreRefusedWithAReason() {
        let cases: [(String, SpokenAbortPhrases.Refusal, UInt)] = [
            ("no", .tooShort("no"), #line),
            ("stop, ...", .tooShort("..."), #line),
            ("please stop what you are doing", .tooLong("please stop what you are doing"), #line),
            ("Send it", .sendPhrase("Send it"), #line),
            ("a1, b2, c3, d4, e5, f6, g7, h8, i9", .tooShort("a1"), #line),
            ("aaa, bbb, ccc, ddd, eee, fff, ggg, hhh, iii", .tooMany, #line),
        ]
        for (typed, refusal, line) in cases {
            XCTAssertEqual(
                SpokenAbortPhrases.validate(SendTriggerPhrases.split(typed), sendPhrases: send),
                .failure(refusal), line: line
            )
        }
    }

    /// Only the whole dictation counts: a prompt that mentions the phrase
    /// is a prompt.
    func testOnlyTheWholeDictationIsAStopPhrase() {
        let phrases = ["stop claude"]
        XCTAssertTrue(SpokenAbortPhrases.isStopPhrase("Stop, Claude.", phrases: phrases))
        XCTAssertTrue(SpokenAbortPhrases.isStopPhrase("  stop claude  ", phrases: phrases))
        XCTAssertFalse(SpokenAbortPhrases.isStopPhrase("please stop claude", phrases: phrases))
        XCTAssertFalse(SpokenAbortPhrases.isStopPhrase("stop claude from retrying", phrases: phrases))
        XCTAssertFalse(SpokenAbortPhrases.isStopPhrase("", phrases: phrases))
    }

    func testAStoredListThatNoLongerValidatesLoadsAsNone() {
        XCTAssertEqual(SpokenAbortPhrases.loaded(nil, sendPhrases: send), [])
        XCTAssertEqual(SpokenAbortPhrases.loaded(["send it"], sendPhrases: send), [])
        XCTAssertEqual(SpokenAbortPhrases.loaded(["stop claude"], sendPhrases: send), ["stop claude"])
    }
}
