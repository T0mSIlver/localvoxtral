import Foundation

/// Token sizes of the polish prompt's parts, for Settings: the fixed
/// instructions, what the global terms add, and the most one project's terms
/// can add.
///
/// No backend offers a token count before a request is sent (Mistral's API has
/// no count endpoint, and the bundled helper's tokenizer lives in polishd), so
/// a part's size is its characters times the tokens per character the current
/// backend's recent polish requests measured: the prompt tokens it reported
/// over the characters the app sent. The helper's own `prompt_tokens` feed
/// that ratio like Mistral's do, so each backend is measured with its own
/// tokenizer.
package struct PolishPromptTokenRatio: Equatable, Sendable {
    package enum Basis: Equatable, Sendable {
        /// From this many recent polish requests on the backend.
        case measured(requests: Int)
        /// No request with both counts yet: `assumedTokensPerCharacter`.
        case assumed
    }

    /// Tokens per character of the whole request, which is mostly English
    /// instructions.
    package let tokensPerCharacter: Double
    package let basis: Basis

    /// 4.6 characters a token: the bundled instructions measured 4.47 to 4.75
    /// on the Qwen3.5, GLM-4.6 and Mistral (tekken) tokenizers (2026-09-28).
    package static let assumedTokensPerCharacter = 1 / 4.6

    /// A list of terms costs more tokens per character than prose: product
    /// names, identifiers and commas split into short pieces. Measured on the
    /// same three tokenizers, 12 and 60 terms: 2.4 to 3.3 characters a token
    /// against the instructions' 4.6, so a list counts 1.6 times the ratio.
    package static let termListWeight = 1.6

    /// Recent enough to follow a change of model on the same backend.
    package static let recentRequestLimit = 20

    package init(tokensPerCharacter: Double, basis: Basis) {
        self.tokensPerCharacter = tokensPerCharacter
        self.basis = basis
    }

    /// The ratio of the backend's last `recentRequestLimit` polish requests
    /// that recorded both counts, or the assumed one before there is any.
    package init(entries: [UsageEntry], backend: UsageEntry.Backend) {
        let measured = entries
            .filter { $0.feature == .polish && $0.backend == backend }
            .compactMap { entry -> (tokens: Int, characters: Int)? in
                guard let tokens = entry.promptTokens, let characters = entry.promptCharacters,
                      tokens > 0, characters > 0
                else { return nil }
                return (tokens, characters)
            }
            .suffix(Self.recentRequestLimit)
        guard !measured.isEmpty else {
            self.init(tokensPerCharacter: Self.assumedTokensPerCharacter, basis: .assumed)
            return
        }
        let tokens = measured.reduce(0) { $0 + $1.tokens }
        let characters = measured.reduce(0) { $0 + $1.characters }
        self.init(
            tokensPerCharacter: Double(tokens) / Double(characters),
            basis: .measured(requests: measured.count)
        )
    }

    /// Prose, such as the instructions.
    package func tokens(proseCharacters characters: Int) -> Int {
        Int((Double(characters) * tokensPerCharacter).rounded())
    }

    /// A list of terms.
    package func tokens(termListCharacters characters: Int) -> Int {
        Int((Double(characters) * tokensPerCharacter * Self.termListWeight).rounded())
    }
}

/// The text each part of the polish prompt puts on the wire, built by the
/// same functions that build the request, so it can be counted in characters
/// or handed to a tokenizer.
package enum PolishPromptParts {
    /// The instructions every polish sends whatever was said: the system
    /// prompt with the reference guide, and the user template around its
    /// placeholders. `templates` must not carry the speaker profile yet.
    package static func instructionText(_ templates: LLMPromptTemplates) -> String {
        let userTemplate = ["{{input_text}}", "{{replacement_dictionary}}"].reduce(templates.userContent) {
            $0.replacingOccurrences(of: $1, with: "")
        }
        return templates.systemContent + userTemplate
    }

    /// What the global terms add to the system prompt, given the About-you
    /// text sent with them: their line, and the header when the profile is
    /// empty and the terms alone bring it.
    package static func globalTermText(
        _ templates: LLMPromptTemplates, profile: String, terms: [String]
    ) -> String {
        let with = templates.withSpeakerProfile(profile, terms: terms).systemContent
        let without = templates.withSpeakerProfile(profile).systemContent
        guard with.hasPrefix(without) else { return "" }
        return String(with.dropFirst(without.count))
    }

    /// The most a project's confirmed terms add to one request: the learned
    /// vocabulary section with every term in it, after the blank line that
    /// joins it to the sections before. A term is sent only when the
    /// dictation says something like it, so most requests carry a few lines
    /// or none. The form each term was heard as is unknown here; the term
    /// itself stands in for it.
    package static func projectTermText(_ terms: [String]) -> String {
        let entries = terms.map { ReplacementEntry(replaceWith: $0, matches: [$0]) }
        let section = RepoVocabularyMatcher.promptSection(
            entries: entries, header: RepoVocabularyMatcher.learnedVocabularyHeader)
        return section.isEmpty ? "" : "\n\n" + section
    }
}
