import Foundation
import XCTest
@testable import localvoxtralCore

/// The polish prompt's token sizes in Settings (#1007): the ratio a backend's
/// requests measured, the assumed one before there are any, and the
/// characters each part of the prompt adds.
final class PolishPromptTokensTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func polish(
        _ backend: UsageEntry.Backend, tokens: Int?, characters: Int?, feature: UsageEntry.Feature = .polish
    ) -> UsageEntry {
        UsageEntry(
            date: moment, feature: feature, backend: backend, model: "m",
            promptTokens: tokens, promptCharacters: characters)
    }

    // MARK: - Ratio

    func testTheRatioIsTheBackendsPolishTokensOverTheirCharacters() {
        let ratio = PolishPromptTokenRatio(entries: [
            polish(.mistral, tokens: 1_000, characters: 4_000),
            polish(.mistral, tokens: 500, characters: 3_000),
            // Another backend, another feature, and requests missing a count
            // measure nothing here.
            polish(.bundledHelper, tokens: 9_000, characters: 1_000),
            polish(.mistral, tokens: 9_000, characters: 1_000, feature: .termSuggestions),
            polish(.mistral, tokens: 9_000, characters: nil),
            polish(.mistral, tokens: nil, characters: 1_000),
        ], backend: .mistral)

        XCTAssertEqual(ratio.basis, .measured(requests: 2))
        XCTAssertEqual(ratio.tokensPerCharacter, 1_500.0 / 7_000.0, accuracy: 1e-12)
    }

    func testOnlyTheMostRecentRequestsCount() {
        let old = Array(repeating: polish(.userServer, tokens: 1_000, characters: 1_000), count: 5)
        let recent = Array(
            repeating: polish(.userServer, tokens: 1_000, characters: 5_000),
            count: PolishPromptTokenRatio.recentRequestLimit)

        let ratio = PolishPromptTokenRatio(entries: old + recent, backend: .userServer)

        XCTAssertEqual(ratio.basis, .measured(requests: PolishPromptTokenRatio.recentRequestLimit))
        XCTAssertEqual(ratio.tokensPerCharacter, 0.2, accuracy: 1e-12)
    }

    func testBeforeAnyMeasuredRequestTheAssumedRatioApplies() {
        let ratio = PolishPromptTokenRatio(
            entries: [polish(.mistral, tokens: 1_949, characters: nil)], backend: .mistral)

        XCTAssertEqual(ratio.basis, .assumed)
        XCTAssertEqual(ratio.tokensPerCharacter, PolishPromptTokenRatio.assumedTokensPerCharacter)
        XCTAssertEqual(ratio.tokens(proseCharacters: 4_600), 1_000)
    }

    func testATermListCountsMoreTokensPerCharacterThanProse() {
        let ratio = PolishPromptTokenRatio(tokensPerCharacter: 0.25, basis: .assumed)

        XCTAssertEqual(ratio.tokens(proseCharacters: 400), 100)
        XCTAssertEqual(ratio.tokens(termListCharacters: 400), 160)
    }

    func testAChatRequestRecordsItsCharactersForTheRatio() throws {
        let entry = UsageEntry.chat(
            date: moment, feature: .polish, backend: .mistral, requestedModel: "zai-glm-5-3",
            usage: LLMTokenUsage(model: nil, promptTokens: 1_949, completionTokens: 40),
            promptCharacters: 8_800)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = try encoder.encode(entry)
        let decoded = UsageLedger.entries(fromFileContents: line)

        XCTAssertEqual(decoded.first?.promptCharacters, 8_800)
        XCTAssertEqual(PolishPromptTokenRatio(entries: decoded, backend: .mistral).basis, .measured(requests: 1))
    }

    // MARK: - Parts

    func testTheInstructionsAreTheSystemPromptAndTheUserTemplateWithoutItsSlots() {
        let templates = LLMPromptTemplates(
            systemContent: "Polish it.",
            userContent: "Terms:\n{{replacement_dictionary}}\nText:\n{{input_text}}")

        XCTAssertEqual(PolishPromptParts.instructionText(templates), "Polish it.Terms:\n\nText:\n")
    }

    func testGlobalTermsAddTheirLineAndTheHeaderWhenTheyBringIt() {
        let templates = LLMPromptTemplates(systemContent: "Polish it.", userContent: "{{input_text}}")
        let line = "Names and terms they use: Qwen, vLLM\n"

        XCTAssertEqual(
            PolishPromptParts.globalTermText(templates, profile: "I write Swift.", terms: ["Qwen", "vLLM"]), line)
        XCTAssertEqual(
            PolishPromptParts.globalTermText(templates, profile: "", terms: ["Qwen", "vLLM"]),
            "\n\n" + LLMPromptTemplates.speakerProfileHeader + "\n" + line)
        XCTAssertEqual(PolishPromptParts.globalTermText(templates, profile: "", terms: []), "")
    }

    func testAProjectAddsAtMostItsLearnedSectionWithEveryTerm() {
        XCTAssertEqual(
            PolishPromptParts.projectTermText(["Qwen", "vLLM"]),
            "\n\n[Learned vocabulary]\n- Qwen: Qwen\n- vLLM: vLLM")
        XCTAssertEqual(PolishPromptParts.projectTermText([]), "")
    }
}
