import XCTest
@testable import localvoxtralCore

/// The start-of-session term list each dictation model takes (LVX-28).
final class DictationModelCapabilitiesTests: XCTestCase {
    private let takesTerms = DictationModelCapabilities(termBias: .sessionList(maxTerms: 100))

    func testAModelThatTakesNoTermsGetsNone() {
        XCTAssertEqual(DictationModelCapabilities.audioOnly.sessionTerms(from: ["localvoxtral", "herdr"]), [])
    }

    func testSessionTermsKeepPhrasesAndDropDuplicatesAndBlanks() {
        let terms = takesTerms.sessionTerms(from: [
            "Claude  Code", "localvoxtral", "", "  \n", "LOCALVOXTRAL", "herdr, cmux",
        ])
        XCTAssertEqual(terms, ["Claude Code", "localvoxtral", "herdr, cmux"])
    }

    func testSessionTermsStopAtTheModelsCap() {
        let candidates = (0..<250).map { "term\($0)" }
        let terms = DictationModelCapabilities(termBias: .sessionList(maxTerms: 7))
            .sessionTerms(from: candidates)
        XCTAssertEqual(terms, (0..<7).map { "term\($0)" })
    }

    /// A session sends the user's language only to a model that takes it.
    func testSessionLanguageIsTheChoiceOnlyWhenTheModelTakesIt() {
        let takesLanguages = DictationModelCapabilities(termBias: .none, languages: ["en", "fr"])
        XCTAssertEqual(takesLanguages.sessionLanguage(for: "fr"), "fr")
        XCTAssertNil(takesLanguages.sessionLanguage(for: "ja"))
        XCTAssertNil(takesLanguages.sessionLanguage(for: nil))
        XCTAssertNil(DictationModelCapabilities.audioOnly.sessionLanguage(for: "fr"))
    }
}
