import Foundation

/// The rule Anthropic models get on top of the profile's prompt (#1895).
///
/// The bundled prompts say "cleanup, not rewriting" and "when in doubt, keep
/// the text as dictated". GLM 5.3 reads that loosely and still repairs words
/// the speech-to-text system misheard; Claude Haiku reads it to the letter and
/// copies them (a near-homophone left in place of the word meant, a misheard
/// tool name left beside the speaker's own term for it). This section tells
/// it that repair is the job, and that the speaker's own names come first:
/// pointed only at "the speaker's terms", Haiku left a listed name misheard
/// (#1897). It is applied by request shape, not by backend mode, so an
/// External URL server on `api.anthropic.com` gets it too, and every other
/// model's request stays byte for byte what it was.
package enum PolishRepairGuide {
    package static let systemSection = """
        Repairing what the speech-to-text system got wrong. The rules above say to keep \
        the speaker's wording. That never means keeping a word the speech-to-text system \
        misheard: repair the transcript, don't copy it.
        - Names first. The speaker's own names and terms are listed under "About the \
        speaker" at the end of these instructions (their tools, products, models, projects \
        and skills). A word or phrase that sounds like one of them, or like a name in the \
        reference material, is that name, even when an ordinary word or a better-known \
        name would also make sense there: write it exactly as spelled in the list. For \
        example, if the speaker lists "Kubrix", "deploy it on cube ricks" -> "deploy it on \
        Kubrix". Never put a name where nothing sounds like it.
        - A word or phrase that makes no sense where it stands was almost always misheard. \
        Replace it with what the speaker most plausibly said, judged by how it sounds and \
        by the rest of the text: "can you right a test for it" -> "can you write a test \
        for it", "we should catch the results between runs" -> "we should cache the \
        results between runs".
        - Drop false starts, stutters and repeated words: "it's on the on the main \
        branch" -> "it's on the main branch", "what do we, what should we ship first" -> \
        "what should we ship first".
        - Spoken sentences often run together or break in the wrong place. Join or split \
        them so each sentence reads as one clear thought, and add the small words (a \
        missing "you", "to" or "the") a sentence needs to read correctly.
        - Keep the speaker's voice: their words, their order, their questions and their \
        hedges ("I don't know", "maybe"). This is repair, not summarizing, and it never \
        adds an idea they did not say.
        """
}

extension LLMPromptTemplates {
    /// These templates with `PolishRepairGuide` appended to the system prompt
    /// when the request goes to Anthropic, and unchanged otherwise. Applied
    /// right after the profile's own rules, before the reference guide;
    /// requests get both through `withPolishGuides(for:)`.
    func withRepairGuide(for shape: LLMPolishingRequestShape) -> LLMPromptTemplates {
        guard shape == .anthropic else { return self }
        return LLMPromptTemplates(
            systemContent: "\(systemContent)\n\n\(PolishRepairGuide.systemSection)\n",
            userContent: userContent
        )
    }
}
