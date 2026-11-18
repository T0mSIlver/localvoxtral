import Foundation
import XCTest

@testable import localvoxtralCore

/// What quick capture left in the learned-term file, which the Projects pane
/// still reads: an upgrade loads it whole, lists its projects, and a later
/// edit writes the old fields back unchanged.
final class RemovedFeatureStoredStateTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A file as the build before the removal wrote it: a project with the
    /// router's GitHub facts, the filing choice and the README summary, and a
    /// repository record the Inbox added with no checkout.
    private static let oldFile = """
        {"version":1,"projects":[
         {"key":"/Users/me/work/payments","name":"payments","lastSeen":"2026-10-20T09:00:00Z",
          "terms":[{"term":"Ledgerd","sources":["screen"],"dictations":4,"firstSeen":"2026-10-01T09:00:00Z",
                    "lastSeen":"2026-10-20T09:00:00Z","pinned":true},
                   {"term":"Idempotency","sources":["agent:claude"],"dictations":0,"firstSeen":"2026-10-02T09:00:00Z",
                    "lastSeen":"2026-10-02T09:00:00Z"}],
          "summary":"Payments service.","summaryAt":"2026-10-03T09:00:00Z",
          "agentLine":"A ledger service.","agentLineAt":"2026-10-03T09:00:00Z",
          "repository":"acme/payments","repositoryTyped":true,
          "github":{"description":"Payments","topics":["fintech"],"parent":"upstream/payments"},
          "githubAt":"2026-10-04T09:00:00Z","filesUpstream":true},
         {"key":"repo:github.com/acme/ledger","name":"ledger","lastSeen":"2026-10-21T09:00:00Z","terms":[],
          "repository":"acme/ledger","addedFromInbox":true,
          "github":{"description":null,"topics":[],"parent":null}}
        ]}
        """

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("removed-feature-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("learned-terms.json")
    }

    func testAFileWithQuickCaptureFieldsLoadsAndIsListed() async throws {
        let fileURL = try makeFileURL()
        try Data(Self.oldFile.utf8).write(to: fileURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let learned = await store.loadedSnapshot()

        XCTAssertNil(store.problem, "the old fields decode; the file is not refused")
        XCTAssertEqual(learned.projects.map(\.key), ["/Users/me/work/payments", "repo:github.com/acme/ledger"])
        let payments = try XCTUnwrap(learned.projects.first)
        XCTAssertEqual(payments.github?.parent, "upstream/payments")
        XCTAssertEqual(payments.filesUpstream, true)
        XCTAssertEqual(learned.projects.last?.addedFromInbox, true)

        let listed = ListedProjects.projects(from: learned, now: Self.start)
        XCTAssertTrue(
            listed.contains { $0.terms.contains("Ledgerd") },
            "the pinned term still shows under its project: \(listed.map(\.key))")
    }

    func testAnEditAfterTheUpgradeKeepsTheOldFieldsAndTheKeptFeaturesWork() async throws {
        let fileURL = try makeFileURL()
        try Data(Self.oldFile.utf8).write(to: fileURL)
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        _ = await store.loadedSnapshot()

        store.setPinned(false, term: "Ledgerd", projectKey: "/Users/me/work/payments")
        store.forget("Idempotency", projectKey: "/Users/me/work/payments")
        store.waitForPendingWrites()

        let reread = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let learned = await reread.loadedSnapshot()
        let payments = try XCTUnwrap(learned.projects.first { $0.key == "/Users/me/work/payments" })
        XCTAssertEqual(payments.terms.map(\.term), ["Ledgerd"], "forget removed the proposal")
        XCTAssertEqual(payments.terms.first?.isPinned, false, "unpin took")
        XCTAssertEqual(payments.repository, "acme/payments")
        XCTAssertEqual(payments.filesUpstream, true, "the old field survives the rewrite")
        XCTAssertEqual(
            learned.projects.first { $0.key == "repo:github.com/acme/ledger" }?.addedFromInbox, true)
    }

    func testForgettingAProjectTheInboxAddedRemovesIt() async throws {
        let fileURL = try makeFileURL()
        try Data(Self.oldFile.utf8).write(to: fileURL)
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        _ = await store.loadedSnapshot()

        store.forgetProject(keys: ["repo:github.com/acme/ledger"])
        store.waitForPendingWrites()

        let reread = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let keys = await reread.loadedSnapshot().projects.map(\.key)
        XCTAssertFalse(keys.contains("repo:github.com/acme/ledger"), "no Inbox is left to re-add it, so Forget is final")
    }
}
