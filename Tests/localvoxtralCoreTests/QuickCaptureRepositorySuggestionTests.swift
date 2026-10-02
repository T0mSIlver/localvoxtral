import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #930: an unplaced capture may offer one of the user's recent GitHub
/// repositories that no project names; only accepting it makes it a project.
@MainActor
final class QuickCaptureRepositorySuggestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("qc-repos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pushed(daysAgo days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testACatchAllCaptureIsOfferedOnlyARecentUnlistedRepositoryAndAcceptingListsIt() async throws {
        var learned = LearnedTerms()
        var reach = LearnedTermProject(key: "/w/reach", name: "reach", terms: [], lastSeen: now)
        reach.repository = "o/reach"
        learned.projects = [reach]
        let repositories = [
            GitHubListedRepository(nameWithOwner: "o/reach", description: "Reach app", pushedAt: pushed(daysAgo: 1)),
            GitHubListedRepository(nameWithOwner: "o/vidtheque", description: "Video search", pushedAt: pushed(daysAgo: 3)),
            GitHubListedRepository(nameWithOwner: "o/oldtool", description: nil, pushedAt: pushed(daysAgo: 45)),
            GitHubListedRepository(nameWithOwner: "o/notes", description: nil, pushedAt: pushed(daysAgo: 2)),
        ]
        let classifier = ScriptedQuickCaptureClassifier([[QuickCaptureRouting.catchAllID: 0.9]])
        let projects: @MainActor () -> [QuickCaptureProject] = { [now] in
            QuickCaptureProjects.projects(
                from: learned, userLines: [:], now: now, readme: { _ in nil }, checkoutExists: { _ in true })
        }
        let model = QuickCaptureInboxModel(
            fileURL: directory.appendingPathComponent("quick-captures.json"),
            makeRouter: { QuickCaptureRouter(classifiers: [classifier]) },
            projects: projects,
            agents: { [.claude] },
            drafter: { QuickCaptureDrafter(runner: FakeQuickCaptureDraftRunner(), openIssues: { _, _ in [] }) },
            github: FakeQuickCaptureGitHub(),
            recentRepositories: { repositories },
            now: { [now] in now }
        )
        model.onRepositoryAdded = { [now] in _ = learned.addRepositoryProject($0, now: now) }

        // Spoken as two words; reach is a project and oldtool is stale.
        await model.capture(text: "Vid theque should index the reach demo and the oldtool talks", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertNil(model.items.first?.projectKey)
        XCTAssertEqual(model.items.first?.repositorySuggestion, .init(repository: "o/vidtheque", name: "vidtheque"))
        let firstOptions = try XCTUnwrap(classifier.calls.withLock { $0.first })
        XCTAssertFalse(firstOptions.contains { $0.description.lowercased().contains("vidtheque") })

        await model.acceptRepositorySuggestion(id)?.value
        XCTAssertTrue(projects().contains { $0.name == "vidtheque" && $0.repository == "o/vidtheque" })
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.projectName, "vidtheque")
        XCTAssertEqual(item.repository, "o/vidtheque")
        XCTAssertNil(item.repositorySuggestion)
        XCTAssertEqual(item.note, "No checkout of this repository to draft in.")

        await model.capture(text: "A note for later", historyRecordID: nil).value
        let secondOptions = try XCTUnwrap(classifier.calls.withLock { $0.last })
        XCTAssertTrue(secondOptions.contains { $0.description.contains("Project vidtheque.") })
        XCTAssertNil(model.items.first?.repositorySuggestion, "words that name no repository get no suggestion")
    }

    /// An added repository is one project with the checkout that names it
    /// later, led by the checkout.
    func testACheckoutOfAnAddedRepositoryJoinsItsProject() async throws {
        var learned = LearnedTerms()
        XCTAssertEqual(learned.addRepositoryProject("o/vidtheque", now: now), "repo:github.com/o/vidtheque")
        learned.projects.append(LearnedTermProject(key: "/w/vidtheque", name: "vidtheque", terms: [], lastSeen: now))
        XCTAssertTrue(learned.recordOriginRepository("o/vidtheque", projectKey: "/w/vidtheque"))

        let projects = QuickCaptureProjects.projects(
            from: learned, userLines: [:], now: now, readme: { _ in nil }, checkoutExists: { _ in true })

        XCTAssertEqual(projects.map(\.key), ["/w/vidtheque"])
        XCTAssertEqual(projects.first?.keys, ["/w/vidtheque", "repo:github.com/o/vidtheque"])
        XCTAssertEqual(learned.checkouts(ofRepository: "repo:github.com/o/vidtheque", now: now).map(\.key), ["/w/vidtheque"])
    }

    func testTheListIsAskedAtMostOnceADayAndAFailureSuggestsNothing() async {
        final class GitHub: Sendable {
            let asked = Mutex(0)
            let answer = Mutex<[GitHubListedRepository]?>(nil)
        }
        let github = GitHub()
        var moment = now
        let fileURL = directory.appendingPathComponent("github-repositories.json")
        func cache() -> GitHubRepositoryListCache {
            GitHubRepositoryListCache(
                fileURL: fileURL,
                fetch: {
                    github.asked.withLock { $0 += 1 }
                    return github.answer.withLock { $0 }
                },
                now: { moment }
            )
        }
        let listed = [GitHubListedRepository(nameWithOwner: "o/vidtheque", description: nil, pushedAt: now)]

        let first = cache()
        let failed = await first.repositories()
        XCTAssertEqual(failed, [])
        github.answer.withLock { $0 = listed }
        moment = now.addingTimeInterval(23 * 3600)
        let stillFailed = await cache().repositories()
        XCTAssertEqual(stillFailed, [], "a relaunch within the day does not ask again")
        XCTAssertEqual(github.asked.withLock { $0 }, 1)

        moment = now.addingTimeInterval(24 * 3600)
        let fetched = await first.repositories()
        XCTAssertEqual(fetched, listed)
        XCTAssertEqual(github.asked.withLock { $0 }, 2)
    }

    func testGhRepoListOutputIsRead() async throws {
        let output = Data("""
        [{"description":"Video search","nameWithOwner":"o/vidtheque","pushedAt":"2026-09-30T12:00:00Z"},
         {"description":"","nameWithOwner":"o/notes","pushedAt":"2026-09-01T08:30:00Z"},
         {"description":null,"nameWithOwner":"not a repository","pushedAt":"2026-09-01T08:30:00Z"}]
        """.utf8)

        let repositories = try XCTUnwrap(GitHubRepositorySuggestions.repositories(inOutput: output))

        XCTAssertEqual(repositories.map(\.nameWithOwner), ["o/vidtheque", "o/notes"])
        XCTAssertEqual(repositories.map(\.description), ["Video search", nil])
        XCTAssertEqual(repositories.first?.pushedAt, ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        XCTAssertNil(GitHubRepositorySuggestions.repositories(inOutput: Data("gh: not logged in".utf8)))
    }
}
