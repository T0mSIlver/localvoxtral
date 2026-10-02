import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// Forget Project's tombstone (#1156): the agent-activity listing (#1027)
/// does not bring a forgotten project back; a dictation or a hook does.
final class LearnedTermsForgottenProjectTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let quill = ProjectRemote("github.com/me/quill")!
    private let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")

    private func agentWorked(in project: LearnedTermProjectIdentity) -> [AgentWorkedRepository] {
        [AgentWorkedRepository(project: project, remote: quill, lastActive: Self.start)]
    }

    private func makeFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forgotten-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("learned-terms.json")
    }

    func testAForgottenProjectStaysOutOfTheAgentListingUntilADictation() throws {
        let fileURL = makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        let listed = store.snapshot()
        XCTAssertEqual(listed.projects.map(\.key).sorted(), [mac.key, quill.key].sorted())

        store.forgetProject(keys: [mac.key, quill.key])
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        // A new clone of the same repository, found through its `origin`.
        let clone = LearnedTermProjectIdentity(key: "/w/quill-2", name: "quill-2")
        store.recordAgentActivity(agentWorked(in: clone), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().projects, [], "the agent listing adds nothing back")

        // The tombstone outlives a relaunch.
        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().projects, [])
        let tombstones = try XCTUnwrap(
            LearnedTermStore.forgotten(fromFileContents: Data(contentsOf: XCTUnwrap(reopened.forgottenFileURL))).value)
        XCTAssertEqual(tombstones.projects.map(\.keys), [[mac.key, quill.key].sorted()])
        XCTAssertEqual(tombstones.projects.first?.forgottenAt, Self.start)

        reopened.record([LearnedTermObservation(term: "Kern", source: .repository)], project: mac)
        reopened.waitForPendingWrites()
        XCTAssertNotNil(reopened.snapshot().termRecord(mac.key), "a dictation brings it back")
        XCTAssertEqual(reopened.snapshot().forgotten.projects, [])

        reopened.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        reopened.waitForPendingWrites()
        XCTAssertEqual(
            reopened.snapshot().projects.first { $0.key == mac.key }?.agentActiveAt, Self.start,
            "the next agent report stamps it")
        let cleared = try XCTUnwrap(
            LearnedTermStore.forgotten(fromFileContents: Data(contentsOf: XCTUnwrap(reopened.forgottenFileURL))).value)
        XCTAssertEqual(cleared.projects, [], "the cleared tombstone is written")
    }

    func testAHookBringsAForgottenProjectBack() {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        let host = LearnedTermProjectIdentity(key: "remote:quill", name: "quill")
        store.recordAgentActivity(agentWorked(in: host), hostID: "box")
        store.forgetProject(keys: [host.key])
        store.recordAgentActivity(agentWorked(in: host), hostID: "box")
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().projects, [])

        store.recordRemoteReport(project: host, asRepository: true, repository: "me/quill", hostID: "box")
        store.recordAgentActivity(agentWorked(in: host), hostID: "box")
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().forgotten.projects, [])
        XCTAssertEqual(store.snapshot().projects.first { $0.key == host.key }?.agentActiveAt, Self.start)
    }

    /// The records go only once the tombstone is on disk: a quit before
    /// then finds the project as it was, never forgotten with nothing to
    /// keep the agent listing from adding it back.
    func testAForgetWhoseTombstoneWasNotWrittenKeepsTheRecordsOnDisk() throws {
        let fileURL = makeFileURL()
        let tombstoneWriteFails = Mutex(false)
        let store = LearnedTermStore(
            fileURL: fileURL, now: { Self.start },
            writeForgottenList: { data, url in
                if tombstoneWriteFails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try LearnedTermStore.writeFile(data, to: url)
            })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        tombstoneWriteFails.withLock { $0 = true }

        store.forgetProject(keys: [mac.key, quill.key])
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().projects, [], "forgotten in memory")
        let relaunched = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        relaunched.waitForPendingWrites()
        XCTAssertEqual(relaunched.snapshot().projects.count, 2, "a relaunch finds the project as it was")

        tombstoneWriteFails.withLock { $0 = false }
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().projects, [], "the next write lands both, in order")
    }

    func testAnAgentsTermsProposalDoesNotBringAForgottenProjectBack() async {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.forgetProject(keys: [mac.key, quill.key])
        let added = await store.recordCommandProposal(["Kern"], proposer: "claude", project: mac, excluding: [])
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(added, [])
        XCTAssertEqual(store.snapshot().projects, [])
    }

    /// An older build, which knows no tombstone, listed the project again
    /// from activity before the forget; a dictation after it stays.
    func testARelaunchSweepsWhatAnOlderBuildAddedBackButKeepsLaterDictations() throws {
        let fileURL = makeFileURL()
        let later = Self.start.addingTimeInterval(60)
        let store = LearnedTermStore(fileURL: fileURL, now: { later })
        store.forgetProject(keys: [mac.key, "/w/ink"])
        store.waitForPendingWrites()

        let kern = LearnedTerm(term: "Kern", sources: ["screen"], dictations: 3, firstSeen: Self.start, lastSeen: Self.start)
        let older = LearnedTerms(projects: [
            LearnedTermProject(key: mac.key, name: "quill", terms: [kern], lastSeen: Self.start),
            LearnedTermProject(key: "/w/ink", name: "ink", terms: [kern], lastSeen: later.addingTimeInterval(60)),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(older).write(to: fileURL)

        let reopened = LearnedTermStore(fileURL: fileURL, now: { later })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().projects.map(\.key), ["/w/ink"])
        let onDisk = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: Data(contentsOf: fileURL)).value)
        XCTAssertEqual(onDisk.projects.map(\.key), ["/w/ink"], "the sweep is written")
    }

    /// A tombstone file this build cannot read is kept as it is, and only
    /// the agent listing stops: any repo may be a forgotten one.
    func testAnUnreadableTombstoneFileStopsOnlyTheAgentListing() throws {
        let fileURL = makeFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstoneURL = directory.appendingPathComponent(LearnedTermStore.forgottenFileName)
        let newer = Data(#"{"version":99,"projects":[]}"#.utf8)
        try newer.write(to: tombstoneURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.forgetProject(keys: ["/w/ink"])
        store.record([LearnedTermObservation(term: "Kern", source: .repository)], project: mac)
        store.waitForPendingWrites()

        XCTAssertEqual(store.snapshot().projects.map(\.key), [mac.key], "the dictation, not the agent listing")
        XCTAssertEqual(try Data(contentsOf: tombstoneURL), newer, "the file is left alone")
    }

    /// Settings' Start Over (#1425): the problem shows until the file is
    /// moved aside, with its bytes, and then agents list projects again.
    func testStartOverMovesANewerTombstoneFileAsideAndAgentsListProjectsAgain() async throws {
        let fileURL = makeFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstoneURL = directory.appendingPathComponent(LearnedTermStore.forgottenFileName)
        let newer = Data(#"{"version":99,"projects":[]}"#.utf8)
        try newer.write(to: tombstoneURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(store.forgottenListProblem, .newerVersion(99))
        XCTAssertEqual(store.snapshot().projects, [])

        let aside = try await store.moveForgottenListAsideAndStartOver()
        XCTAssertEqual(try Data(contentsOf: aside), newer, "moved aside with its bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path))
        XCTAssertNil(store.forgottenListProblem)

        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().projects.map(\.key).sorted(), [mac.key, quill.key].sorted())
        XCTAssertNil(store.forgottenListProblem)
    }

    /// Tombstones this copy read before another wrote a file it cannot read
    /// outlive Start Over and a relaunch.
    func testStartOverWritesTheTombstonesThisCopyStillHolds() async throws {
        let fileURL = makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.forgetProject(keys: [mac.key, quill.key])
        store.waitForPendingWrites()
        let tombstoneURL = try XCTUnwrap(store.forgottenFileURL)
        try Data(#"{"version":99,"projects":[]}"#.utf8).write(to: tombstoneURL)
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(store.forgottenListProblem, .newerVersion(99))

        _ = try await store.moveForgottenListAsideAndStartOver()
        let written = try XCTUnwrap(
            LearnedTermStore.forgotten(fromFileContents: Data(contentsOf: tombstoneURL)).value)
        XCTAssertEqual(written.projects.map(\.keys), [[mac.key, quill.key].sorted()])

        let relaunched = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        relaunched.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        relaunched.waitForPendingWrites()
        XCTAssertEqual(relaunched.snapshot().projects, [], "the forget holds")
    }

    /// When Start Over cannot write the tombstones it keeps, the retry puts
    /// them back on top of the file another running copy wrote meanwhile.
    func testStartOverRetriesItsTombstonesOverAnotherCopysFile() async throws {
        let fileURL = makeFileURL()
        let tombstoneWriteFails = Mutex(false)
        let store = LearnedTermStore(
            fileURL: fileURL, now: { Self.start },
            writeForgottenList: { data, url in
                if tombstoneWriteFails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try LearnedTermStore.writeFile(data, to: url)
            })
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.forgetProject(keys: [mac.key, quill.key])
        store.waitForPendingWrites()
        let tombstoneURL = try XCTUnwrap(store.forgottenFileURL)
        try Data(#"{"version":99,"projects":[]}"#.utf8).write(to: tombstoneURL)
        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertEqual(store.forgottenListProblem, .newerVersion(99))

        tombstoneWriteFails.withLock { $0 = true }
        _ = try await store.moveForgottenListAsideAndStartOver()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path), "the write failed")
        // Another running copy writes its own tombstones.
        try Data(#"{"projects":[{"forgottenAt":"2023-11-14T22:13:20Z","keys":["/w/ink"]}],"version":1}"#.utf8)
            .write(to: tombstoneURL)
        tombstoneWriteFails.withLock { $0 = false }

        store.recordAgentActivity(agentWorked(in: mac), hostID: nil)
        store.waitForPendingWrites()
        XCTAssertNil(store.forgottenListProblem, "the other copy's file reads")
        XCTAssertEqual(store.snapshot().projects, [], "the forget holds")
        let written = try XCTUnwrap(
            LearnedTermStore.forgotten(fromFileContents: Data(contentsOf: tombstoneURL)).value)
        XCTAssertEqual(
            Set(written.projects.map(\.keys)), [["/w/ink"], [mac.key, quill.key].sorted()],
            "both copies' tombstones")
    }

    /// Start Over deletes the original once it is linked aside: without the
    /// lock another copy could replace it in between, so it refuses.
    func testStartOverRefusesWithoutTheLock() async throws {
        let fileURL = makeFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstoneURL = directory.appendingPathComponent(LearnedTermStore.forgottenFileName)
        let newer = Data(#"{"version":99,"projects":[]}"#.utf8)
        try newer.write(to: tombstoneURL)
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.waitForPendingWrites()
        // A directory where the lock file goes: open(2) fails.
        let lockURL = StoredFileLock.lockURL(beside: try XCTUnwrap(store.ignoredFileURL))
        try? FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        do {
            _ = try await store.moveForgottenListAsideAndStartOver()
            XCTFail("Start Over moved the file without the lock")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: tombstoneURL), newer)
        XCTAssertEqual(store.forgottenListProblem, .newerVersion(99))
    }
}
