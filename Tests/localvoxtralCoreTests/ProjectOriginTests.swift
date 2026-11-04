import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// A project's GitHub repository, from its checkout's `origin` or its host's
/// report (#926, #971).
final class ProjectOriginTests: XCTestCase {
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

    /// The same repository on the Mac and on a host is one project, led by
    /// the Mac's checkout, with both checkouts' terms; the learned terms keep
    /// both.
    func testTwoCheckoutsOfOneRepositoryAreOneProject() {
        var local = LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: now)
        local.repository = "me/quill"
        var host = LearnedTermProject(key: "remote:quill", name: "quill", terms: [term("Glyph"), term("kern")], lastSeen: now.addingTimeInterval(60))
        host.repository = "me/quill"
        host.reportedAsRepository = true
        var other = LearnedTermProject(key: "remote:ink", name: "ink", terms: [term("Ink")], lastSeen: now)
        other.reportedAsRepository = true
        let learned = LearnedTerms(projects: [local, host, other])

        let projects = ListedProjects.projects(from: learned, now: now, checkoutExists: { $0 == "/w/quill" })

        XCTAssertEqual(projects.map(\.key), ["/w/quill", "remote:ink"])
        XCTAssertEqual(projects[0].keys, ["/w/quill", "remote:quill"])
        XCTAssertEqual(projects[0].terms, ["Kern", "Glyph"], "one spelling once")
        XCTAssertEqual(learned.listedProjects(now: now).count, 3)

        // The Mac's checkout is gone: the host's leads.
        let moved = ListedProjects.projects(from: learned, now: now, checkoutExists: { _ in false })
        XCTAssertEqual(moved.map(\.key), ["remote:quill", "remote:ink"])
        XCTAssertEqual(moved[0].keys, ["remote:quill", "/w/quill"])
    }
}

@MainActor
final class ProjectOriginLinkerTests: XCTestCase {
    private final class Store: ProjectOriginStoring, @unchecked Sendable {
        let memory: Mutex<LearnedTerms>
        init(_ learned: LearnedTerms) { memory = Mutex(learned) }
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordOrigin(_ remote: ProjectRemote, projectKey: String) {
            memory.withLock { _ = $0.recordOrigin(remote, projectKey: projectKey) }
        }
    }

    private final class Origins: CheckoutOriginReading, @unchecked Sendable {
        let read = Mutex<[String]>([])
        func remote(ofCheckout path: String) async -> ProjectRemote? {
            read.withLock { $0.append(path) }
            return path == "/w/quill" ? ProjectRemote(githubRepository: "me/quill") : nil
        }
    }

    func testOriginsAreReadOnceALaunchAndLinkTheCheckoutToItsRepository() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let term = LearnedTerm(term: "Kern", sources: ["screen"], dictations: 3, firstSeen: start, lastSeen: start)
        var host = LearnedTermProject(key: "remote:ink", name: "ink", terms: [], lastSeen: start)
        host.reportedAsRepository = true
        host.repository = "me/ink"
        let store = Store(LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term], lastSeen: start),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term], lastSeen: start),
            host,
        ]))
        let origins = Origins()
        let linker = ProjectOriginLinker(store: store, origins: origins, now: { start })

        await linker.refresh().value
        XCTAssertEqual(origins.read.withLock { $0 }.sorted(), ["/w/notes", "/w/quill"], "a host's checkout is not on this Mac")
        XCTAssertEqual(store.snapshot().projects.first { $0.key == "/w/quill" }?.repository, "me/quill")
        XCTAssertEqual(
            store.snapshot().projects.first { $0.key == "/w/quill" }?.remote, "github.com/me/quill",
            "the checkout joins its repository's project")

        await linker.refresh().value
        XCTAssertEqual(origins.read.withLock { $0 }.count, 2, "nothing is read again this launch")
    }
}
