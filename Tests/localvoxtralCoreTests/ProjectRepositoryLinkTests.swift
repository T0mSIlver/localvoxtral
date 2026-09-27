import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// A project's GitHub repository, GitHub's description of it and where its
/// issues are filed (#926).
final class ProjectRepositoryLinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func term(_ spelling: String) -> LearnedTerm {
        LearnedTerm(term: spelling, sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
    }

    private func remote(_ name: String) -> LearnedTermProjectIdentity {
        LearnedTermProjectIdentity(key: "remote:\(name)", name: name)
    }

    func testAHostsOriginIsKeptOnlyBesideItsRepositorysName() {
        var learned = LearnedTerms()
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", now: now)
        learned.recordRemoteReport(project: remote("ink"), asRepository: true, repository: "../..", now: now)
        XCTAssertEqual(learned.projects.first { $0.key == "remote:quill" }?.repository, "me/quill")
        XCTAssertNil(learned.projects.first { $0.key == "remote:ink" }?.repository, "no owner/name")

        // A cwd label is no repository's name: its origin is not kept.
        learned.record([LearnedTermObservation(term: "Kern", source: .terminal)], project: remote("quill-fix"), now: now)
        learned.recordRemoteReport(project: remote("quill-fix"), asRepository: false, repository: "me/other", now: now)
        XCTAssertNil(learned.projects.first { $0.key == "remote:quill-fix" }?.repository)

        // A later report without the header (an older shim) keeps it.
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: nil, now: now)
        XCTAssertEqual(learned.projects.first { $0.key == "remote:quill" }?.repository, "me/quill")
    }

    func testATypedRepositoryIsKeptUntilAnOriginNamesOne() {
        var learned = LearnedTerms(projects: [LearnedTermProject(key: "/w/notes", name: "notes", terms: [term("Obsidian")], lastSeen: now)])
        XCTAssertTrue(learned.recordTypedRepository("me/notes", projectKey: "/w/notes"))
        XCTAssertEqual(learned.projects[0].repository, "me/notes")
        XCTAssertEqual(learned.projects[0].repositoryTyped, true)

        learned.recordOriginRepository("me/notes-v2", projectKey: "/w/notes")
        XCTAssertEqual(learned.projects[0].repository, "me/notes-v2")
        XCTAssertNil(learned.projects[0].repositoryTyped)
        XCTAssertFalse(learned.recordTypedRepository("me/other", projectKey: "/w/notes"), "an origin wins over a typed answer")
        XCTAssertEqual(learned.projects[0].repository, "me/notes-v2")
    }

    func testAForkFilesInItselfUntilTheUserPicksItsUpstream() {
        var learned = LearnedTerms(projects: [LearnedTermProject(key: "/w/tool", name: "tool", terms: [term("Kern")], lastSeen: now)])
        learned.recordOriginRepository("me/tool", projectKey: "/w/tool")
        learned.recordGitHub(.init(description: "A tool.", topics: [], parent: "upstream/tool"), repository: "me/tool", now: now)
        XCTAssertEqual(learned.projects[0].issueRepository, "me/tool")

        learned.setFilesUpstream(true, repository: "me/tool")
        XCTAssertEqual(learned.projects[0].issueRepository, "upstream/tool")

        // Another origin is another repository: the choice and GitHub's
        // answer were about the old one.
        learned.recordOriginRepository("me/tool2", projectKey: "/w/tool")
        XCTAssertEqual(learned.projects[0].issueRepository, "me/tool2")
        XCTAssertNil(learned.projects[0].github)
    }

    /// The same repository on the Mac and on a host is one option, drafted
    /// on the Mac, with both projects' terms; the learned terms keep both.
    func testTwoCheckoutsOfOneRepositoryAreOneOption() {
        var local = LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now)
        local.repository = "me/quill"
        var host = LearnedTermProject(key: "remote:quill", name: "quill", terms: [term("Glyph"), term("kern")], lastSeen: now.addingTimeInterval(60))
        host.repository = "me/quill"
        host.reportedAsRepository = true
        host.summary = "Quill typesets Markdown."
        var other = LearnedTermProject(key: "remote:ink", name: "ink", terms: [term("Ink")], lastSeen: now)
        other.reportedAsRepository = true
        let learned = LearnedTerms(projects: [local, host, other])

        let projects = QuickCaptureProjects.projects(
            from: learned, userLines: ["remote:quill": "Markdown to PDF."], now: now, readme: { _ in nil },
            checkoutExists: { $0 == "/w/quill" })

        XCTAssertEqual(projects.map(\.key), ["/w/quill", "remote:ink"])
        XCTAssertEqual(projects[0].keys, ["/w/quill", "remote:quill"])
        XCTAssertEqual(projects[0].terms, ["Kern", "Glyph"], "one spelling once")
        XCTAssertEqual(projects[0].summary, "Quill typesets Markdown.", "the host's README when the Mac's has none")
        XCTAssertEqual(projects[0].userLine, "Markdown to PDF.", "the line the user wrote on either")
        XCTAssertEqual(learned.listedProjects(now: now).count, 3)

        // The Mac's checkout is gone: the host's leads, so it still drafts.
        let moved = QuickCaptureProjects.projects(
            from: learned, userLines: [:], now: now, readme: { _ in nil }, checkoutExists: { _ in false })
        XCTAssertEqual(moved.map(\.key), ["remote:quill", "remote:ink"])
        XCTAssertEqual(moved[0].keys, ["remote:quill", "/w/quill"])
    }

    /// #920's order: the user's line, else GitHub's, else the agent's; the
    /// README; GitHub's topics; the terms.
    func testTheDescriptionPutsTheUsersLineThenGitHubsThenTheAgents() {
        let github = GitHubRepositoryFacts(
            description: "Swift SDK for audio with MLX", topics: ["mlx", "tts"], parent: "Blaizzy/mlx-audio-swift")
        func project(userLine: String? = nil, agentLine: String? = nil, github: GitHubRepositoryFacts? = nil) -> QuickCaptureProject {
            QuickCaptureProject(
                key: "/w/mlx", name: "mlx-audio-swift", summary: "Runs TTS on device.", terms: ["Kokoro"],
                agentLine: agentLine, userLine: userLine, repository: "me/mlx-audio-swift", github: github)
        }
        XCTAssertEqual(
            project(agentLine: "Audio models.", github: github).description,
            "Project mlx-audio-swift. Swift SDK for audio with MLX. A fork of Blaizzy/mlx-audio-swift. "
                + "Runs TTS on device. Topics: mlx, tts. Its names: Kokoro."
        )
        XCTAssertEqual(
            project(userLine: "My TTS fork.", agentLine: "Audio models.", github: github).description,
            "Project mlx-audio-swift. My TTS fork. Runs TTS on device. Its names: Kokoro."
        )
        XCTAssertEqual(
            project(agentLine: "Audio models.").description,
            "Project mlx-audio-swift. Audio models. Runs TTS on device. Its names: Kokoro."
        )
        XCTAssertEqual(project(agentLine: "Audio models.", github: github).automaticLine,
                       "Swift SDK for audio with MLX. A fork of Blaizzy/mlx-audio-swift.")
    }

    func testGitHubsAnswerIsReadForItsDescriptionTopicsAndParent() {
        let output = #"{"description":"Dictation\nfor agents ","topics":["swift","Bad Topic","mlx"],"parent":"Blaizzy/mlx"}"#
        XCTAssertEqual(
            QuickCaptureFiling.repositoryFacts(inOutput: Data(output.utf8)),
            GitHubRepositoryFacts(description: "Dictation for agents", topics: ["swift", "mlx"], parent: "Blaizzy/mlx")
        )
        XCTAssertEqual(
            QuickCaptureFiling.repositoryFacts(inOutput: Data(#"{"description":null,"topics":[],"parent":null}"#.utf8)),
            GitHubRepositoryFacts(description: nil, topics: [], parent: nil)
        )
        XCTAssertNil(QuickCaptureFiling.repositoryFacts(inOutput: Data("gh: Not Found (HTTP 404)".utf8)))
        XCTAssertEqual(
            QuickCaptureFiling.repositoryFactsArguments(repository: "me/quill"),
            ["api", "repos/me/quill", "--jq", "{description, topics, parent: .parent.full_name}"]
        )
    }
}

@MainActor
final class QuickCaptureProjectLinkerTests: XCTestCase {
    private final class Store: QuickCaptureProjectLinkStoring, @unchecked Sendable {
        let memory: Mutex<LearnedTerms>
        let now: Date
        init(_ learned: LearnedTerms, now: Date) {
            memory = Mutex(learned)
            self.now = now
        }
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordOriginRepository(_ repository: String, projectKey: String) {
            memory.withLock { _ = $0.recordOriginRepository(repository, projectKey: projectKey) }
        }
        func recordGitHub(_ facts: GitHubRepositoryFacts, repository: String) {
            let now = now
            memory.withLock { $0.recordGitHub(facts, repository: repository, now: now) }
        }
    }

    private final class GitHub: QuickCaptureGitHub, @unchecked Sendable {
        let originsRead = Mutex<[String]>([])
        let described = Mutex<[String]>([])
        let answers = Mutex<[String: GitHubRepositoryFacts]>([:])
        func repository(ofCheckout path: String) async -> String? {
            originsRead.withLock { $0.append(path) }
            return path == "/w/quill" ? "me/quill" : nil
        }
        func openIssues(ofCheckout path: String, repository: String?) async -> [QuickCaptureDraft.OpenIssue]? { [] }
        func repositoryFacts(_ repository: String) async -> GitHubRepositoryFacts? {
            described.withLock { $0.append(repository) }
            return answers.withLock { $0[repository] }
        }
        func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
            .failure(.noURL)
        }
    }

    func testOriginsAreReadOnceAndDescriptionsWeekly() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var clock = start
        let term = LearnedTerm(term: "Kern", sources: ["screen"], dictations: 3, firstSeen: start, lastSeen: start)
        var host = LearnedTermProject(key: "remote:ink", name: "ink", terms: [], lastSeen: start)
        host.reportedAsRepository = true
        host.repository = "me/ink"
        let store = Store(LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term], lastSeen: start),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term], lastSeen: start),
            host,
        ]), now: start)
        let github = GitHub()
        github.answers.withLock { $0["me/quill"] = .init(description: "Quill.", topics: [], parent: nil) }
        let linker = QuickCaptureProjectLinker(store: store, github: github, now: { clock })

        await linker.refresh().value
        XCTAssertEqual(github.originsRead.withLock { $0 }.sorted(), ["/w/notes", "/w/quill"], "a host's checkout is not on this Mac")
        XCTAssertEqual(store.snapshot().projects.first { $0.key == "/w/quill" }?.repository, "me/quill")
        XCTAssertEqual(store.snapshot().projects.first { $0.key == "/w/quill" }?.github?.description, "Quill.")
        XCTAssertEqual(github.described.withLock { $0 }.sorted(), ["me/ink", "me/quill"])

        // A day later: nothing is read again, and gh's failure on me/ink
        // waits for a forced refresh.
        clock = start.addingTimeInterval(86_400)
        await linker.refresh().value
        XCTAssertEqual(github.originsRead.withLock { $0 }.count, 2)
        XCTAssertEqual(github.described.withLock { $0 }.count, 2)

        // The sheet opens: every repository is asked again.
        await linker.refresh(force: true).value
        XCTAssertEqual(github.described.withLock { $0 }.count, 4)

        // A week after the last answer, me/quill is due again.
        clock = start.addingTimeInterval(8 * 86_400)
        await linker.refresh().value
        XCTAssertEqual(github.described.withLock { $0 }.suffix(1), ["me/quill"])
    }
}
