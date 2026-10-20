import Foundation
import XCTest

@testable import localvoxtralCore

/// #1897: Haiku repaired a misheard name to a plausible word while the
/// speaker's own spelling sat in About you, because the repair rule pointed at
/// "the speaker's terms", a block no prompt section is called.
final class PolishRepairGuideTests: XCTestCase {
    func testTheAnthropicRepairRuleNamesTheSpeakerBlockItPointsAt() {
        let system = LLMPromptTemplates(systemContent: "Rules.", userContent: "{{input_text}}")
            .withRepairGuide(for: .anthropic)
            .withReferenceGuide()
            .withSpeakerProfile("", terms: ["vidtheque"])
            .systemContent

        let label = "\"\(LLMPromptTemplates.speakerProfileLabel)\""
        let repair = system.range(of: PolishRepairGuide.systemSection)
        let speakerBlock = system.range(of: "\n\(LLMPromptTemplates.speakerProfileHeader)\n")
        XCTAssertNotNil(repair)
        XCTAssertNotNil(speakerBlock)
        XCTAssertTrue(
            PolishRepairGuide.systemSection.contains(label),
            "the rule names the speaker block by the label it opens with")
        XCTAssertTrue(LLMPromptTemplates.speakerProfileHeader.hasPrefix(LLMPromptTemplates.speakerProfileLabel))
    }

    func testOtherRequestShapesCarryNoRepairRule() {
        let templates = LLMPromptTemplates(systemContent: "Rules.", userContent: "{{input_text}}")
        for shape in [LLMPolishingRequestShape.openAICompatible, .mistral] {
            XCTAssertEqual(templates.withRepairGuide(for: shape), templates)
        }
    }
}
