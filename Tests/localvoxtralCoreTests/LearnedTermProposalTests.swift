import Foundation
import XCTest

@testable import localvoxtralCore

/// An agent's proposals in the learned-term store (#609): unconfirmed until
/// use or a pin, first to go under the caps, carried unconfirmed by import,
/// and a per-project stamp that keeps a project from being asked twice.
final class LearnedTermProposalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let project = LearnedTermProjectIdentity(key: "/Users/me/work/quillmark", name: "quillmark")
    private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    private func proposed(_ terms: [String], excluding: [String] = []) -> LearnedTerms {
        var memory = LearnedTerms()
        memory.recordProposal(terms, agent: .claude, project: project, excluding: excluding, now: now)
        return memory
    }

    private func term(_ spelling: String, in memory: LearnedTerms) -> LearnedTerm? {
        memory.projects.first { $0.key == project.key }?.terms.first { $0.term == spelling }
    }

    func testAProposalIsStoredUnconfirmedWithItsAgentAndNoDictations() throws {
        let memory = proposed(["inkwell"])
        let inkwell = try XCTUnwrap(term("inkwell", in: memory))
        XCTAssertEqual(inkwell.sources, ["agent:claude"])
        XCTAssertEqual(inkwell.dictations, 0)
        XCTAssertEqual(inkwell.proposingAgent, .claude)
        XCTAssertTrue(inkwell.isUnconfirmedProposal)
        XCTAssertEqual(memory.confirmedTerms(projectKey: project.key), [])
        XCTAssertEqual(memory.confirmedEverywhere(), [])
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: project.key), ["inkwell"])

        var vibe = LearnedTerms()
        vibe.recordProposal(["qmk"], agent: .vibe, project: project, now: now)
        XCTAssertEqual(vibe.projects.first?.terms.first?.sources, ["agent:vibe"])
    }

    /// Each dictation that resolves it counts, from memory, as `.learned`.
    func testThreeDictationsConfirmAProposal() throws {
        var memory = proposed(["inkwell"])
        for day in 1...3 {
            XCTAssertFalse(memory.confirmedTerms(projectKey: project.key).contains("inkwell"))
            memory.record(
                [LearnedTermObservation(term: "inkwell", source: .learned)],
                project: project,
                now: days(Double(day))
            )
        }
        let inkwell = try XCTUnwrap(term("inkwell", in: memory))
        XCTAssertEqual(inkwell.dictations, 3)
        XCTAssertEqual(inkwell.appliedCount, 3)
        XCTAssertEqual(inkwell.sources, ["agent:claude"])
        XCTAssertEqual(memory.confirmedTerms(projectKey: project.key), ["inkwell"])
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: project.key), [])
    }

    func testAPinConfirmsAProposal() {
        var memory = proposed(["inkwell"])
        memory.setPinned(true, term: "inkwell", projectKey: project.key)
        XCTAssertEqual(memory.confirmedTerms(projectKey: project.key), ["inkwell"])
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: project.key), [])
    }

    func testTermsAlreadyKnownOrExcludedAreNotProposed() {
        var memory = LearnedTerms()
        memory.record([LearnedTermObservation(term: "PageComposer", source: .repository)], project: project, now: now)
        memory.recordProposal(
            ["pagecomposer", "inkwell", "Qwen", "qmk"],
            agent: .claude,
            project: project,
            excluding: ["qwen"],
            now: now
        )
        let terms = memory.projects.first?.terms.map(\.term)
        XCTAssertEqual(terms, ["PageComposer", "inkwell", "qmk"])
        XCTAssertEqual(term("PageComposer", in: memory)?.sources, ["repository"])
    }

    func testTheCapEvictsUnearnedProposalsFirst() {
        var memory = LearnedTerms()
        let learned = (0..<(LearnedTerms.maxTermsPerProject - 1)).map { "Learned\($0)" }
        memory.record(
            learned.map { LearnedTermObservation(term: $0, source: .repository) },
            project: project,
            now: days(-1)
        )
        memory.recordProposal(["inkwell", "qmk", "PageComposer"], agent: .claude, project: project, now: now)
        let kept = memory.projects.first?.terms ?? []
        XCTAssertEqual(kept.count, LearnedTerms.maxTermsPerProject)
        XCTAssertEqual(kept.filter(\.isUnconfirmedProposal).count, 1)
        XCTAssertTrue(learned.allSatisfy { spelling in kept.contains { $0.term == spelling } })
    }

    func testAProposalNoDictationUsedDecaysAtNinetyDays() {
        var memory = proposed(["inkwell"])
        memory.prune(now: days(Double(LearnedTerms.staleAfterDays) - 1))
        XCTAssertNotNil(term("inkwell", in: memory))
        memory.prune(now: days(Double(LearnedTerms.staleAfterDays) + 1))
        XCTAssertNil(term("inkwell", in: memory))
        // The stamp outlives it: the project is not asked again.
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(100)))
    }

    func testImportKeepsAProposalUnconfirmedAndCarriesTheStamp() throws {
        let exported = try LearnedTermsExport.data(for: proposed(["inkwell"]), exportedAt: now)
        var target = LearnedTerms()
        target.merge(importing: try LearnedTermsExport.projects(from: exported), now: now)
        let inkwell = try XCTUnwrap(term("inkwell", in: target))
        XCTAssertTrue(inkwell.isUnconfirmedProposal)
        XCTAssertEqual(inkwell.dictations, 0)
        XCTAssertEqual(target.confirmedTerms(projectKey: project.key), [])
        XCTAssertFalse(target.needsProposal(projectKey: project.key, now: now))
    }

    // MARK: The stamp

    func testAnEmptyAnswerStampsTheProjectAndSurvivesPruneAndForget() {
        var memory = proposed([])
        XCTAssertEqual(memory.projects.count, 1)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(365)))

        memory.recordProposal(["inkwell"], agent: .claude, project: project, now: now)
        memory.forget("inkwell", projectKey: project.key)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: now))
    }

    func testAProjectWithLearnedTermsIsAskedOnceToo() {
        var memory = LearnedTerms()
        memory.record([LearnedTermObservation(term: "PageComposer", source: .repository)], project: project, now: now)
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: now))
        memory.recordProposal(["inkwell"], agent: .vibe, project: project, now: now)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: now))
    }

    func testAFailedAttemptIsRetriedAfterADay() {
        var memory = LearnedTerms()
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: now))
        memory.recordProposalFailure(project: project, now: now)
        XCTAssertEqual(memory.projects.count, 1)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: now.addingTimeInterval(24 * 3600)))

        memory.recordProposal(["inkwell"], agent: .claude, project: project, now: days(2))
        XCTAssertNil(memory.projects.first?.proposalAttemptedAt)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(10)))
    }

    /// A worktree asked before #652's fold reached it is not asked again
    /// once folded into its main checkout.
    func testFoldingAWorktreeCarriesItsStamp() {
        var memory = LearnedTerms()
        let worktree = LearnedTermProjectIdentity(key: project.key + "/.claude/worktrees/a", name: "a")
        memory.recordProposal(["inkwell"], agent: .claude, project: worktree, now: now)
        memory.fold(into: { $0.key == worktree.key ? self.project : nil }, now: now)
        XCTAssertEqual(memory.projects.map(\.key), [project.key])
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: now))
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: project.key), ["inkwell"])
    }

    /// A file written before #609 has neither field and decodes as never
    /// asked.
    func testAnOlderFileDecodesAsNeverAsked() throws {
        let json = #"{"version":1,"projects":[{"key":"/Users/me/work/quillmark","name":"quillmark","lastSeen":"2026-09-20T00:00:00Z","terms":[]}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let memory = try decoder.decode(LearnedTerms.self, from: Data(json.utf8))
        XCTAssertNil(memory.projects.first?.proposedAt)
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: now))
    }
}
