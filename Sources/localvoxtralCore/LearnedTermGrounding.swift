import Foundation

/// What a project's learned terms ground in one transcript: the `.learned`
/// source's candidate for the cross-source merge.
///
/// Confirmed terms run through the matcher like any source, then #522's guard
/// (`withholdingOrdinaryReadings`). An agent's unconfirmed proposals (#609)
/// join the same run, so ambiguity between the two is resolved the same way,
/// but only in the exact tier: a proposal pre-applies a span that normalizes
/// to it and is never nominated as a sound-alike, nor offered as a
/// verification pair when the guard holds it back on prose. Use is what
/// confirms a proposal, and only an applied one is use. The caller passes
/// proposals only where repo vocabulary may go (`PolishContextGatherer`).
package enum LearnedTermGrounding {
    package static func outcome(
        transcript: String,
        confirmed: [String],
        proposals: [String]
    ) -> RepoVocabularyMatcher.GroundingOutcome {
        let confirmedKeys = Set(confirmed.map(\.caseFoldedForMatching))
        let proposalOnly = proposals.filter { !confirmedKeys.contains($0.caseFoldedForMatching) }
        let terms = confirmed + proposalOnly
        guard !terms.isEmpty else { return .empty }
        let outcome = RepoVocabularyMatcher.withholdingOrdinaryReadings(
            RepoVocabularyMatcher.groundedCandidates(
                transcript: transcript,
                vocabulary: RepoVocabulary(terms: terms, branch: nil)
            ),
            transcript: transcript
        )
        guard !proposalOnly.isEmpty else { return outcome }
        let proposalTerms = Set(proposalOnly)
        return RepoVocabularyMatcher.GroundingOutcome(
            entries: outcome.entries,
            isFallbackOnly: outcome.isFallbackOnly,
            phoneticEntries: outcome.phoneticEntries.filter { !proposalTerms.contains($0.replaceWith) },
            verificationCandidates: outcome.verificationCandidates.filter {
                !proposalTerms.contains($0.replaceWith)
            }
        )
    }
}
