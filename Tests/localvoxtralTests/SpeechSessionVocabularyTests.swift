import XCTest

@testable import localvoxtral

final class SpeechSessionVocabularyTests: XCTestCase {
    func testSpeakerTermsComeFirstAndRepeatsAcrossListsCountOnce() {
        XCTAssertEqual(
            SpeechSessionVocabulary.terms(
                speakerTerms: ["herdr", " Claude Code ", ""],
                learnedTerms: ["claude code", "mlx-lm", "HERDR"]
            ),
            ["herdr", "Claude Code", "mlx-lm"]
        )
    }

    func testTheListIsCappedAtTheHelpersLimit() {
        let learned = (0..<150).map { "term\($0)" }
        let terms = SpeechSessionVocabulary.terms(speakerTerms: ["mine"], learnedTerms: learned)
        XCTAssertEqual(terms.count, SpeechSessionVocabulary.maxTerms)
        XCTAssertEqual(terms.first, "mine")
    }
}
