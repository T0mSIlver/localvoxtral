import Foundation
import XCTest
@testable import localvoxtralCore

/// Export and import of learned terms (#523): the file format and the merge
/// rule from the spec on the issue.
final class LearnedTermsExportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func term(
        _ spelling: String,
        dictations: Int = 1,
        sources: [String] = ["repo"],
        seen: Double = 1,
        correction: Bool = false,
        pinned: Bool = false,
        applied: Int? = nil
    ) -> LearnedTerm {
        LearnedTerm(
            term: spelling,
            sources: sources,
            dictations: dictations,
            firstSeen: daysAgo(seen + 10),
            lastSeen: daysAgo(seen),
            confirmedByCorrection: correction ? true : nil,
            applied: applied,
            lastApplied: applied.map { _ in daysAgo(seen) },
            pinned: pinned ? true : nil
        )
    }

    private func project(_ key: String, _ name: String, _ terms: [LearnedTerm]) -> LearnedTermProject {
        LearnedTermProject(key: key, name: name, terms: terms, lastSeen: daysAgo(1))
    }

    private func roundTrip(_ terms: LearnedTerms) throws -> [LearnedTermProject] {
        try LearnedTermsExport.projects(from: LearnedTermsExport.data(for: terms, exportedAt: now))
    }

    func testExportCarriesTermsStillBeingLearnedIntoAnEmptyMemory() throws {
        let source = LearnedTerms(projects: [
            project("/Users/tom/work/app", "app", [
                term("speechd", dictations: 4, applied: 2),
                term("Voxtral", dictations: 2),
                term("herdr", correction: true, pinned: true),
            ]),
            project("shared", "No project", [term("Qwen", dictations: 1)]),
        ])
        var target = LearnedTerms()
        let summary = target.merge(importing: try roundTrip(source), now: now)

        XCTAssertEqual(target.projects, source.projects)
        XCTAssertEqual(summary, .init(terms: 4, projects: 2))
    }

    func testFileIsVersionedAndTagged() throws {
        let data = try LearnedTermsExport.data(for: LearnedTerms(), exportedAt: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "localvoxtral.learned-terms")
        XCTAssertEqual(object["version"] as? Int, LearnedTerms.currentVersion)
    }

    func testImportingTheSameFileTwiceChangesNothing() throws {
        var local = LearnedTerms(projects: [
            project("/a", "a", [term("speechd", dictations: 2, sources: ["clipboard"])]),
        ])
        let file = try roundTrip(LearnedTerms(projects: [
            project("/a", "a", [term("Speechd", dictations: 3, correction: true, applied: 1)]),
            project("/b", "b", [term("Qwen")]),
        ]))
        local.merge(importing: file, now: now)
        let once = local
        local.merge(importing: file, now: now)
        XCTAssertEqual(local, once)

        // And back again: A→B→A is the same as A→B.
        local.merge(importing: try roundTrip(once), now: now)
        XCTAssertEqual(local, once)
    }

    func testMatchedTermTakesMaxCountsAndUnionsTheRest() throws {
        var local = LearnedTerms(projects: [
            project("/a", "a", [term("speechd", dictations: 5, sources: ["clipboard"], seen: 3, applied: 1)]),
        ])
        local.merge(importing: [
            project("/a", "a", [term("SPEECHD", dictations: 2, sources: ["repo"], seen: 1, pinned: true, applied: 4)]),
        ], now: now)

        let merged = try XCTUnwrap(local.projects.first?.terms.first)
        XCTAssertEqual(local.projects.first?.terms.count, 1)
        XCTAssertEqual(merged.term, "speechd", "local spelling stays without a hand fix on the import")
        XCTAssertEqual(merged.dictations, 5)
        XCTAssertEqual(merged.appliedCount, 4)
        XCTAssertEqual(merged.sources, ["clipboard", "repo"])
        XCTAssertEqual(merged.firstSeen, daysAgo(13))
        XCTAssertEqual(merged.lastSeen, daysAgo(1))
        XCTAssertEqual(merged.lastApplied, daysAgo(1))
        XCTAssertTrue(merged.isPinned)
    }

    func testHandCorrectedSpellingFromTheFileWins() throws {
        var local = LearnedTerms(projects: [project("/a", "a", [term("Speechd", dictations: 3)])])
        local.merge(importing: [project("/a", "a", [term("speechd", correction: true)])], now: now)
        let merged = try XCTUnwrap(local.projects.first?.terms.first)
        XCTAssertEqual(merged.term, "speechd")
        XCTAssertTrue(merged.isConfirmedByCorrection)
    }

    func testProjectMatchesByKeyThenByUniqueName() {
        var local = LearnedTerms(projects: [
            project("/Users/tom/work/app", "app", [term("one")]),
            project("/Users/tom/x/lib", "lib", [term("two")]),
            project("/Users/tom/y/lib", "lib", [term("three")]),
        ])
        local.merge(importing: [
            project("/Users/thomas/src/app", "app", [term("moved")]),
            project("/Users/thomas/src/lib", "lib", [term("ambiguous")]),
        ], now: now)

        XCTAssertEqual(
            local.projects.first { $0.key == "/Users/tom/work/app" }?.terms.map(\.term),
            ["one", "moved"]
        )
        XCTAssertEqual(
            local.projects.first { $0.key == "/Users/thomas/src/lib" }?.terms.map(\.term),
            ["ambiguous"],
            "two local projects share the name, so the file's project stays its own"
        )
        XCTAssertEqual(local.projects.count, 4)
    }

    func testImportNeverConfirmsATermStillBeingLearned() {
        var local = LearnedTerms()
        local.merge(importing: [
            project("/a", "a", [term("Voxtral", dictations: 2), term("speechd", dictations: 3)]),
        ], now: now)
        XCTAssertEqual(local.confirmedTerms(projectKey: "/a"), ["speechd"])
    }

    func testDecayAndCapsApplyAfterTheMergeAndTheSummaryCountsWhatStayed() {
        var local = LearnedTerms()
        let summary = local.merge(importing: [
            project("/a", "a", [
                term("fresh", seen: 1),
                term("stale", seen: Double(LearnedTerms.staleAfterDays) + 1),
                term("  "),
            ]),
        ], now: now)
        XCTAssertEqual(local.projects.first?.terms.map(\.term), ["fresh"])
        XCTAssertEqual(summary, .init(terms: 1, projects: 1))

        var full = LearnedTerms()
        full.merge(importing: [
            project("/a", "a", (0...LearnedTerms.maxTermsPerProject).map { term("t\($0)") }),
        ], now: now)
        XCTAssertEqual(full.termCount, LearnedTerms.maxTermsPerProject)
    }

    func testAcceptsTheAppsOwnFile() throws {
        let store = """
            {"projects":[{"key":"/a","lastSeen":"2026-09-20T10:00:00Z","name":"a",
            "terms":[{"dictations":3,"firstSeen":"2026-09-01T10:00:00Z",
            "lastSeen":"2026-09-20T10:00:00Z","sources":["repo"],"term":"speechd"}]}],
            "version":1}
            """
        let projects = try LearnedTermsExport.projects(from: Data(store.utf8))
        XCTAssertEqual(projects.first?.terms.first?.term, "speechd")
    }

    func testRefusesANewerVersionAnotherFormatAndGarbage() {
        func refusal(_ json: String) -> LearnedTermsExport.ImportError? {
            do {
                _ = try LearnedTermsExport.projects(from: Data(json.utf8))
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(
            refusal(#"{"format":"localvoxtral.learned-terms","version":2,"projects":[]}"#),
            .newerVersion
        )
        XCTAssertEqual(refusal(#"{"format":"something-else","version":1,"projects":[]}"#), .unreadable)
        XCTAssertEqual(refusal("not json"), .unreadable)
    }

    // MARK: Worktree buckets fold into the main checkout (#652)

    /// Two worktrees that each saw a spelling three times saw it three times,
    /// not six: the fold takes the import rule, max and never the sum.
    func testFoldTakesTheMaxOfCountsAndDropsTheOldKeys() throws {
        var terms = LearnedTerms(projects: [
            project("/w/repo", "repo", [term("speechd", dictations: 2)]),
            project("/w/repo/.claude/worktrees/a", "a", [
                term("speechd", dictations: 3, sources: ["claude"]),
                term("polishd", dictations: 1),
            ]),
            project("/tmp/repo-b", "repo-b", [term("speechd", dictations: 3, correction: true)]),
            project("remote:a", "a", [term("herdr", dictations: 3)]),
        ])
        let main = LearnedTermProjectIdentity(key: "/w/repo", name: "repo")
        let destination: (LearnedTermProject) -> LearnedTermProjectIdentity? = {
            ["/w/repo/.claude/worktrees/a", "/tmp/repo-b"].contains($0.key) ? main : nil
        }

        XCTAssertEqual(terms.fold(into: destination, now: now), 2)

        XCTAssertEqual(terms.projects.map(\.key).sorted(), ["/w/repo", "remote:a"])
        let repo = try XCTUnwrap(terms.projects.first { $0.key == "/w/repo" })
        let speechd = try XCTUnwrap(repo.terms.first { $0.term == "speechd" })
        XCTAssertEqual(speechd.dictations, 3)
        XCTAssertTrue(speechd.isConfirmedByCorrection)
        XCTAssertEqual(speechd.sources, ["repo", "claude"])
        XCTAssertEqual(repo.terms.map(\.term).sorted(), ["polishd", "speechd"])

        let once = terms
        XCTAssertEqual(terms.fold(into: destination, now: now), 0)
        XCTAssertEqual(terms, once)
    }

    /// A worktree whose main checkout had learned nothing yet becomes that
    /// project, under the main checkout's name.
    func testFoldCreatesTheMainCheckoutsProject() {
        var terms = LearnedTerms(projects: [
            project("/w/repo/.claude/worktrees/a", "a", [term("speechd", dictations: 3)]),
        ])
        terms.fold(into: { _ in LearnedTermProjectIdentity(key: "/w/repo", name: "repo") }, now: now)

        XCTAssertEqual(terms.projects.map(\.key), ["/w/repo"])
        XCTAssertEqual(terms.projects.first?.name, "repo")
        XCTAssertEqual(terms.confirmedTerms(projectKey: "/w/repo"), ["speechd"])
    }

    /// The filesystem half, on the layout `git worktree add` writes: the
    /// worktree's key folds, the main checkout's, a plain directory's and a
    /// remote label stay.
    func testFoldWorktreesReadsTheWorktreesGitFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-fold-\(UUID().uuidString)").standardizedFileURL
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("repo")
        let gitDir = main.appendingPathComponent(".git/worktrees/a")
        let worktree = base.appendingPathComponent("repo-a")
        let plain = base.appendingPathComponent("notes")
        for directory in [gitDir, worktree, plain] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        var terms = LearnedTerms(projects: [
            project(worktree.path, "repo-a", [term("speechd", dictations: 3)]),
            project(main.path, "repo", [term("speechd", dictations: 1)]),
            project(plain.path, "notes", [term("herdr", dictations: 3)]),
            project("remote:repo-a", "repo-a", [term("polishd", dictations: 3)]),
        ])

        XCTAssertEqual(terms.foldWorktreesIntoMainCheckouts(now: now), 1)
        XCTAssertEqual(
            terms.projects.map(\.key).sorted(), [main.path, plain.path, "remote:repo-a"].sorted()
        )
        XCTAssertEqual(terms.confirmedTerms(projectKey: main.path), ["speechd"])
        XCTAssertEqual(terms.foldWorktreesIntoMainCheckouts(now: now), 0)
    }
}
