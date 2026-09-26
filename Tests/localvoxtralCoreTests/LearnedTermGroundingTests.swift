import Foundation
import XCTest

@testable import localvoxtralCore

/// How an unconfirmed agent proposal takes part in matching (#609): the
/// learned source's exact tier only, behind #522's guard, never as a
/// sound-alike nomination.
final class LearnedTermGroundingTests: XCTestCase {
    private func outcome(
        _ transcript: String,
        confirmed: [String] = [],
        proposals: [String] = []
    ) -> RepoVocabularyMatcher.GroundingOutcome {
        LearnedTermGrounding.outcome(transcript: transcript, confirmed: confirmed, proposals: proposals)
    }

    func testAProposalSpokenNextToACodeWordIsPreApplied() {
        let result = outcome("rename the page composer struct", proposals: ["PageComposer"])
        XCTAssertEqual(result.entries, [ReplacementEntry(replaceWith: "PageComposer", matches: ["page composer"])])
    }

    /// #522's guard holds a proposal back on prose, and unlike a confirmed
    /// term it is not offered to the model as a question either.
    func testTheOrdinaryReadingGuardHoldsAProposalBackEntirely() {
        let prose = "the page composer looks nice today"
        let proposal = outcome(prose, proposals: ["PageComposer"])
        XCTAssertEqual(proposal.entries, [])
        XCTAssertEqual(proposal.verificationCandidates, [])

        let confirmed = outcome(prose, confirmed: ["PageComposer"])
        XCTAssertEqual(confirmed.entries, [])
        XCTAssertEqual(confirmed.verificationCandidates.map(\.replaceWith), ["PageComposer"])
    }

    func testAProposalIsNeverASoundAlikeNomination() {
        let transcript = "open the glyph atlas cash file"
        let confirmed = outcome(transcript, confirmed: ["GlyphAtlasCache"])
        XCTAssertFalse(confirmed.verificationCandidates.isEmpty, "the fixture must nominate a confirmed term")
        let proposal = outcome(transcript, proposals: ["GlyphAtlasCache"])
        XCTAssertEqual(proposal.entries, [])
        XCTAssertEqual(proposal.verificationCandidates, [])
        XCTAssertEqual(proposal.phoneticEntries, [])
    }

    /// With no proposals, the learned source is exactly what it was before
    /// #609, which is what keeps every polish request unchanged.
    func testWithoutProposalsTheOutcomeIsTheConfirmedTermsAlone() {
        let transcript = "call use auth and open the glyph atlas cash file"
        let terms = ["useAuth", "GlyphAtlasCache"]
        XCTAssertEqual(
            outcome(transcript, confirmed: terms),
            RepoVocabularyMatcher.withholdingOrdinaryReadings(
                RepoVocabularyMatcher.groundedCandidates(
                    transcript: transcript,
                    vocabulary: RepoVocabulary(terms: terms, branch: nil)
                ),
                transcript: transcript
            )
        )
    }

    func testAConfirmedTermKeepsItsNominationBesideAProposal() {
        let result = outcome(
            "rename the page composer struct and open the glyph atlas cash file",
            confirmed: ["GlyphAtlasCache"],
            proposals: ["PageComposer"]
        )
        XCTAssertEqual(result.entries.map(\.replaceWith), ["PageComposer"])
        XCTAssertEqual(result.verificationCandidates.map(\.replaceWith), ["GlyphAtlasCache"])
    }

    /// A pre-applied proposal is a `.learned` entry of the merge, and the
    /// commit path records every merged entry: that is the dictation that
    /// counts toward the bar.
    func testAResolvedProposalRecordsADictation() {
        let project = LearnedTermProjectIdentity(key: "/r", name: "r")
        var memory = LearnedTerms()
        memory.recordProposal(["PageComposer"], agent: .claude, project: project, now: Date(timeIntervalSince1970: 0))
        let entries = outcome(
            "rename the page composer struct",
            confirmed: memory.confirmedTerms(projectKey: project.key),
            proposals: memory.unconfirmedProposals(projectKey: project.key)
        ).entries
        memory.record(
            entries.map { LearnedTermObservation(term: $0.replaceWith, source: .learned) },
            project: project,
            now: Date(timeIntervalSince1970: 60)
        )
        XCTAssertEqual(memory.projects.first?.terms.first?.dictations, 1)
        XCTAssertEqual(memory.projects.first?.terms.first?.appliedCount, 1)
    }
}
