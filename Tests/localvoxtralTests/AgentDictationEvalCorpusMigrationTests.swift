import Foundation
import XCTest

/// The corpus check that needs the polish-only eval cases, which live in the
/// app's test target; the rest of the corpus rules are
/// `AgentDictationEvalCorpusTests`', in the core suite.
final class AgentDictationEvalCorpusMigrationTests: XCTestCase {
    private func allCases() throws -> [AgentDictationEvalCorpus.Case] {
        try AgentDictationEvalCorpus.allCases()
    }

    /// Every LLMPolishEvalSupport required/known-hard case must appear in the
    /// corpus exactly once, byte-identical: same input text (as spokenForm),
    /// same expected output / needles, same required-vs-known-hard status.
    /// LLMPolishEvalSupport stays the runtime source of truth for the
    /// polish-only eval lanes; this test pins the two representations
    /// together so neither can drift silently.
    func testMigratedCasesByteMatchLLMPolishEvalSupportOriginals() throws {
        let migrated = try allCases().filter { $0.source?.migratedFrom != nil }
        let byOriginalId = Dictionary(grouping: migrated) { $0.source?.originalId ?? "" }

        for (originalId, group) in byOriginalId {
            XCTAssertEqual(group.count, 1, "original \(originalId) migrated more than once")
        }

        let originals =
            LLMPolishEvalSupport.requiredCases.map { (original: $0, list: "LLMPolishEvalSupport.requiredCases") }
            + LLMPolishEvalSupport.knownHardCases.map { (original: $0, list: "LLMPolishEvalSupport.knownHardCases") }

        XCTAssertEqual(
            migrated.count, originals.count,
            "migration must cover every required + known-hard original, nothing more"
        )

        for (original, list) in originals {
            guard let corpusCase = byOriginalId[original.id]?.first else {
                XCTFail("original case \(original.id) is missing from the corpus migration")
                continue
            }
            XCTAssertEqual(
                corpusCase.source?.migratedFrom, list,
                "\(corpusCase.id): migratedFrom must name the originating list"
            )
            XCTAssertEqual(
                corpusCase.spokenForm, original.input,
                "\(corpusCase.id): spokenForm must byte-match the original input"
            )
            XCTAssertEqual(
                corpusCase.isCaseInsensitive, !original.caseSensitive,
                "\(corpusCase.id): must preserve the original scorer's case sensitivity"
            )
            if let expectedText = original.expectedText {
                // Currently-required original: full-output equality carries over.
                XCTAssertEqual(
                    corpusCase.intendedText, expectedText,
                    "\(corpusCase.id): intendedText must byte-match the original expectedText"
                )
                XCTAssertEqual(
                    corpusCase.status["exactText"], .required,
                    "\(corpusCase.id): migrated required case must keep exactText=required"
                )
                XCTAssertEqual(
                    corpusCase.status["tokens"], .required,
                    "\(corpusCase.id): migrated required case must keep tokens=required"
                )
            } else {
                XCTAssertEqual(
                    corpusCase.requiredTokens, original.mustContain,
                    "\(corpusCase.id): requiredTokens must byte-match the original mustContain"
                )
                XCTAssertEqual(
                    corpusCase.forbidden, original.mustNotContain,
                    "\(corpusCase.id): forbiddenSubstrings must byte-match the original mustNotContain"
                )
                XCTAssertEqual(
                    corpusCase.status["tokens"], .knownHard,
                    "\(corpusCase.id): migrated known-hard case must stay known-hard"
                )
                XCTAssertNil(
                    corpusCase.status["exactText"],
                    "\(corpusCase.id): known-hard originals had no expectedText — no exactText metric"
                )
            }
        }
    }
}
