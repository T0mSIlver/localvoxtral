import Foundation
import XCTest

@testable import localvoxtralCore

final class ListedProjectsTests: XCTestCase {
    func testProjectsComeFromTheLearnedTerms() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func term(_ spelling: String, dictations: Int, source: String = "screen") -> LearnedTerm {
            LearnedTerm(term: spelling, sources: [source], dictations: dictations, firstSeen: now, lastSeen: now)
        }
        var website = LearnedTermProject(key: "remote:website", name: "website", terms: [term("Astro", dictations: 3)], lastSeen: now)
        website.reportedAt = now
        website.reportedAsRepository = true
        let learned = LearnedTerms(projects: [
            website,
            LearnedTermProject(
                key: "/w/localvoxtral", name: "localvoxtral",
                terms: [term("speechd", dictations: 0, source: "agent:claude"), term("Voxtral", dictations: 5), term("rare", dictations: 1)],
                lastSeen: now.addingTimeInterval(60)
            ),
        ])
        let projects = ListedProjects.projects(from: learned, now: now)
        XCTAssertEqual(projects.map(\.key), ["/w/localvoxtral", "remote:website"], "most recent first")
        XCTAssertEqual(projects[0].terms, ["Voxtral", "speechd"], "confirmed, then proposals; unconfirmed polish terms stay out")
        XCTAssertEqual(projects[1].terms, ["Astro"])
    }

    /// #819: a remote project no hook has named since hosts began sending
    /// `X-Lvx-Env-Project` is a label no session reports any more.
    func testARemoteProjectIsListedOnlyOnceAHookHasNamedIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400
        let term = LearnedTerm(term: "ScreenPipe", sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "remote:modest-lewin-c92780", name: "modest-lewin-c92780", terms: [term], lastSeen: now),
            LearnedTermProject(key: "remote:quill-fix", name: "quill-fix", terms: [term], lastSeen: now),
            LearnedTermProject(key: "/w/inkwell", name: "inkwell", terms: [term], lastSeen: now),
            LearnedTermProject(key: LearnedTermProjectResolver.shared.key, name: "No project", terms: [term], lastSeen: now),
        ])
        learned.recordRemoteReport(project: .init(key: "remote:quillmark", name: "quillmark"), asRepository: true, now: now)
        learned.recordRemoteReport(project: .init(key: "remote:quill-fix", name: "quill-fix"), asRepository: false, now: now)
        func listed(at moment: Date) -> [String] {
            ListedProjects.projects(from: learned, now: moment).map(\.key).sorted()
        }
        XCTAssertEqual(listed(at: now), ["/w/inkwell", "remote:quill-fix", "remote:quillmark"])
        XCTAssertEqual(
            listed(at: now.addingTimeInterval(Double(LearnedTerms.remoteLabelListedDays) * day)),
            ["/w/inkwell", "remote:quillmark"],
            "an old shim's cwd label drops out a week after its last hook; a repository stays"
        )
    }

    /// #1026: a folder name a tool generated is no project, however recent
    /// its hook; a repository whose name ends in a hex word still is.
    func testAToolGeneratedFolderNameIsNotListed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let term = LearnedTerm(term: "ScreenPipe", sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
        let labels = [
            "ci-speed-optimizations-7ffef0", "deepseek-v4-setup-questions-c7abac", "agent-add526d17c28bb610", "quill-fix",
        ]
        var learned = LearnedTerms(projects: labels.map {
            LearnedTermProject(key: "remote:" + $0, name: $0, terms: [term], lastSeen: now)
        })
        for label in labels {
            learned.recordRemoteReport(project: .init(key: "remote:" + label, name: label), asRepository: false, now: now)
        }
        learned.recordRemoteReport(project: .init(key: "remote:sha-abc123", name: "sha-abc123"), asRepository: true, now: now)

        XCTAssertEqual(ListedProjects.projects(from: learned, now: now).map(\.name), ["quill-fix", "sha-abc123"])
        XCTAssertEqual(PolishProjectNames.names(from: learned, now: now), ["quill-fix", "sha-abc123"])
    }
}
