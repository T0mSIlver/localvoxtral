import ClaudeContextWire
import Foundation
import XCTest

@testable import localvoxtralCore

/// The Projects pane's table and sheet data (#939).
final class ProjectsPaneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func term(_ spelling: String, dictations: Int = 3) -> LearnedTerm {
        LearnedTerm(term: spelling, sources: ["screen"], dictations: dictations, firstSeen: now, lastSeen: now)
    }

    private func remote(_ name: String) -> LearnedTermProjectIdentity {
        LearnedTermProjectIdentity(key: "remote:\(name)", name: name)
    }

    private func rows(
        _ learned: LearnedTerms,
        hosts: [(id: String, name: String)] = [],
        sessions: [ClaudeSessionSnapshot] = [],
        dictations: [String?] = []
    ) -> [ProjectsPaneRow] {
        ProjectsPane.rows(
            projects: ListedProjects.projects(from: learned, now: now, checkoutExists: { _ in true }),
            learned: learned,
            hostNames: hosts,
            liveSessions: sessions,
            dictationProjectKeys: dictations
        )
    }

    private func session(_ id: String, cwd: String, origin: ClaudeTransportOrigin, agent: ClaudeHookAgent) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: origin, firstSeen: now)
        snapshot.agent = agent
        snapshot.workspace = .make(rawCwd: cwd, origin: origin)
        return snapshot
    }

    func testARowNamesTheRepositoryItsOriginNames() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/app", name: "app", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term("Obsidian")], lastSeen: now),
        ])
        learned.recordOriginRepository("me/app", projectKey: "/w/app")
        let repositories = Dictionary(uniqueKeysWithValues: rows(learned).map { ($0.name, $0.repository) })
        XCTAssertEqual(repositories["app"], "me/app")
        XCTAssertNil(repositories["notes"] ?? nil)
    }

    func testCheckoutsNameTheMacAndEachHostThatReportedTheRepository() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", hostID: "h1", now: now)
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", hostID: "h2", now: now)
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", hostID: "h1", now: now)
        learned.recordRemoteReport(project: remote("ink"), asRepository: true, now: now)

        let hosts = [(id: "h2", name: "builder"), (id: "h1", name: "devbox")]
        let byName = Dictionary(uniqueKeysWithValues: rows(learned, hosts: hosts).map { ($0.name, $0) })
        XCTAssertEqual(byName.count, 2, "the Mac's and the hosts' quill are one row")
        XCTAssertEqual(byName["quill"]?.keys, ["/w/quill", "remote:quill", "repo:github.com/me/quill"])
        XCTAssertEqual(byName["quill"]?.checkouts(), "Mac · builder · devbox")
        XCTAssertEqual(byName["quill"]?.checkouts(macName: "This Mac"), "This Mac · builder · devbox")
        // Reported before hosts were recorded, or by a host since removed.
        XCTAssertEqual(byName["ink"]?.checkouts(), "A remote host")
        XCTAssertEqual(rows(learned, hosts: []).first { $0.name == "quill" }?.checkouts(), "Mac · A remote host")
    }

    func testCountsBelongToEveryCheckoutOfTheProject() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "/w/ink", name: "ink", terms: [term("Tokio")], lastSeen: now),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", hostID: "h1", now: now)
        let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        let sessions = [
            session("a", cwd: "/w/quill/.claude/worktrees/x", origin: local, agent: .opencode),
            session("b", cwd: "/elsewhere/quill", origin: .remote(channel: "ssh:h1"), agent: .claude),
            session("c", cwd: "/w/quill-other", origin: local, agent: .claude),
            session("d", cwd: "/w/ink", origin: local, agent: .vibe),
        ]
        let dictations: [String?] = ["/w/quill", "remote:quill", "/w/ink", nil, "/w/gone"]

        let byName = Dictionary(uniqueKeysWithValues: rows(
            learned, sessions: sessions, dictations: dictations
        ).map { ($0.name, $0) })
        XCTAssertEqual(byName["quill"]?.sessions, .init(running: 2, agents: [.claude, .opencode]),
                       "a sibling directory whose name starts the same is not the checkout")
        XCTAssertEqual(byName["quill"]?.dictationsThisWeek, 2)
        XCTAssertEqual(byName["ink"]?.sessions, .init(running: 1, agents: [.vibe]))
        XCTAssertEqual(byName["ink"]?.dictationsThisWeek, 1)
    }

    func testRowsRunMostRecentlyUsedFirstAndAHookCountsAsUse() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/old", name: "old", terms: [term("Kern")], lastSeen: now.addingTimeInterval(-86_400 * 3)),
            LearnedTermProject(key: "/w/new", name: "new", terms: [term("Tokio")], lastSeen: now.addingTimeInterval(-3_600)),
            LearnedTermProject(key: "remote:far", name: "far", terms: [term("Serde")], lastSeen: now.addingTimeInterval(-86_400 * 5)),
        ])
        learned.recordRemoteReport(project: remote("far"), asRepository: true, now: now)
        XCTAssertEqual(rows(learned).map(\.name), ["far", "new", "old"])
        XCTAssertEqual(rows(learned).first?.lastUsed, now)
    }

    func testTermsStrongestFirstEachSpellingOnceAcrossCheckouts() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern", dictations: 3), term("Tokio", dictations: 9)], lastSeen: now),
            LearnedTermProject(key: "remote:quill", name: "quill", terms: [term("kern", dictations: 1), term("Serde", dictations: 5)], lastSeen: now),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", now: now)
        XCTAssertEqual(rows(learned).first?.terms.map(\.term), ["Tokio", "Serde", "Kern"])
    }

    /// A pinned copy on one checkout leads the project's list and shows
    /// the pin, whichever checkout holds it.
    func testAPinnedCopyLeadsAndShowsThePin() {
        var pinned = term("kern", dictations: 1)
        pinned.pinned = true
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern", dictations: 9), term("Tokio", dictations: 5)], lastSeen: now),
            LearnedTermProject(key: "remote:quill", name: "quill", terms: [pinned], lastSeen: now),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", now: now)
        let terms = rows(learned).first?.terms
        XCTAssertEqual(terms?.map(\.term), ["kern", "Tokio"])
        XCTAssertEqual(terms?.first?.isPinned, true)
    }

    /// #972: Text Processing's count said "49 in 6 projects" while its sheet
    /// listed only the terms outside projects. Now every stored term shows
    /// under exactly one entry: its project's row, or "No project" for a
    /// bucket no row holds (a remote label no host named, the shared
    /// bucket), most recent first and the shared bucket last.
    func testEveryTermShowsUnderExactlyOneEntry() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "remote:quill", name: "quill", terms: [term("Serde")], lastSeen: now),
            LearnedTermProject(
                key: LearnedTermProjectResolver.shared.key, name: LearnedTermProjectResolver.shared.name,
                terms: [term("Qwen")], lastSeen: now),
            LearnedTermProject(
                key: "remote:bold-bose-fac585", name: "bold-bose-fac585", terms: [term("Tokio"), term("qwen")],
                lastSeen: now.addingTimeInterval(-60)),
            LearnedTermProject(
                key: "remote:modest-lewin-c92780", name: "modest-lewin-c92780", terms: [term("Obsidian")],
                lastSeen: now.addingTimeInterval(-30)),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", now: now)

        let rows = rows(learned)
        let unlisted = ProjectsPane.unlisted(learned: learned, rows: rows)
        XCTAssertEqual(rows.map(\.name), ["quill"])
        XCTAssertEqual(rows.first?.terms.map(\.term), ["Kern", "Serde"])
        XCTAssertEqual(
            unlisted?.keys,
            ["remote:modest-lewin-c92780", "remote:bold-bose-fac585", LearnedTermProjectResolver.shared.key]
        )
        XCTAssertEqual(Set(unlisted?.terms.map(\.term) ?? []), ["Qwen", "Tokio", "Obsidian"], "each spelling once")
        XCTAssertEqual(unlisted?.lastUsed, now)

        let entries = rows.map(\.keys) + [unlisted?.keys ?? []]
        for bucket in learned.projects {
            XCTAssertEqual(entries.filter { $0.contains(bucket.key) }.count, 1, bucket.key)
        }
        let shown = rows.map(\.terms.count).reduce(0, +) + (unlisted?.terms.count ?? 0)
        XCTAssertEqual(shown, learned.termCount - 1, "only qwen, a second spelling in one entry, folds away")
    }

    func testNoUnlistedEntryWhenEveryTermHasAProject() {
        let learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "remote:old", name: "old", terms: [], lastSeen: now),
        ])
        XCTAssertNil(ProjectsPane.unlisted(learned: learned, rows: rows(learned)))
    }

    func testSearchMatchesPartOfASpellingIgnoringCase() {
        let terms = [term("GlyphAtlasCache"), term("Kern"), term("useAuth")]
        XCTAssertEqual(ProjectsPane.matching(terms, query: "atlas").map(\.term), ["GlyphAtlasCache"])
        XCTAssertEqual(ProjectsPane.matching(terms, query: " AUTH ").map(\.term), ["useAuth"])
        XCTAssertEqual(ProjectsPane.matching(terms, query: "").count, 3)
        XCTAssertEqual(ProjectsPane.matching(terms, query: "zzz"), [])
    }

    /// Review of #973: forgetting the 13th term hides the search field;
    /// the query left in it must stop filtering.
    func testAQueryStopsFilteringOnceTheFieldHides() {
        let thirteen = (0...ProjectsPane.searchAbove).map { term("Term\($0)") }
        XCTAssertEqual(ProjectsPane.shown(thirteen, query: "Term12").map(\.term), ["Term12"])
        let twelve = Array(thirteen.dropLast())
        XCTAssertEqual(ProjectsPane.shown(twelve, query: "Term12").count, ProjectsPane.searchAbove)
    }

    func testLastUsedReadsLikeTheTable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 86_400 * 100 + 43_200)
        XCTAssertEqual(ProjectsPane.lastUsed(noon.addingTimeInterval(-600), now: noon, calendar: calendar), "now")
        XCTAssertEqual(ProjectsPane.lastUsed(noon.addingTimeInterval(-7_300), now: noon, calendar: calendar), "2 h")
        XCTAssertEqual(ProjectsPane.lastUsed(noon.addingTimeInterval(-43_300), now: noon, calendar: calendar), "yesterday")
        XCTAssertEqual(ProjectsPane.lastUsed(noon.addingTimeInterval(-86_400 * 3), now: noon, calendar: calendar), "3 days")
    }
}
