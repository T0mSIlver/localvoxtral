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
        for project in projects {
            add(project.name)
            if let repository = project.repository, let name = repository.split(separator: "/").last {
                add(String(name))
            }
        }
        for project in projects {
            var added = 0
            for key in project.keys {
                for term in learned.confirmedTerms(projectKey: key) where added < maxTermsPerProject {
                    if add(term) { added += 1 }
                }
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
