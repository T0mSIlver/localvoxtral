import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// Forget Project and Ignore Project in Settings → Projects (#1006): what
/// goes, what stays, and what an ignored repo can no longer add.
final class LearnedTermsIgnoreTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let quill = ProjectRemote("github.com/me/quill")!

    private func term(_ spelling: String, pinned: Bool = false) -> LearnedTerm {
        LearnedTerm(
            term: spelling, sources: ["screen"], dictations: 3, firstSeen: Self.start, lastSeen: Self.start,
            pinned: pinned ? true : nil)
    }

    private func observations(_ terms: String...) -> [LearnedTermObservation] {
        terms.map { LearnedTermObservation(term: $0, source: .repository) }
    }

    /// Quill on the Mac and on a host, linked to its repository's record;
    /// ink, another repository; notes, a checkout with no remote.
    private func threeProjects() -> LearnedTerms {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: Self.start),
            LearnedTermProject(key: "/w/ink", name: "ink", terms: [term("Inkwell", pinned: true)], lastSeen: Self.start),
            LearnedTermProject(key: "/w/notes", name: "notes", terms: [term("Obsidian")], lastSeen: Self.start),
        ])
        learned.recordOrigin(quill, projectKey: "/w/quill")
        learned.recordOrigin(ProjectRemote("github.com/me/ink")!, projectKey: "/w/ink")
        learned.recordRemoteReport(
            project: LearnedTermProjectIdentity(key: "remote:quill", name: "quill"), asRepository: true,
            repository: "me/quill", now: Self.start)
        learned.record(observations("Glyph"), project: .init(key: "remote:quill", name: "quill"), now: Self.start)
        return learned
    }

    private func makeFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignore-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("learned-terms.json")
    }

    // MARK: Forget

    func testForgetProjectRemovesOnlyThatProject() {
        var learned = threeProjects()
        XCTAssertEqual(learned.termRecord("/w/quill")?.terms.map(\.term).sorted(), ["Glyph", "Kern"])
        let others = learned.projects.filter { !$0.key.contains("quill") }
        XCTAssertEqual(others.count, 3, "ink's checkout and record, and notes")

        // The row's keys: its checkouts and its repository's record.
        let removed = learned.forgetProject(keys: ["/w/quill", quill.key])

        XCTAssertEqual(removed, 3, "both checkouts and the repository's record")
        XCTAssertEqual(learned.projects, others, "every other project is untouched, terms and all")
        XCTAssertFalse(learned.isIgnored(projectKey: "/w/quill"), "forgotten, not ignored")
        learned.record(observations("Kern"), project: .init(key: "/w/quill", name: "quill"), now: Self.start)
        XCTAssertEqual(learned.termRecord("/w/quill")?.terms.map(\.term), ["Kern"], "detected again from scratch")
        XCTAssertEqual(learned.termRecord("/w/quill")?.terms.first?.dictations, 1)
    }

    func testForgetProjectOfACheckoutWithNoRemote() {
        var learned = threeProjects()
        let others = learned.projects.filter { $0.key != "/w/notes" }
        learned.forgetProject(keys: ["/w/notes"])
        XCTAssertEqual(learned.projects, others)
    }

    /// Records left from before #975 (Tom, 2026-09-28): a checkout keyed by
    /// its old folder with no repository, and a checkout that names a
    /// repository whose record is gone. Forget takes each alone.
    func testForgetTakesALeftoverFromBeforeOneProjectPerRepository() {
        var learned = threeProjects()
        let current = learned.projects
        var orphan = LearnedTermProject(key: "/w/old-ink", name: "old-ink", terms: [], lastSeen: Self.start)
        orphan.remote = "github.com/me/gone"
        learned.projects += [
            LearnedTermProject(key: "/w/supervoxtral", name: "supervoxtral", terms: [term("Voxtral")], lastSeen: Self.start),
            orphan,
        ]
        let rows = learned.listedProjects(now: Self.start)
        XCTAssertTrue(rows.contains { $0.key == "/w/supervoxtral" }, "the leftover is listed, so it can be forgotten")
        XCTAssertTrue(rows.contains { $0.key == "repo:github.com/me/gone" }, "the orphan is listed under its repository")

        learned.forgetProject(keys: ["/w/supervoxtral"])
        learned.forgetProject(keys: ["/w/old-ink", "repo:github.com/me/gone"])

        XCTAssertEqual(learned.projects, current, "the current projects are untouched")
    }

    // MARK: Ignore

    /// Everything that adds a record or a term, after Ignore: nothing stays.
    func testAnIgnoredRepoGetsNothingRecordedLearnedOrProposed() async {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        let seeded = threeProjects()
        let importSummary = await withCheckedContinuation { continuation in
            store.importProjects(seeded.projects) { continuation.resume(returning: $0) }
        }
        XCTAssertGreaterThan(importSummary.terms, 0)
        // The summary arrives from inside the change, before the store
        // holds its result.
        store.waitForPendingWrites()
        let before = store.snapshot()
        let others = before.projects.filter { !$0.key.contains("quill") }

        store.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill", "remote:quill", quill.key])
        store.waitForPendingWrites()
        XCTAssertEqual(store.snapshot().projects, others, "its records went, the others stayed")

        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        let host = LearnedTermProjectIdentity(key: "remote:quill", name: "quill")
        store.record(observations("Kern", "Glyph"), project: mac)
        store.record(observations("Serif"), project: host)
        store.recordCorrection("Ligature", project: mac)
        store.recordRemoteReport(project: host, asRepository: true, repository: "me/quill")
        store.recordProposal(["Typesetter"], agent: .claude, project: mac, excluding: [])
        store.recordProposalFailure(project: host)
        let proposed = await store.recordCommandProposal(["Kerning"], proposer: "codex", project: mac, excluding: [])
        // A clone at a new path, before its origin is read, then once it is.
        let clone = LearnedTermProjectIdentity(key: "/elsewhere/quill", name: "quill")
        store.record(observations("Leading"), project: clone)
        store.recordOrigin(ProjectRemote(remoteURL: "git@github.com:me/quill.git")!, projectKey: clone.key)
        _ = await withCheckedContinuation { continuation in
            store.importProjects(seeded.projects.filter { $0.key.contains("quill") }) { continuation.resume(returning: $0) }
        }
        store.waitForPendingWrites()

        let after = store.snapshot()
        XCTAssertEqual(proposed, [])
        XCTAssertEqual(after.projects, others, "nothing recorded for any of its checkouts")
        XCTAssertFalse(after.listedProjects(now: Self.start).contains { $0.name == "quill" })
        XCTAssertFalse(after.confirmedEverywhere().contains { ["Kern", "Glyph", "Ligature"].contains($0.term) })
        let choices = QuickCaptureProjects.projects(from: after, userLines: [:], now: Self.start, readme: { _ in nil })
        XCTAssertFalse(choices.contains { $0.name == "quill" }, "quick capture does not list it")
        for key in [mac.key, host.key, clone.key] {
            XCTAssertFalse(after.needsProposal(projectKey: key, now: Self.start), key)
        }
        XCTAssertTrue(after.needsProposal(projectKey: "/w/new", now: Self.start), "other repos are still asked")
    }

    /// At the project cap, a dictation in an ignored checkout must not
    /// evict another project before the sweep drops it (review,
    /// 2026-09-29): that project's terms would be lost for good.
    func testDictatingInAnIgnoredCheckoutAtTheCapEvictsNoOtherProject() async {
        let moment = Mutex(Self.start.addingTimeInterval(-3_600))
        let store = LearnedTermStore(fileURL: nil, now: { moment.withLock { $0 } })
        let full = (0..<LearnedTerms.maxProjects).map {
            LearnedTermProject(key: "/w/p\($0)", name: "p\($0)", terms: [term("T\($0)")], lastSeen: moment.withLock { $0 })
        }
        _ = await withCheckedContinuation { continuation in
            store.importProjects(full) { continuation.resume(returning: $0) }
        }
        store.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill"])
        moment.withLock { $0 = Self.start }

        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        store.record(observations("Kern"), project: mac)
        store.recordCorrection("Glyph", project: mac)
        store.recordProposal(["Typesetter"], agent: .claude, project: mac, excluding: [])
        store.waitForPendingWrites()

        XCTAssertEqual(store.snapshot().projects.map(\.key).sorted(), full.map(\.key).sorted())
    }

    /// The ignore list could not be written (review, 2026-09-29): the
    /// deletion is not written without it, the store says so, and the next
    /// write tries again, so a relaunch never lifts the opt-out silently.
    func testAnIgnoreListThatCouldNotBeWrittenIsRetriedAndNeverLiftedSilently() throws {
        let fileURL = makeFileURL()
        let listWriteFails = Mutex(false)
        let store = LearnedTermStore(
            fileURL: fileURL, now: { Self.start },
            writeIgnoredList: { data, url in
                if listWriteFails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try LearnedTermStore.writeFile(data, to: url)
            })
        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        store.record(observations("Kern"), project: mac)
        store.waitForPendingWrites()
        listWriteFails.withLock { $0 = true }

        store.ignoreProject(key: quill.key, name: "quill", keys: [mac.key])
        store.waitForPendingWrites()

        XCTAssertTrue(store.snapshot().projects.isEmpty, "this session keeps it out")
        XCTAssertTrue(store.ignoredListUnsaved, "Settings says it is not saved")
        let onDisk = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: Data(contentsOf: fileURL)).value)
        XCTAssertEqual(onDisk.projects.map(\.key), [mac.key], "no deletion on disk without its ignore entry")

        listWriteFails.withLock { $0 = false }
        store.record(observations("Inkwell"), project: .init(key: "/w/ink", name: "ink"))
        store.waitForPendingWrites()
        XCTAssertFalse(store.ignoredListUnsaved)

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().ignored.projects.map(\.key), [quill.key], "the next write saved the list")
        XCTAssertEqual(reopened.snapshot().projects.map(\.key), ["/w/ink"])
    }

    /// Two running copies of the app (#990): each ignore applies to the
    /// list the other wrote, and a copy that never ignored the repo itself
    /// records nothing for it once the other has.
    func testTwoRunningCopiesKeepEachOthersIgnores() throws {
        let fileURL = makeFileURL()
        let first = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let second = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        first.waitForPendingWrites()
        second.waitForPendingWrites()

        first.ignoreProject(key: quill.key, name: "quill", keys: [mac.key])
        first.waitForPendingWrites()
        second.ignoreProject(key: "/w/notes", name: "notes", keys: [])
        second.waitForPendingWrites()
        second.record(observations("Kern"), project: mac)
        second.waitForPendingWrites()
        first.unignoreProject(key: "/w/missing")
        first.waitForPendingWrites()

        XCTAssertEqual(second.snapshot().ignored.projects.map(\.key), [quill.key, "/w/notes"])
        XCTAssertTrue(second.snapshot().projects.isEmpty, "the other copy's ignore keeps the repo out")
        XCTAssertEqual(first.snapshot().ignored.projects.map(\.key), [quill.key, "/w/notes"])
        let onDisk = try XCTUnwrap(
            LearnedTermStore.ignored(fromFileContents: Data(contentsOf: XCTUnwrap(first.ignoredFileURL))).value)
        XCTAssertEqual(onDisk.projects.map(\.key), [quill.key, "/w/notes"])
        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().ignored.projects.map(\.key), [quill.key, "/w/notes"])
        XCTAssertTrue(reopened.snapshot().projects.isEmpty)
    }

    /// Another copy un-ignores a repo and records a correction there while
    /// this copy is between reading the list and updating the terms
    /// (review, 2026-10-01). The list's lock is held across both, so the
    /// other copy waits, and this copy's sweep never deletes the correction.
    func testAnUnignoreByAnotherCopyDuringAWriteKeepsItsCorrection() throws {
        let fileURL = makeFileURL()
        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        let other = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        other.ignoreProject(key: quill.key, name: "quill", keys: [mac.key])
        other.waitForPendingWrites()
        let ignoredURL = try XCTUnwrap(other.ignoredFileURL)
        let armed = Mutex(false)
        let ranMidWrite = Mutex(false)
        let quillKey = quill.key
        let otherWrites: @Sendable () -> Void = {
            other.unignoreProject(key: quillKey)
            other.recordCorrection("Kern", project: mac)
            other.waitForPendingWrites()
        }
        let store = LearnedTermStore(
            fileURL: fileURL, now: { Self.start },
            beforeTermsUpdate: {
                guard armed.withLock({ armed in defer { armed = false }; return armed }) else { return }
                // The other copy can write only while this one leaves the list free.
                guard StoredFileLock.tryHolding(beside: ignoredURL) != nil else { return }
                otherWrites()
                ranMidWrite.withLock { $0 = true }
            })
        store.waitForPendingWrites()

        armed.withLock { $0 = true }
        store.record(observations("Inkwell"), project: .init(key: "/w/ink", name: "ink"))
        store.waitForPendingWrites()
        if !ranMidWrite.withLock({ $0 }) { otherWrites() }

        let onDisk = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: Data(contentsOf: fileURL)).value)
        XCTAssertEqual(
            onDisk.projects.first { $0.key == mac.key }?.terms.map(\.term), ["Kern"],
            "the other copy's correction stays")
        XCTAssertNotNil(onDisk.projects.first { $0.key == "/w/ink" })
    }

    /// An ignore whose write failed, then another copy's write to the list,
    /// then this copy's next write (review, 2026-10-01): the failed ignore
    /// is replayed onto the other copy's list, so neither is lost.
    func testAnIgnoreWhoseWriteFailedSurvivesAnotherCopysWrite() throws {
        let fileURL = makeFileURL()
        let listWriteFails = Mutex(false)
        let first = LearnedTermStore(
            fileURL: fileURL, now: { Self.start },
            writeIgnoredList: { data, url in
                if listWriteFails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try LearnedTermStore.writeFile(data, to: url)
            })
        let second = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        first.waitForPendingWrites()
        second.waitForPendingWrites()

        listWriteFails.withLock { $0 = true }
        first.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill"])
        first.waitForPendingWrites()
        XCTAssertTrue(first.ignoredListUnsaved)
        second.ignoreProject(key: "/w/notes", name: "notes", keys: [])
        second.waitForPendingWrites()
        listWriteFails.withLock { $0 = false }
        first.record(observations("Inkwell"), project: .init(key: "/w/ink", name: "ink"))
        first.waitForPendingWrites()

        XCTAssertFalse(first.ignoredListUnsaved)
        let onDisk = try XCTUnwrap(
            LearnedTermStore.ignored(fromFileContents: Data(contentsOf: XCTUnwrap(first.ignoredFileURL))).value)
        XCTAssertEqual(onDisk.projects.map(\.key).sorted(), ["/w/notes", quill.key].sorted())
    }

    func testUnignoreLetsTheNextDictationRecordIt() {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        store.ignoreProject(key: quill.key, name: "quill", keys: [mac.key])
        for _ in 0..<3 { store.record(observations("Kern"), project: mac) }
        store.waitForPendingWrites()
        XCTAssertTrue(store.snapshot().projects.isEmpty)

        store.unignoreProject(key: quill.key)
        for _ in 0..<3 { store.record(observations("Kern"), project: mac) }
        store.waitForPendingWrites()
        XCTAssertTrue(store.snapshot().ignored.projects.isEmpty)
        XCTAssertEqual(store.confirmedTerms(projectKey: mac.key), ["Kern"])
        XCTAssertTrue(store.snapshot().needsProposal(projectKey: mac.key, now: Self.start))
    }

    // MARK: The file

    func testTheIgnoreListOutlivesARelaunchAndSweepsAnOlderBuildsRecords() throws {
        let fileURL = makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill"])
        store.waitForPendingWrites()
        let ignoredURL = try XCTUnwrap(store.ignoredFileURL)
        XCTAssertEqual(ignoredURL.lastPathComponent, "ignored-projects.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredURL.path))

        // An older build, which knows no ignore list, recorded it again.
        let older = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: Self.start),
            LearnedTermProject(key: "/w/ink", name: "ink", terms: [term("Inkwell")], lastSeen: Self.start),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(older).write(to: fileURL)

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().ignored.projects.map(\.key), [quill.key])
        XCTAssertEqual(reopened.snapshot().projects.map(\.key), ["/w/ink"])
        let onDisk = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: Data(contentsOf: fileURL)).value)
        XCTAssertEqual(onDisk.projects.map(\.key), ["/w/ink"], "the sweep is written")
        XCTAssertFalse(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("ignored"),
                       "the list stays out of learned-terms.json")
    }

    /// The Projects pane reads the terms' file again when another copy wrote
    /// it (#1126). That file never carries the list, so the reload keeps the
    /// list in memory and sweeps what an older build recorded.
    func testReadingAnotherCopysWriteKeepsTheIgnoreList() async throws {
        let fileURL = makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill"])
        store.waitForPendingWrites()
        let older = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/quill", name: "quill", terms: [term("Kern")], lastSeen: Self.start),
            LearnedTermProject(key: "/w/ink", name: "ink", terms: [term("Inkwell")], lastSeen: Self.start),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(older).write(to: fileURL)

        await store.reloadIfChanged()

        XCTAssertEqual(store.snapshot().ignored.projects.map(\.key), [quill.key])
        XCTAssertEqual(store.snapshot().projects.map(\.key), ["/w/ink"])
        XCTAssertFalse(store.snapshot().needsProposal(projectKey: "/w/quill", now: Self.start))
    }

    private func assertAnUnreadableListKeepsItsBytes(_ contents: Data, problem: StoredFileProblem) async throws {
        let fileURL = makeFileURL()
        let seeded = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        seeded.record(observations("Inkwell"), project: .init(key: "/w/ink", name: "ink"))
        seeded.waitForPendingWrites()
        let termsBytes = try Data(contentsOf: fileURL)
        let ignoredURL = try XCTUnwrap(seeded.ignoredFileURL)
        try contents.write(to: ignoredURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let mac = LearnedTermProjectIdentity(key: "/w/quill", name: "quill")
        store.record(observations("Kern"), project: mac)
        store.ignoreProject(key: quill.key, name: "quill", keys: [mac.key])
        store.unignoreProject(key: quill.key)
        store.forgetProject(keys: ["/w/ink"])
        let proposed = await store.recordCommandProposal(["Kerning"], proposer: "codex", project: mac, excluding: [])
        store.waitForPendingWrites()

        XCTAssertEqual(try Data(contentsOf: ignoredURL), contents, "the list keeps its bytes")
        XCTAssertEqual(try Data(contentsOf: fileURL), termsBytes, "nothing is learned while any repo may be ignored")
        XCTAssertEqual(store.ignoredListProblem, problem)
        XCTAssertNil(store.problem)
        XCTAssertEqual(proposed, [])
        XCTAssertFalse(store.snapshot().needsProposal(projectKey: "/w/new", now: Self.start), "no agent is asked")
        XCTAssertEqual(store.snapshot().projects.map(\.key), ["/w/ink"], "the terms still ground dictation")

        let aside = try await store.moveIgnoredListAsideAndStartOver()
        XCTAssertEqual(try Data(contentsOf: aside), contents)
        XCTAssertNil(store.ignoredListProblem)
        store.record(observations("Kern"), project: mac)
        store.waitForPendingWrites()
        XCTAssertNotNil(store.snapshot().projects.first { $0.key == mac.key }, "learning resumes")
    }

    /// Start Over deletes the original once it is linked aside: without the
    /// lock another copy's write could land in between and be lost (#1432).
    func testStartOverOnTheListRefusesWithoutTheLock() async throws {
        let fileURL = makeFileURL()
        let seeded = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        seeded.waitForPendingWrites()
        let ignoredURL = try XCTUnwrap(seeded.ignoredFileURL)
        let damaged = Data("{ not json".utf8)
        try FileManager.default.createDirectory(at: ignoredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try damaged.write(to: ignoredURL)
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.waitForPendingWrites()
        XCTAssertEqual(store.ignoredListProblem, .unreadable)
        let lockURL = StoredFileLock.lockURL(beside: ignoredURL)
        try? FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        do {
            _ = try await store.moveIgnoredListAsideAndStartOver()
            XCTFail("Start Over moved the list without the lock")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: ignoredURL), damaged)
        XCTAssertEqual(store.ignoredListProblem, .unreadable)
    }

    /// Start Over on a refused learned-terms file keeps the ignore list,
    /// which loaded fine from its own file.
    func testStartingTheTermsOverKeepsTheIgnoreList() async throws {
        let fileURL = makeFileURL()
        let seeded = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        seeded.ignoreProject(key: quill.key, name: "quill", keys: ["/w/quill"])
        seeded.waitForPendingWrites()
        try Data("{ not json".utf8).write(to: fileURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.waitForPendingWrites()
        XCTAssertEqual(store.problem, .unreadable)
        _ = try await store.moveAsideAndStartOver()
        store.record(observations("Kern"), project: .init(key: "/w/quill", name: "quill"))
        store.ignoreProject(key: "/w/notes", name: "notes", keys: [])
        store.waitForPendingWrites()

        XCTAssertTrue(store.snapshot().projects.isEmpty)
        let onDisk = try XCTUnwrap(
            LearnedTermStore.ignored(fromFileContents: Data(contentsOf: XCTUnwrap(store.ignoredFileURL))).value)
        XCTAssertEqual(onDisk.projects.map(\.key), [quill.key, "/w/notes"])
    }

    func testACorruptIgnoreListKeepsItsBytesAndPausesLearning() async throws {
        try await assertAnUnreadableListKeepsItsBytes(Data(#"{"version":1,"projects":[{"key":"#.utf8), problem: .unreadable)
    }

    func testANewerIgnoreListKeepsItsBytesAndPausesLearning() async throws {
        let json = #"{"version":\#(IgnoredProjects.currentVersion + 1),"projects":[]}"#
        try await assertAnUnreadableListKeepsItsBytes(
            Data(json.utf8), problem: .newerVersion(IgnoredProjects.currentVersion + 1))
    }
}
