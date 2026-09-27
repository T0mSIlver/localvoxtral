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
        captures: [QuickCaptureItem] = [],
        hosts: [(id: String, name: String)] = [],
        sessions: [ClaudeSessionSnapshot] = [],
        dictations: [String?] = [],
        userLines: [String: String] = [:]
    ) -> [ProjectsPaneRow] {
        ProjectsPane.rows(
            projects: QuickCaptureProjects.projects(
                from: learned, userLines: userLines, now: now, readme: { _ in nil }, checkoutExists: { _ in true }
            ),
            learned: learned,
            captures: captures,
            hostNames: hosts,
            liveSessions: sessions,
            dictationProjectKeys: dictations
        )
    }

    private func capture(_ projectKey: String?, _ state: QuickCaptureItem.State) -> QuickCaptureItem {
        var item = QuickCaptureItem(capturedAt: now, text: "a note")
        item.projectKey = projectKey
        item.state = state
        return item
    }

    private func session(_ id: String, cwd: String, origin: ClaudeTransportOrigin, agent: ClaudeHookAgent) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: origin, firstSeen: now)
        snapshot.agent = agent
        snapshot.workspace = .make(rawCwd: cwd, origin: origin)
        return snapshot
    }

    func testFilesInColumnWarnsForAnUnpickedForkAndAProjectWithNoRepository() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/app", name: "app", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "/w/tool", name: "tool", terms: [term("Tokio")], lastSeen: now),
            LearnedTermProject(key: "/w/lib", name: "lib", terms: [term("Serde")], lastSeen: now),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term("Obsidian")], lastSeen: now),
        ])
        learned.recordOriginRepository("me/app", projectKey: "/w/app")
        learned.recordOriginRepository("me/tool", projectKey: "/w/tool")
        learned.recordOriginRepository("me/lib", projectKey: "/w/lib")
        learned.recordGitHub(.init(description: nil, topics: [], parent: "them/tool"), repository: "me/tool", now: now)
        learned.recordGitHub(.init(description: nil, topics: [], parent: "them/lib"), repository: "me/lib", now: now)
        learned.setFilesUpstream(true, repository: "me/lib")

        let filing = Dictionary(uniqueKeysWithValues: rows(learned).map { ($0.name, $0.filing) })
        XCTAssertEqual(filing["app"], .repository("me/app"))
        XCTAssertEqual(filing["tool"], .forkUnpicked(fork: "me/tool", upstream: "them/tool"))
        XCTAssertEqual(filing["lib"], .repository("them/lib"))
        XCTAssertEqual(filing["notes"], .noRepository)

        // Picking the fork itself is a choice too: the warning goes.
        learned.setFilesUpstream(false, repository: "me/tool")
        XCTAssertEqual(rows(learned).first { $0.name == "tool" }?.filing, .repository("me/tool"))
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
        XCTAssertEqual(byName["quill"]?.keys, ["/w/quill", "remote:quill"])
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
        let captures = [
            capture("/w/quill", .ready), capture("remote:quill", .drafting), capture("/w/quill", .filed),
            capture("/w/ink", .filed), capture(nil, .ready),
        ]
        let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        let sessions = [
            session("a", cwd: "/w/quill/.claude/worktrees/x", origin: local, agent: .opencode),
            session("b", cwd: "/elsewhere/quill", origin: .remote(channel: "ssh:h1"), agent: .claude),
            session("c", cwd: "/w/quill-other", origin: local, agent: .claude),
            session("d", cwd: "/w/ink", origin: local, agent: .vibe),
        ]
        let dictations: [String?] = ["/w/quill", "remote:quill", "/w/ink", nil, "/w/gone"]

        let byName = Dictionary(uniqueKeysWithValues: rows(
            learned, captures: captures, sessions: sessions, dictations: dictations
        ).map { ($0.name, $0) })
        XCTAssertEqual(byName["quill"]?.draftsWaiting, 2)
        XCTAssertEqual(byName["quill"]?.filed, 1)
        XCTAssertEqual(byName["quill"]?.sessions, .init(running: 2, agents: [.claude, .opencode]),
                       "a sibling directory whose name starts the same is not the checkout")
        XCTAssertEqual(byName["quill"]?.dictationsThisWeek, 2)
        XCTAssertEqual(byName["ink"]?.draftsWaiting, 0)
        XCTAssertEqual(byName["ink"]?.filed, 1)
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

    func testDescriptionAndWhoWroteIt() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/app", name: "app", terms: [term("Kern")], lastSeen: now),
            LearnedTermProject(key: "/w/bare", name: "bare", terms: [term("Tokio")], lastSeen: now),
        ])
        learned.recordOriginRepository("me/app", projectKey: "/w/app")
        learned.recordGitHub(.init(description: "Dictation for agents", topics: [], parent: nil), repository: "me/app", now: now)

        var app = rows(learned).first { $0.name == "app" }
        XCTAssertEqual(app?.description, "Dictation for agents.")
        XCTAssertEqual(app?.descriptionSource, .github)
        XCTAssertEqual(rows(learned).first { $0.name == "bare" }?.descriptionSource, ProjectsPaneRow.DescriptionSource.none)

        app = rows(learned, userLines: ["/w/app": "My dictation app."]).first { $0.name == "app" }
        XCTAssertEqual(app?.description, "My dictation app.")
        XCTAssertEqual(app?.descriptionSource, .user)
    }

    func testTermsStrongestFirstEachSpellingOnceAcrossCheckouts() {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern", dictations: 3), term("Tokio", dictations: 9)], lastSeen: now),
            LearnedTermProject(key: "remote:quill", name: "quill", terms: [term("kern", dictations: 1), term("Serde", dictations: 5)], lastSeen: now),
        ])
        learned.recordOriginRepository("me/quill", projectKey: "/w/quill")
        learned.recordRemoteReport(project: remote("quill"), asRepository: true, repository: "me/quill", now: now)
        XCTAssertEqual(rows(learned).first?.terms, ["Tokio", "Serde", "Kern"])
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
