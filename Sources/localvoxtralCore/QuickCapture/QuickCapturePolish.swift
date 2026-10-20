import Foundation

/// A capture's words after the one polish it gets before routing (#970).
package struct QuickCapturePolish: Equatable, Sendable {
    package let text: String
    package let durationSeconds: Double

    package init(text: String, durationSeconds: Double) {
        self.text = text
        self.durationSeconds = durationSeconds
    }
}

/// Polishes a capture's words with the user's polishing model. Nil when
/// there is no polishing configuration or the request failed: the capture
/// then routes its raw words.
@MainActor
package protocol QuickCapturePolishing {
    func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish?
}

/// The spellings a capture is polished with (#970). No project is joined
/// at capture time, so they come from every project the router offers: its
/// name, its repository's name, and its confirmed learned terms. Agent
/// proposals and terms below the confirmation bar stay out.
package enum QuickCapturePolishVocabulary {
    package static let maxTermsPerProject = 10
    package static let maxTerms = 80

    /// Every project's names first, so a long term list cannot crowd one
    /// out, then each project's confirmed terms, strongest first, up to
    /// `maxTermsPerProject`. Case-folded duplicates are dropped.
    package static func terms(projects: [QuickCaptureProject], learned: LearnedTerms) -> [String] {
        terms(
            names: projects.map { project in
                [project.name] + (project.repository?.split(separator: "/").last.map { [String($0)] } ?? [])
            },
            confirmed: projects.map { project in project.keys.flatMap { learned.confirmedTerms(projectKey: $0) } }
        )
    }

    /// The same list from each project's names and confirmed terms, both in
    /// project order: for a replay, whose projects come from a file.
    package static func terms(names: [[String]], confirmed: [[String]]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        @discardableResult
        func add(_ term: String) -> Bool {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard terms.count < maxTerms, !trimmed.isEmpty,
                  seen.insert(trimmed.caseFoldedForMatching).inserted
            else { return false }
            terms.append(trimmed)
            return true
        }
        for projectNames in names {
            for name in projectNames { add(name) }
        }
        for projectTerms in confirmed {
            var added = 0
            for term in projectTerms where added < maxTermsPerProject {
                if add(term) { added += 1 }
            }
        }
        return terms
    }
}

/// The capture's side of the polish request: the working text with the
/// matched spellings pre-applied, and the vocabulary sections for the
/// `{{replacement_dictionary}}` slot. The vocabulary goes through the same
/// matcher, merge and rendering a dictation's learned terms do, as the
/// learned source alone.
package enum QuickCapturePolishPrompt {
    package struct Prepared: Equatable, Sendable {
        package let workingText: String
        package let dictionarySection: String
    }

    /// - Parameter rendersDictionary: the prompt template has the
    ///   `{{replacement_dictionary}}` slot. Without it the matched spellings
    ///   are still pre-applied.
    package static func prepare(transcript: String, vocabulary: [String], rendersDictionary: Bool) -> Prepared {
        let outcome = LearnedTermGrounding.outcome(transcript: transcript, confirmed: vocabulary, proposals: [])
        let merged = PolishContextGrounding.merge(
            [
                PolishContextGrounding.Candidate(
                    source: .learned,
                    entries: outcome.entries,
                    isFallbackOnly: outcome.isFallbackOnly,
                    phoneticEntries: outcome.phoneticEntries,
                    verificationEntries: outcome.verificationCandidates
                ),
            ],
            maxVerificationPairs: RepoVocabularyMatcher.nominationCap(forTranscript: transcript)
        )
        let workingText = RepoVocabularyMatcher.preapplying(entries: merged.all, to: transcript)
        guard rendersDictionary else { return Prepared(workingText: workingText, dictionarySection: "") }
        let section = RepoVocabularyMatcher.appendedVerificationSection(
            base: RepoVocabularyMatcher.appendedPromptSection(
                base: "", entries: merged.entries(from: .learned), header: RepoVocabularyMatcher.learnedVocabularyHeader
            ),
            pairs: merged.verificationPairs
        )
        return Prepared(workingText: workingText, dictionarySection: section)
    }
}

/// What a capture's polish request is built from besides the words and the
/// vocabulary: the standard profile's templates as loaded, the user's About
/// you and Global terms, and the replacement file's rules when exact
/// replacement is on (nil when it is off).
package struct QuickCapturePolishInputs: Sendable {
    package var templates: LLMPromptTemplates
    package var speakerProfile: String
    package var speakerTerms: [String]
    package var replacementDictionary: ReplacementDictionary?
    /// The polishing backend's request format, which decides whether the
    /// repair guide goes in.
    package var requestShape: LLMPolishingRequestShape

    package init(
        templates: LLMPromptTemplates, speakerProfile: String = "", speakerTerms: [String] = [],
        replacementDictionary: ReplacementDictionary? = nil,
        requestShape: LLMPolishingRequestShape = .openAICompatible
    ) {
        self.templates = templates
        self.speakerProfile = speakerProfile
        self.speakerTerms = speakerTerms
        self.replacementDictionary = replacementDictionary
        self.requestShape = requestShape
    }
}

/// A capture's polish request: the working text, the system prompt and the
/// user messages, as the polishing endpoint gets them.
package struct QuickCapturePolishRequest: Equatable, Sendable {
    package let inputText: String
    package let systemPrompt: String
    package let userPrompts: [String]

    /// The chat messages: the system prompt when there is one, then each
    /// user message, as a chat/completions body orders them.
    package var messages: [[String: String]] {
        (systemPrompt.isEmpty ? [] : [["role": "system", "content": systemPrompt]])
            + userPrompts.map { ["role": "user", "content": $0] }
    }
}

extension QuickCapturePolishPrompt {
    /// The whole request, as a dictation's polish assembles its own: the
    /// replacement rules and the casing of the user's terms applied first,
    /// then the vocabulary matched, into the profile's templates with the
    /// polish guides and About you.
    package static func request(
        transcript: String, vocabulary: [String], inputs: QuickCapturePolishInputs
    ) -> QuickCapturePolishRequest {
        let templates = inputs.templates.withPolishGuides(for: inputs.requestShape)
            .withSpeakerProfile(inputs.speakerProfile, terms: inputs.speakerTerms)
        let rules = (inputs.replacementDictionary ?? ReplacementDictionary(entries: []))
            .adding(speakerTerms: inputs.speakerTerms)
        let replaced = rules.entries.isEmpty ? transcript : rules.apply(to: transcript)
        let prepared = prepare(
            transcript: replaced, vocabulary: vocabulary, rendersDictionary: templates.supportsReplacementDictionary
        )
        return QuickCapturePolishRequest(
            inputText: prepared.workingText,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: prepared.workingText, replacementDictionary: prepared.dictionarySection
            )
        )
    }
}
