import XCTest
@testable import localvoxtralCore

/// The spellings here are the owner's field misrecognitions (invariants.md,
/// "LLM polishing trusts the model's text" and "Suggested terms"): Coin and
/// Kuen for Qwen, `toolInput`, `SessionStart`, `useAuth.ts`, H100 for H200,
/// `pain` for `pane`.
final class CorrectionDiffClassifierTests: XCTestCase {
    private func classify(
        _ inserted: String,
        _ submitted: String,
        known: Set<String> = [],
        learned: Set<String> = []
    ) -> CorrectionDiffClassifier.Verdict {
        CorrectionDiffClassifier.classify(
            inserted: inserted,
            submitted: submitted,
            knownTerms: known,
            learnedTerms: learned
        )
    }

    // MARK: Corrections that are learned

    func testMisheardNameFixedToItsSpellingIsLearned() {
        XCTAssertEqual(
            classify("can you check why Coin 3.6 is slow", "can you check why Qwen 3.6 is slow"),
            .learn(term: "Qwen", replaced: "Coin", forgetting: nil)
        )
        XCTAssertEqual(
            classify("the Kuen tokenizer drops the BOS", "the Qwen tokenizer drops the BOS"),
            .learn(term: "Qwen", replaced: "Kuen", forgetting: nil)
        )
    }

    func testLowercaseMishearingFixedMidSentenceIsLearned() {
        XCTAssertEqual(
            classify("please fix the kwen tokenizer", "please fix the Qwen tokenizer"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testSpacedIdentifierJoinedByTheUserIsLearned() {
        XCTAssertEqual(
            classify("read the tool input field first", "read the toolInput field first"),
            .learn(term: "toolInput", replaced: "tool input", forgetting: nil)
        )
        XCTAssertEqual(
            classify("hook the session start event", "hook the SessionStart event"),
            .learn(term: "SessionStart", replaced: "session start", forgetting: nil)
        )
    }

    func testSpokenFileNameFixedToThePathIsLearned() {
        XCTAssertEqual(
            classify("open use auth dot ts and look", "open useAuth.ts and look"),
            .learn(term: "useAuth.ts", replaced: "use auth dot ts", forgetting: nil)
        )
    }

    func testDigitFixIsLearnedAndTrailingPunctuationIsNotPartOfIt() {
        XCTAssertEqual(
            classify("we rent an H100.", "we rent an H200."),
            .learn(term: "H200", replaced: "H100", forgetting: nil)
        )
        XCTAssertEqual(
            classify("is it kwen, or llama", "is it Qwen, or llama"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testTextTypedAroundTheDictationIsIgnored() {
        XCTAssertEqual(
            classify(
                "fix the kwen tokenizer",
                "context: see #412\nfix the Qwen tokenizer and run the tests"
            ),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testAFixOfTheFirstWordIsFoundBehindTypedPrefixText() {
        XCTAssertEqual(
            classify("kwen tokenizer is broken again", "hey, Qwen tokenizer is broken again"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testAFixOfTheLastWordIsFoundAheadOfTypedSuffixText() {
        XCTAssertEqual(
            classify("the slow one is kwen", "the slow one is Qwen thanks"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testClaudeCodePasteMarkersAreNotWords() {
        let submitted = "\n\n<pasted_content id=\"4bd7\">\nthe kwen server\ncrashed on load\n</pasted_content id=\"4bd7\">\n\n thanks"
        XCTAssertEqual(
            classify("the kwen server\ncrashed on load", submitted),
            .nothing(.unchanged)
        )
        let fixed = submitted.replacingOccurrences(of: "kwen", with: "Qwen")
        XCTAssertEqual(
            classify("the kwen server\ncrashed on load", fixed),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    func testAPlainCapitalizedWordIsLearnedOnlyWhenAlreadyKnown() {
        XCTAssertEqual(
            classify("Vibe is running", "Vibe is running"),
            .nothing(.unchanged)
        )
        XCTAssertEqual(
            classify("vibe runs the hooks", "Vibe runs the hooks"),
            .nothing(.notTermShaped)
        )
        XCTAssertEqual(
            classify("vibe runs the hooks", "Vibe runs the hooks", known: ["Vibe"]),
            .learn(term: "Vibe", replaced: "vibe", forgetting: nil)
        )
    }

    func testASmallUnrelatedDeletionElsewhereDoesNotBlockTheFix() {
        XCTAssertEqual(
            classify("so um please fix the kwen tokenizer", "please fix the Qwen tokenizer"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil)
        )
    }

    // MARK: Edits that are not learned

    func testOrdinaryWordFixIsNotVocabulary() {
        XCTAssertEqual(
            classify("click the terminal pain", "click the terminal pane"),
            .nothing(.notTermShaped)
        )
        XCTAssertEqual(
            classify("put it over their", "put it over there"),
            .nothing(.notTermShaped)
        )
    }

    func testSentenceStartCapitalIsNotEvidence() {
        XCTAssertEqual(
            classify("done. their tests pass", "done. There tests pass"),
            .nothing(.notTermShaped)
        )
    }

    /// Dictated lists often have no final period; capitalizing the first word
    /// of a line is still not a name (GLM review of #532).
    func testLineStartCapitalIsNotEvidence() {
        XCTAssertEqual(
            classify("fix the bug\nthen commit", "fix the bug\nThen commit"),
            .nothing(.notTermShaped)
        )
        XCTAssertEqual(
            classify("fix the bug then kwen", "fix the bug\nthen Qwen"),
            .learn(term: "Qwen", replaced: "kwen", forgetting: nil),
            "only the first word of a line is exempt"
        )
    }

    func testRewordingIsNotLearned() {
        XCTAssertEqual(
            classify("fix the bug in the parser", "fix the issue in the parser"),
            .nothing(.notSoundAlike)
        )
        XCTAssertEqual(
            classify("make the Kuen server faster", "make the Qwen server quicker"),
            .nothing(.severalFixes)
        )
    }

    func testAddedWordsAloneTeachNothing() {
        XCTAssertEqual(
            classify("make it faster", "make it much faster please"),
            .nothing(.unchanged)
        )
    }

    func testARewrittenPromptIsNotThisDictation() {
        XCTAssertEqual(
            classify(
                "can you check why the kwen server is slow today",
                "never mind, just restart the Qwen server"
            ),
            .nothing(.rewording)
        )
        XCTAssertEqual(
            classify("fix the kwen tokenizer", "something else entirely"),
            .nothing(.notFound)
        )
    }

    func testManyDeletedWordsAreRewording() {
        XCTAssertEqual(
            classify(
                "so basically what I want is for you to fix the kwen tokenizer now",
                "what I want is you to fix the Qwen tokenizer"
            ),
            .nothing(.rewording)
        )
    }

    func testALongSubstitutionIsNotAFix() {
        XCTAssertEqual(
            classify(
                "run the one two three four five tests now",
                "run the OneTwoThreeFourFive tests now"
            ),
            .nothing(.fixTooLong)
        )
    }

    func testPunctuationOnlyEditIsNotAFix() {
        XCTAssertEqual(
            classify("fix the tests", "fix the tests."),
            .nothing(.unchanged)
        )
    }

    // MARK: Reverts

    func testChangingALearnedSpellingBackForgetsIt() {
        XCTAssertEqual(
            classify(
                "hook the SessionStart event",
                "hook the session start event",
                learned: ["SessionStart"]
            ),
            .forget(term: "SessionStart")
        )
    }

    func testReplacingALearnedSpellingWithABetterOneSwapsThem() {
        XCTAssertEqual(
            classify("load Qwen weights", "load Qwen3 weights", learned: ["Qwen"]),
            .learn(term: "Qwen3", replaced: "Qwen", forgetting: "Qwen")
        )
    }

    func testRewordingAwayFromALearnedSpellingKeepsIt() {
        XCTAssertEqual(
            classify("load the Qwen weights", "load the Mistral weights", learned: ["Qwen"]),
            .nothing(.notSoundAlike)
        )
    }

    // MARK: Pieces

    func testTermShape() {
        XCTAssertTrue(CorrectionDiffClassifier.isTermShaped("Qwen", atSentenceStart: false))
        XCTAssertFalse(CorrectionDiffClassifier.isTermShaped("Qwen", atSentenceStart: true))
        XCTAssertTrue(CorrectionDiffClassifier.isTermShaped("vLLM", atSentenceStart: true))
        XCTAssertTrue(CorrectionDiffClassifier.isTermShaped(".env", atSentenceStart: true))
        XCTAssertTrue(CorrectionDiffClassifier.isTermShaped("use-auth", atSentenceStart: true))
        XCTAssertTrue(CorrectionDiffClassifier.isTermShaped("gpt4", atSentenceStart: true))
        XCTAssertFalse(CorrectionDiffClassifier.isTermShaped("there", atSentenceStart: false))
    }

    func testEdgeTrimKeepsInnerAndLeadingDots() {
        XCTAssertEqual(CorrectionDiffClassifier.trimmedEdges("useAuth.ts."), "useAuth.ts")
        XCTAssertEqual(CorrectionDiffClassifier.trimmedEdges(".env,"), ".env")
        XCTAssertEqual(CorrectionDiffClassifier.trimmedEdges("(Qwen)"), "Qwen")
    }

    func testOversizedInputIsRefusedBeforeAligning() {
        let long = Array(repeating: "word", count: CorrectionDiffClassifier.maxInsertedWords + 1)
            .joined(separator: " ")
        XCTAssertEqual(classify(long, long), .nothing(.tooLong))
    }
}
