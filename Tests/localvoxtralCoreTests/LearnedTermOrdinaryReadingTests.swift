import Foundation
import XCTest
@testable import localvoxtralCore

/// The guard that keeps a learned term off ordinary words (#522). The eval over
/// whole dictations is `LearnedTermOverApplicationEvalTests`; these pin each
/// rule on its own.
final class LearnedTermOrdinaryReadingTests: XCTestCase {
    private func isOrdinary(_ term: String, _ heard: String, in transcript: String) -> Bool {
        RepoVocabularyMatcher.ordinaryReadingIsLikelier(term: term, heard: heard, transcript: transcript)
    }

    func testPlainTwoWordJoinInProseReadsOrdinary() {
        XCTAssertTrue(isOrdinary("useAuth", "use auth", in: "we should use auth tokens for the upload"))
        XCTAssertTrue(isOrdinary("isEmpty", "is empty", in: "the list is empty after a restart"))
    }

    func testSentenceStartCapitalStillReadsOrdinary() {
        XCTAssertTrue(isOrdinary("useAuth", "Use auth", in: "Use auth headers only when asked."))
        XCTAssertTrue(isOrdinary("useAuth", "Use auth", in: "It failed. Use auth headers now."))
    }

    func testCapitalMidSentenceMarksAName() {
        XCTAssertFalse(isOrdinary("SessionStart", "Session Start", in: "then Session Start fires"))
    }

    func testCodeNounAfterMarksAnIdentifier() {
        XCTAssertFalse(isOrdinary("SessionStart", "session start", in: "the session start hook fires twice"))
    }

    func testCodeNounOrVerbBeforeMarksAnIdentifier() {
        XCTAssertFalse(isOrdinary("useAuth", "use auth", in: "call use auth before the render"))
        XCTAssertFalse(isOrdinary("useAuth", "use auth", in: "la fonction use auth renvoie nil"))
        XCTAssertFalse(isOrdinary("SwiftLint", "swift lint", in: "a target that runs swift lint"))
    }

    func testCueFurtherAwayDoesNotCount() {
        // "hook" is three words before the span: out of reach.
        XCTAssertTrue(isOrdinary("isReady", "is ready", in: "the hook said it is ready"))
    }

    func testBacktickOrParenthesisMarksCode() {
        XCTAssertFalse(isOrdinary("isEmpty", "is empty", in: "check `is empty` first"))
        XCTAssertFalse(isOrdinary("isEmpty", "is empty", in: "check is empty() first"))
    }

    func testSingleWordCaseChangeIsNotGuarded() {
        XCTAssertFalse(isOrdinary("Swift", "swift", in: "a swift reply"))
    }

    func testThreeWordsAreAppliedWhateverTheContext() {
        XCTAssertFalse(isOrdinary("PushToTalk", "push to talk", in: "I prefer push to talk"))
    }

    func testAcronymHasNoOrdinaryReading() {
        XCTAssertFalse(isOrdinary("API URL", "api url", in: "so the api url uses https"))
    }

    func testDigitOrVowellessWordHasNoOrdinaryReading() {
        XCTAssertFalse(isOrdinary("llamaCpp", "llama cpp", in: "we build llama cpp nightly"))
        XCTAssertFalse(isOrdinary("h200Node", "h200 node", in: "the h200 node is down"))
    }

    func testSpokenSeparatorMarksAName() {
        XCTAssertFalse(isOrdinary("use.auth", "use dot auth", in: "open use dot auth now"))
    }

    func testJudgesTheOccurrencePreapplyingWouldRewrite() {
        // The first "is empty" sits inside `this_is empty`-like joiners and is
        // skipped by the boundary check, exactly as `preapplying` skips it.
        XCTAssertTrue(isOrdinary("isEmpty", "is empty", in: "run x_is empty then the bag is empty"))
    }

    func testWithholdingMovesTheEntryToTheFrontOfVerification() {
        let transcript = "we should use auth tokens and the tool input field"
        let outcome = RepoVocabularyMatcher.GroundingOutcome(
            entries: [
                ReplacementEntry(replaceWith: "useAuth", matches: ["use auth"]),
                ReplacementEntry(replaceWith: "toolInput", matches: ["tool input"]),
            ],
            isFallbackOnly: false,
            verificationCandidates: [ReplacementEntry(replaceWith: "Qwen", matches: ["kwen"])]
        )
        let guarded = RepoVocabularyMatcher.withholdingOrdinaryReadings(outcome, transcript: transcript)
        XCTAssertEqual(guarded.entries, [ReplacementEntry(replaceWith: "toolInput", matches: ["tool input"])])
        XCTAssertEqual(guarded.verificationCandidates, [
            ReplacementEntry(replaceWith: "useAuth", matches: ["use auth"]),
            ReplacementEntry(replaceWith: "Qwen", matches: ["kwen"]),
        ])
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(entries: guarded.entries, to: transcript),
            "we should use auth tokens and the toolInput field"
        )
    }

    func testWithholdingKeepsTheNominationCap() {
        let transcript = "we use auth and it is empty"
        let cap = RepoVocabularyMatcher.nominationCap(forTranscript: transcript)
        let outcome = RepoVocabularyMatcher.GroundingOutcome(
            entries: [ReplacementEntry(replaceWith: "useAuth", matches: ["use auth"])],
            isFallbackOnly: false,
            verificationCandidates: (0..<cap).map {
                ReplacementEntry(replaceWith: "Term\($0)", matches: ["heard \($0)"])
            }
        )
        let guarded = RepoVocabularyMatcher.withholdingOrdinaryReadings(outcome, transcript: transcript)
        XCTAssertTrue(guarded.entries.isEmpty)
        XCTAssertEqual(guarded.verificationCandidates.count, cap)
        XCTAssertEqual(guarded.verificationCandidates.first?.replaceWith, "useAuth")
    }

    func testNothingWithheldReturnsTheOutcomeUnchanged() {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "the session start hook fires",
            vocabulary: RepoVocabulary(terms: ["SessionStart"], branch: nil)
        )
        XCTAssertEqual(
            RepoVocabularyMatcher.withholdingOrdinaryReadings(outcome, transcript: "the session start hook fires"),
            outcome
        )
        XCTAssertEqual(outcome.entries.map(\.replaceWith), ["SessionStart"])
    }
}
