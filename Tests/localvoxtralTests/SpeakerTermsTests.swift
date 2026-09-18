import XCTest
@testable import localvoxtral

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

    func testLiveCorrectorDoesNotRetypeATermThatIsAlreadyRight() {
        let dictionary = ReplacementDictionary(entries: []).adding(speakerTerms: ["Claude Code"])
        XCTAssertEqual(
            LiveReplacementCorrector.completedBoundaryCorrectedText(
                "open Claude Code now", dictionary: dictionary
            ),
            "open Claude Code now"
        )
        XCTAssertEqual(
            LiveReplacementCorrector.completedBoundaryCorrectedText(
                "open claude code now", dictionary: dictionary
            ),
            "open Claude Code now"
        )
    }
}

final class SpeakerTermsPromptTests: XCTestCase {
    private let templates = LLMPromptTemplates(
        systemContent: "SYSTEM",
        userContent: "{{replacement_dictionary}}\n{{input_text}}"
    )

    func testTermsAloneStillProduceTheAboutYouBlock() {
        XCTAssertEqual(
            templates.withSpeakerProfile("", terms: ["Qwen", "Claude Code"]).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "Names and terms they use: Qwen, Claude Code\n"
        )
    }

    func testProfileComesBeforeTheTerms() {
        XCTAssertEqual(
            templates.withSpeakerProfile("I run inference.", terms: ["vLLM"]).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "I run inference.\nNames and terms they use: vLLM\n"
        )
    }

    func testNothingTypedLeavesThePromptByteExact() {
        XCTAssertEqual(templates.withSpeakerProfile(" ", terms: ["", "  "]), templates)
    }
}
