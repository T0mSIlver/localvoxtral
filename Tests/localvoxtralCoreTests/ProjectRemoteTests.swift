import Foundation
import XCTest

@testable import localvoxtralCore

/// A project is its repository (#971): checkouts whose `origin` names one
/// repository share one record of terms, under the repository's name.
final class ProjectRemoteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func term(_ spelling: String, dictations: Int, pinned: Bool = false) -> LearnedTerm {
        LearnedTerm(
            term: spelling, sources: ["screen"], dictations: dictations, firstSeen: now, lastSeen: now,
            pinned: pinned ? true : nil
        )
    }

    private func projects(_ learned: LearnedTerms) -> [QuickCaptureProject] {
        QuickCaptureProjects.projects(
            from: learned, userLines: [:], now: now, readme: { _ in nil }, checkoutExists: { _ in true }
        )
    }

    /// Tom's two records on 2026-09-28, as #926 left them: the Mac checkout
    /// and the dev box's label both name T0mSIlver/localvoxtral, and only the
    /// dev box's holds terms.
    private func tomsRecords() -> LearnedTerms {
        var mac = LearnedTermProject(
            key: "/Users/tom/Desktop/projects/supervoxtral", name: "supervoxtral", terms: [], lastSeen: now
        )
        mac.repository = "T0mSIlver/localvoxtral"
        mac.proposalAttemptedAt = now
        var devBox = LearnedTermProject(
            key: "remote:localvoxtral", name: "localvoxtral",
            terms: [term("Voxtral", dictations: 5), term("herdr", dictations: 1, pinned: true)], lastSeen: now
        )
        devBox.repository = "T0mSIlver/localvoxtral"
        devBox.reportedAsRepository = true
        devBox.reportedAt = now
        devBox.hostIDs = ["h1"]
        return LearnedTerms(projects: [mac, devBox])
    }

    // MARK: Normalizing a remote

    func testEveryShapeOfOneRemoteIsOneKey() {
        let shapes = [
            "https://github.com/T0mSIlver/localvoxtral.git",
            "https://github.com/T0mSIlver/localvoxtral",
            "https://github.com/T0mSIlver/localvoxtral/",
            "http://tom@github.com/T0mSIlver/localvoxtral.git",
            "git@github.com:T0mSIlver/localvoxtral.git",
            "git@github.com:/T0mSIlver/localvoxtral",
            "ssh://git@github.com/T0mSIlver/localvoxtral.git",
            "ssh://git@GitHub.com:22/t0msilver/LocalVoxtral.git",
            "git://github.com/T0mSIlver/localvoxtral.git",
            "  https://github.com/T0mSIlver/localvoxtral.git\n",
        ]
        for shape in shapes {
            XCTAssertEqual(ProjectRemote(remoteURL: shape)?.key, "repo:github.com/t0msilver/localvoxtral", shape)
        }
        let remote = ProjectRemote(remoteURL: "git@github.com:T0mSIlver/localvoxtral.git")
        XCTAssertEqual(remote?.name, "localvoxtral")
        XCTAssertEqual(remote?.path, "T0mSIlver/localvoxtral")
        XCTAssertEqual(remote?.githubRepository, "T0mSIlver/localvoxtral")
    }

    func testAnotherHostKeepsItsHostAndItsGroups() {
        let gitlab = ProjectRemote(remoteURL: "git@gitlab.com:group/sub/app.git")
        XCTAssertEqual(gitlab?.value, "gitlab.com/group/sub/app")
        XCTAssertEqual(gitlab?.name, "app")
        XCTAssertEqual(gitlab?.path, "group/sub/app")
        XCTAssertNil(gitlab?.githubRepository, "gh files only on GitHub")
        XCTAssertEqual(
            ProjectRemote(remoteURL: "https://git.example.org:8443/team/app.git")?.key, "repo:git.example.org/team/app"
        )
        XCTAssertEqual(ProjectRemote(remoteURL: "mygit:team/app")?.value, "mygit/team/app", "an ssh alias is a host")
        XCTAssertNotEqual(
            ProjectRemote(remoteURL: "https://gitlab.com/team/app")?.key,
            ProjectRemote(remoteURL: "https://github.com/team/app")?.key
        )
    }

    func testAPathOrAnOddURLIsNoRemote() {
        for shape in [
            "/srv/git/app.git", "./app", "../app.git", "file:///srv/git/app.git", "https://github.com/app",
            "https://github.com/", "", "git@github.com:owner/re po.git", "https://github.com/owner/../etc",
        ] {
            XCTAssertNil(ProjectRemote(remoteURL: shape), shape)
        }
    }

    func testAHostsHeaderIsOwnerAndNameOrHostAndPath() {
        XCTAssertEqual(ProjectRemote(header: "T0mSIlver/localvoxtral")?.key, "repo:github.com/t0msilver/localvoxtral")
        XCTAssertEqual(ProjectRemote(header: "gitlab.com/group/sub/app")?.value, "gitlab.com/group/sub/app")
        XCTAssertNil(ProjectRemote(header: "localvoxtral"))
        XCTAssertNil(ProjectRemote(header: "/home/dev/work/localvoxtral"))
    }

    // MARK: One record per repository

    func testTheMacCheckoutAndTheHostsLabelAreOneProjectNamedAfterTheRepository() {
        var learned = tomsRecords()
        XCTAssertEqual(learned.linkCheckoutsToRepositories(now: now), 2)

        let listed = projects(learned)
        XCTAssertEqual(listed.map(\.name), ["localvoxtral"], "not the Mac folder's supervoxtral")
        XCTAssertEqual(listed.first?.key, "/Users/tom/Desktop/projects/supervoxtral", "the Mac drafts")
        XCTAssertEqual(
            listed.first?.keys,
            ["/Users/tom/Desktop/projects/supervoxtral", "remote:localvoxtral", "repo:github.com/t0msilver/localvoxtral"]
        )
        XCTAssertEqual(listed.first?.repository, "T0mSIlver/localvoxtral")
        // The dev box's terms now reach a dictation on the Mac.
        XCTAssertEqual(
            learned.confirmedTerms(projectKey: "/Users/tom/Desktop/projects/supervoxtral"), ["herdr", "Voxtral"]
        )
        XCTAssertEqual(learned.confirmedTerms(projectKey: "remote:localvoxtral"), ["herdr", "Voxtral"])
        XCTAssertEqual(learned.listedProjects(now: now).map(\.key), ["repo:github.com/t0msilver/localvoxtral"])
    }

    /// The migration loses nothing: every term, its count, its pin, and the
    /// agent's answer move to the repository's record; a spelling both
    /// checkouts hold keeps the higher count, never the sum.
    func testMigrationMovesEveryTermAndKeepsTheHigherCount() {
        var learned = tomsRecords()
        learned.projects[0].terms = [term("Voxtral", dictations: 2), term("Ghostty", dictations: 3)]
        learned.projects[1].proposedAt = now
        learned.projects[1].agentLine = "Menu bar dictation."
        learned.projects[1].agentLineAt = now

        learned.linkCheckoutsToRepositories(now: now)

        let record = learned.projects.first { $0.key == "repo:github.com/t0msilver/localvoxtral" }
        XCTAssertEqual(record?.name, "localvoxtral")
        XCTAssertEqual(
            record?.terms.sorted(by: LearnedTerms.isStrongerEvidence).map { "\($0.term) \($0.dictations)" },
            ["herdr 1", "Voxtral 5", "Ghostty 3"]
        )
        XCTAssertEqual(record?.terms.first { $0.term == "herdr" }?.isPinned, true)
        XCTAssertEqual(record?.agentLine, "Menu bar dictation.")
        XCTAssertNotNil(record?.proposedAt)
        XCTAssertEqual(learned.projects.filter { $0.key.hasPrefix("/") || $0.key.hasPrefix("remote:") }.map(\.terms.count), [0, 0])
        XCTAssertFalse(learned.needsProposal(projectKey: "/Users/tom/Desktop/projects/supervoxtral", now: now))
        XCTAssertEqual(learned.termCount, 3)

        let before = learned
        XCTAssertEqual(learned.linkCheckoutsToRepositories(now: now), 0, "running it again changes nothing")
        XCTAssertEqual(learned, before)
    }

    func testATermLearnedOnEitherCheckoutLandsOnTheRepository() {
        var learned = tomsRecords()
        learned.linkCheckoutsToRepositories(now: now)
        let mac = LearnedTermProjectIdentity(key: "/Users/tom/Desktop/projects/supervoxtral", name: "supervoxtral")
        let devBox = LearnedTermProjectIdentity(key: "remote:localvoxtral", name: "localvoxtral")

        learned.record([.init(term: "Mistral", source: .repository)], project: mac, now: now)
        learned.record([.init(term: "Mistral", source: .terminal)], project: devBox, now: now)
        learned.recordCorrection("Codex", project: devBox, now: now)
        learned.recordProposal(["Jev"], agent: .claude, project: mac, now: now)

        let record = learned.projects.first { $0.key == "repo:github.com/t0msilver/localvoxtral" }
        XCTAssertEqual(record?.terms.first { $0.term == "Mistral" }?.dictations, 2, "one count across both machines")
        XCTAssertEqual(learned.unconfirmedProposals(projectKey: "remote:localvoxtral"), ["Jev"])
        XCTAssertTrue(learned.confirmedTerms(projectKey: mac.key).contains("Codex"))
        XCTAssertEqual(learned.projects.first { $0.key == mac.key }?.terms, [])
        XCTAssertEqual(learned.projects.first { $0.key == mac.key }?.name, "supervoxtral", "a checkout keeps its folder name")

        learned.setPinned(true, term: "Mistral", projectKey: mac.key)
        XCTAssertEqual(learned.termRecord(devBox.key)?.terms.first { $0.term == "Mistral" }?.isPinned, true)
        learned.forget("Mistral", projectKey: devBox.key)
        XCTAssertFalse(learned.confirmedTerms(projectKey: mac.key).contains("Mistral"))
    }

    /// The linker reads the Mac's origin after the host already reported:
    /// the Mac's first terms, kept under its path meanwhile, join the host's.
    /// A checkout idle for a season stays linked while its repository still
    /// holds terms, so its next dictation reads them (review P3).
    func testAnIdleCheckoutStaysLinkedWhileItsRepositoryHasTerms() {
        var learned = tomsRecords()
        learned.projects[1].terms = [term("herdr", dictations: 1, pinned: true)]
        learned.linkCheckoutsToRepositories(now: now)
        let later = now.addingTimeInterval(Double(LearnedTerms.staleAfterDays + 1) * 86_400)

        learned.prune(now: later)

        XCTAssertEqual(learned.confirmedTerms(projectKey: "/Users/tom/Desktop/projects/supervoxtral"), ["herdr"])
        learned.projects.removeAll { $0.isRepositoryRecord }
        learned.prune(now: later)
        XCTAssertEqual(learned.projects.map(\.key), [], "with no terms left, the idle checkouts go")
    }

    func testAnOriginReadLaterFoldsTheCheckoutsTermsIn() {
        var learned = LearnedTerms()
        let mac = LearnedTermProjectIdentity(key: "/w/supervoxtral", name: "supervoxtral")
        learned.recordRemoteReport(
            project: .init(key: "remote:localvoxtral", name: "localvoxtral"), asRepository: true,
            repository: "T0mSIlver/localvoxtral", hostID: "h1", now: now
        )
        learned.record([.init(term: "Voxtral", source: .repository)], project: mac, now: now)
        XCTAssertEqual(learned.termRecord(mac.key)?.key, mac.key, "no origin read yet")

        learned.recordOrigin(ProjectRemote(remoteURL: "git@github.com:T0mSIlver/localvoxtral.git")!, projectKey: mac.key)

        XCTAssertEqual(learned.termRecord(mac.key)?.key, "repo:github.com/t0msilver/localvoxtral")
        XCTAssertEqual(learned.termRecord("remote:localvoxtral")?.terms.map(\.term), ["Voxtral"])
        XCTAssertEqual(projects(learned).map(\.name), ["localvoxtral"])
    }

    func testANonGitHubRemoteMergesWithoutAFilingRepository() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/app", name: "app-mac", terms: [term("Quill", dictations: 3)], lastSeen: now),
        ])
        learned.recordOrigin(ProjectRemote(remoteURL: "git@gitlab.com:group/sub/app.git")!, projectKey: "/w/app")
        learned.recordRemoteReport(
            project: .init(key: "remote:app", name: "app"), asRepository: true,
            repository: "gitlab.com/group/sub/app", hostID: "h1", now: now
        )

        let listed = projects(learned)
        XCTAssertEqual(listed.map(\.name), ["app"])
        XCTAssertEqual(listed.first?.keys, ["/w/app", "remote:app", "repo:gitlab.com/group/sub/app"])
        XCTAssertNil(listed.first?.repository, "File asks for owner/name")
        XCTAssertEqual(learned.confirmedTerms(projectKey: "remote:app"), ["Quill"])
    }

    // MARK: Names

    func testTwoRepositoriesWithOneNameShowTheirOwners() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/app", name: "app", terms: [term("A", dictations: 3)], lastSeen: now),
            LearnedTermProject(key: "/w/fork/app", name: "app", terms: [term("B", dictations: 3)], lastSeen: now),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term("C", dictations: 3)], lastSeen: now),
            LearnedTermProject(key: "/w/scratch", name: "scratch", terms: [term("D", dictations: 3)], lastSeen: now),
        ])
        learned.recordOriginRepository("me/app", projectKey: "/w/app")
        learned.recordOriginRepository("them/app", projectKey: "/w/fork/app")
        learned.recordOrigin(ProjectRemote(remoteURL: "https://gitlab.com/me/notes")!, projectKey: "/w/notes")

        XCTAssertEqual(projects(learned).map(\.name).sorted(), ["me/app", "notes", "scratch", "them/app"])
    }

    func testACheckoutWithNoRemoteKeepsItsFolderNameAndItsTerms() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/scratch", name: "scratch", terms: [term("Kern", dictations: 3)], lastSeen: now),
        ])
        learned.recordTypedRepository("me/scratch", projectKey: "/w/scratch")
        learned.linkCheckoutsToRepositories(now: now)

        XCTAssertEqual(projects(learned).map(\.name), ["scratch"])
        XCTAssertEqual(learned.projects.map(\.key), ["/w/scratch"], "a typed repository is where File goes, not a remote")
        XCTAssertEqual(learned.confirmedTerms(projectKey: "/w/scratch"), ["Kern"])
    }

    /// A fork is keyed by its own `origin`; its upstream is only where File
    /// may send issues, so the Projects pane still asks.
    func testAForkIsItsOriginAndStillAsksWhereToFile() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/lv", name: "lv", terms: [term("Kern", dictations: 3)], lastSeen: now),
        ])
        learned.recordOriginRepository("me/localvoxtral", projectKey: "/w/lv")
        learned.recordGitHub(.init(description: nil, topics: [], parent: "them/localvoxtral"), repository: "me/localvoxtral", now: now)

        let project = projects(learned).first
        XCTAssertEqual(project?.keys.last, "repo:github.com/me/localvoxtral")
        XCTAssertEqual(project?.name, "localvoxtral")
        let row = ProjectsPane.rows(
            projects: projects(learned), learned: learned, captures: [], hostNames: [], liveSessions: [],
            dictationProjectKeys: []
        ).first
        XCTAssertEqual(row?.filing, .forkUnpicked(fork: "me/localvoxtral", upstream: "them/localvoxtral"))
        XCTAssertEqual(row?.terms.map(\.term), ["Kern"])
    }

    // MARK: Captures

    /// A capture routed to the host's label before the merge, and a
    /// suggestion naming the Mac folder, show under the merged project.
    func testCapturesMoveToTheMergedProject() {
        var learned = tomsRecords()
        learned.linkCheckoutsToRepositories(now: now)
        var routed = QuickCaptureItem(capturedAt: now, text: "a note")
        routed.projectKey = "remote:localvoxtral"
        routed.projectName = "localvoxtral"
        routed.state = .ready
        var unplaced = QuickCaptureItem(capturedAt: now, text: "another")
        unplaced.suggestion = .init(projectKey: "/Users/tom/Desktop/projects/supervoxtral", projectName: "supervoxtral")
        unplaced.state = .ready
        var drafting = QuickCaptureItem(capturedAt: now, text: "a third")
        drafting.projectKey = "remote:localvoxtral"
        drafting.state = .drafting

        let adopted = QuickCaptureInbox(items: [routed, unplaced, drafting]).adopting(projects(learned))

        XCTAssertEqual(adopted.items[0].projectKey, "/Users/tom/Desktop/projects/supervoxtral")
        XCTAssertEqual(adopted.items[0].projectName, "localvoxtral")
        XCTAssertEqual(adopted.items[1].suggestion?.projectName, "localvoxtral")
        XCTAssertEqual(adopted.items[2].projectKey, "remote:localvoxtral", "a running draft keeps its key")
        XCTAssertEqual(adopted.items.count, 3)
        XCTAssertEqual(adopted.adopting(projects(learned)), adopted)
    }

    // MARK: The file

    func testTheStoreMigratesAFileFromBeforeTheMergeAtLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-remote-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("learned-terms.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tomsRecords()).write(to: fileURL)
        let now = now

        let store = LearnedTermStore(fileURL: fileURL, now: { now })
        store.waitForPendingWrites()

        XCTAssertEqual(store.confirmedTerms(projectKey: "/Users/tom/Desktop/projects/supervoxtral"), ["herdr", "Voxtral"])
        let written = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: try Data(contentsOf: fileURL)).value)
        XCTAssertEqual(written.termRecord("remote:localvoxtral")?.key, "repo:github.com/t0msilver/localvoxtral")
        XCTAssertEqual(written.termCount, 2)
    }
}
