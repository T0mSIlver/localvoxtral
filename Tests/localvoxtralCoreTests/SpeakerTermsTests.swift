import XCTest
@testable import localvoxtralCore

final class SpeakerTermsTests: XCTestCase {
    func testSanitizedTrimsDedupesCaseInsensitivelyAndKeepsFirstSpelling() {
        XCTAssertEqual(
            SpeakerTerms.sanitized(["  Qwen ", "qwen", "Claude   Code", "", "a\nb", "vLLM"]),
            ["Qwen", "Claude Code", "ab", "vLLM"]
        )
    }

    func testSanitizedDropsOverlongTermsAndCapsTheList() {
        let long = String(repeating: "x", count: SpeakerTerms.maxTermCharacters + 1)
        XCTAssertEqual(SpeakerTerms.sanitized([long, "ok"]), ["ok"])
        XCTAssertEqual(
            SpeakerTerms.sanitized((0..<500).map { "term\($0)" }).count,
            SpeakerTerms.maxTerms
        )
    }

    func testOneSubmissionAddsEveryCommaSeparatedTerm() {
        XCTAssertEqual(
            SpeakerTerms.adding("Claude Code, vLLM,qwen", to: ["Qwen"]),
            ["Qwen", "Claude Code", "vLLM"]
        )
    }

    /// The user types the right spelling only; the rule is derived from it.
    func testTermsFixCasingAndSpacingWithoutAModel() {
        let dictionary = ReplacementDictionary(entries: [])
            .adding(speakerTerms: ["Claude Code", "vLLM", "GitHub"])
        XCTAssertEqual(
            dictionary.apply(to: "ask claude  code to push the vllm patch to github"),
            "ask Claude Code to push the vLLM patch to GitHub"
        )
    }

    /// "Work" and "Vibe" are products AND ordinary words. Nothing without a
    /// model can tell them apart, so they get no rule and reach the prompt only.
    func testPlainCapitalizedWordGetsNoRule() {
        XCTAssertTrue(SpeakerTerms.replacementEntries(for: ["Work", "Vibe", "Qwen"]).isEmpty)
        XCTAssertEqual(
            ReplacementDictionary(entries: []).adding(speakerTerms: ["Work"])
                .apply(to: "the work is done"),
            "the work is done"
        )
    }

    func testHandWrittenDictionaryRuleWinsOverTheTermRule() {
        let dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Claude Code CLI", matches: ["claude code"]),
        ]).adding(speakerTerms: ["Claude Code"])
        XCTAssertEqual(dictionary.apply(to: "open claude code"), "open Claude Code CLI")
    }

    func testImportTakesTheDictionarySpellingsNotTheMishearings() {
        let dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Qwen", matches: ["coin", "kuen"]),
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
            ReplacementEntry(replaceWith: "qwen", matches: ["q n"]),
        ])
        XCTAssertEqual(SpeakerTerms.migrated(from: dictionary), ["Qwen", "Claude Code"])
    }

    /// Asserted on the correction itself: a no-op correction leaves the text
    /// unchanged, so comparing strings could not see it.
    func testLiveCorrectorEmitsNoCorrectionForATermThatIsAlreadyRight() {
        let dictionary = ReplacementDictionary(entries: []).adding(speakerTerms: ["Claude Code"])

        var right = LiveReplacementCorrector(dictionary: dictionary)
        right.recordInsertedText("open Claude Code now")
        XCTAssertNil(right.nextCompletedBoundaryCorrection())

        var wrong = LiveReplacementCorrector(dictionary: dictionary)
        wrong.recordInsertedText("open claude code now")
        XCTAssertEqual(wrong.nextCompletedBoundaryCorrection()?.replacementText, "Claude Code ")
    }

    /// "US" and "IT" are all capitals: a rule would uppercase "us" and "it".
    func testAcronymGetsNoRule() {
        XCTAssertTrue(SpeakerTerms.replacementEntries(for: ["US", "IT", "GLM", "MCP"]).isEmpty)
        XCTAssertEqual(
            ReplacementDictionary(entries: []).adding(speakerTerms: ["US", "IT"])
                .apply(to: "give it to us tomorrow"),
            "give it to us tomorrow"
        )
        XCTAssertEqual(
            SpeakerTerms.replacementEntries(for: ["vLLM", "iPhone", "GitHub"]).map(\.replaceWith),
            ["vLLM", "iPhone", "GitHub"]
        )
    }
}
