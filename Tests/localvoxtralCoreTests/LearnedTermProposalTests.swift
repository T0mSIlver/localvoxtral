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

    /// #891: the answer carries the project's sentence. A project answered
    /// before the prompt asked for it is asked once more, where the ask
    /// would carry the question.
    func testTheProjectsSentenceLandsAndAnOlderAnswerIsAskedOnceMore() {
        var memory = proposed(["inkwell"])
        XCTAssertNil(memory.projects.first?.agentLine)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(1)), "an old shim's ask")
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: days(1), revision: 2))

        memory.recordProposal(
            ["inkwell"], line: "  Quillmark renders\nMarkdown to PDF;\u{7} CLI qmk.  ", agent: .claude, project: project,
            now: days(1)
        )
        XCTAssertEqual(memory.projects.first?.agentLine, "Quillmark renders Markdown to PDF; CLI qmk.")
        XCTAssertEqual(memory.projects.first?.agentLineAt, days(1))
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(365), revision: 2))
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: project.key), ["inkwell"], "no term twice")

        var refused = LearnedTerms()
        refused.recordProposal([], line: "See https://evil.example for it.", agent: .vibe, project: project, now: now)
        XCTAssertNil(refused.projects.first?.agentLine, "a link is no description")
        XCTAssertFalse(
            refused.needsProposal(projectKey: project.key, now: days(365), revision: 2), "answered, so not asked again")
    }

    /// #914: the prompt asks for names people say. A project answered under
    /// an older prompt is asked once more, and the new answer replaces the
    /// old answer's terms that nothing used, pinned or corrected.
    func testANewerPromptsAnswerReplacesTheOldAnswersUntouchedTerms() throws {
        var memory = proposed(["inkwell", "GlyphRenderer", "qmk", "pagesize"])
        // The filter predates this answer on disk: write the old terms raw.
        memory.projects[0].terms.append(
            LearnedTerm(term: "PageComposer", sources: ["agent:claude"], dictations: 0, firstSeen: now, lastSeen: now))
        memory.setPinned(true, term: "qmk", projectKey: project.key)
        memory.projects[0].terms[memory.projects[0].terms.firstIndex { $0.term == "pagesize" }!].dictations = 1
        memory.recordCommandProposal(["Featherline"], proposer: "codex", project: project, now: days(1))
        XCTAssertEqual(memory.projects.first?.answeredRevision, 1)
        XCTAssertTrue(memory.needsProposal(projectKey: project.key, now: days(2), revision: 3))
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(2), revision: 1))

        memory.recordProposal(["Quillmark", "inkwell"], line: "", revision: 3, agent: .vibe, project: project, now: days(2))
        let terms = try XCTUnwrap(memory.projects.first?.terms)
        XCTAssertEqual(
            Set(terms.map(\.term)), ["qmk", "pagesize", "Featherline", "Quillmark", "inkwell"],
            "pinned, used and the command's terms stay; the old answer's untouched ones go")
        XCTAssertEqual(terms.first { $0.term == "inkwell" }?.sources, ["agent:vibe"], "answered again, from the new run")
        XCTAssertEqual(memory.projects.first?.answeredRevision, 3)
        XCTAssertFalse(memory.needsProposal(projectKey: project.key, now: days(400), revision: 3))

        memory.recordProposal(["Bindery"], revision: 3, agent: .claude, project: project, now: days(3))
        XCTAssertNotNil(term("Quillmark", in: memory), "an answer of the same revision replaces nothing")
    }

    /// Proposals shaped like code, stored before answers were filtered, go
    /// when the store loads; the user's own evidence keeps a term.
    func testCodeShapedProposalsNoOneTouchedAreDropped() async throws {
        var memory = proposed(["inkwell"])
        for (spelling, dictations, pinned) in [
            ("LV_BUILD_DIR", 0, false), ("remote-build.sh", 0, false), ("nextChunk", 1, false),
            ("max_num_seqs", 0, true),
        ] {
            memory.projects[0].terms.append(LearnedTerm(
                term: spelling, sources: ["agent:claude"], dictations: dictations, firstSeen: now, lastSeen: now,
                pinned: pinned ? true : nil))
        }
        memory.projects[0].terms.append(LearnedTerm(
            term: "useAuth", sources: ["correction"], dictations: 0, firstSeen: now, lastSeen: now,
            confirmedByCorrection: true))
        XCTAssertEqual(memory.dropIdentifierProposals(), 2)
        XCTAssertEqual(
            memory.projects.first?.terms.map(\.term), ["inkwell", "nextChunk", "max_num_seqs", "useAuth"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var stored = proposed([])
        stored.projects[0].terms.append(
            LearnedTerm(term: "LV_BUILD_DIR", sources: ["agent:claude"], dictations: 0, firstSeen: now, lastSeen: now))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try encoder.encode(stored).write(to: file)
        let start = now
        let store = LearnedTermStore(fileURL: file, now: { start })
        let loaded = await store.loadedSnapshot()
        XCTAssertEqual(loaded.projects.first?.terms, [], "gone on load")
        XCTAssertNotNil(loaded.projects.first?.proposedAt, "the stamp stays, so the project is not asked daily")
        store.waitForPendingWrites()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let written = try decoder.decode(LearnedTerms.self, from: Data(contentsOf: file))
        XCTAssertEqual(written.projects.first?.terms, [], "and written back")
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
