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
}
