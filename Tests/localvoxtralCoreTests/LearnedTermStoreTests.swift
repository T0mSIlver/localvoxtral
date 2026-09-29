import XCTest
@testable import localvoxtralCore

/// The file around `LearnedTerms`: what survives a relaunch, what a damaged
/// file costs, and what a project's Forget and Forget All forget.
final class LearnedTermStoreTests: XCTestCase {
    private let project = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/localvoxtral", name: "localvoxtral"
    )
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-terms-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("learned-terms.json")
    }

    private func observations(_ terms: String...) -> [LearnedTermObservation] {
        terms.map { LearnedTermObservation(term: $0, source: .repository) }
    }

    func testRecordedTermsSurviveARelaunch() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        for _ in 0..<3 {
            store.record(observations("Voxtral"), project: project)
        }
        store.waitForPendingWrites()

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.confirmedTerms(projectKey: project.key), ["Voxtral"])
        XCTAssertEqual(reopened.summary().terms, 1)
        XCTAssertEqual(reopened.summary().projects, 1)
    }

    /// Nothing resolved, nothing written: the common case is a sentence the
    /// recognizer got right, and it must not cost a file write.
    func testRecordingNothingWritesNoFile() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.record([], project: project)
        store.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A project's sheet shows a spelling once for all its checkouts, so
    /// its pin and forget reach every checkout that holds it (#972).
    func testPinAndForgetReachEveryCheckoutOfAProject() {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        let remote = LearnedTermProjectResolver.Identity(key: "remote:localvoxtral", name: "localvoxtral")
        let other = LearnedTermProjectResolver.Identity(key: "/Users/t/work/other", name: "other")
        store.record(observations("Voxtral", "Mistral"), project: project)
        store.record(observations("voxtral", "Mistral"), project: remote)
        store.record(observations("Mistral"), project: other)
        let keys = [project.key, remote.key]

        store.setPinned(true, term: "Voxtral", projectKeys: keys)
        store.forget("Mistral", projectKeys: keys)
        store.waitForPendingWrites()

        let byKey = Dictionary(uniqueKeysWithValues: store.snapshot().projects.map { ($0.key, $0.terms) })
        XCTAssertEqual(byKey[project.key]?.map(\.term), ["Voxtral"])
        XCTAssertEqual(byKey[remote.key]?.map(\.term), ["voxtral"])
        XCTAssertEqual(byKey[project.key]?.first?.isPinned, true)
        XCTAssertEqual(byKey[remote.key]?.first?.isPinned, true)
        XCTAssertEqual(byKey[other.key]?.map(\.term), ["Mistral"], "another project keeps its copy")
    }

    /// Forget All in a project's sheet empties that project and no other;
    /// a bucket kept for its proposal stamp stays, empty, so its agent is
    /// not asked again.
    func testForgetTermsEmptiesOnlyThatProject() {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        let other = LearnedTermProjectResolver.Identity(key: "/Users/t/work/other", name: "other")
        store.record(observations("Voxtral", "Mistral"), project: project)
        store.record(observations("Kern"), project: other)
        store.recordProposalFailure(project: project)

        store.forgetTerms(projectKeys: [project.key])
        store.waitForPendingWrites()

        let projects = store.snapshot().projects
        XCTAssertEqual(projects.first { $0.key == project.key }?.terms, [])
        XCTAssertEqual(projects.first { $0.key == other.key }?.terms.map(\.term), ["Kern"])
    }

    /// A torn write or a hand edit starts over empty rather than refusing to
    /// start: losing what was learned costs a few dictations, refusing costs
    /// the feature.
    /// What a worktree learned under its own key, before #652 or through a
    /// hand fix keyed by the session's directory, is filed under the main
    /// checkout when the store loads, and the file says so after a relaunch.
    func testLoadFoldsAWorktreesProjectIntoItsMainCheckout() throws {
        let fileURL = try makeFileURL()
        let base = fileURL.deletingLastPathComponent().standardizedFileURL
        let main = base.appendingPathComponent("repo")
        let gitDir = main.appendingPathComponent(".git/worktrees/wt")
        let worktree = main.appendingPathComponent(".claude/worktrees/wt")
        for directory in [gitDir, worktree] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        let seeded = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        for _ in 0..<3 {
            seeded.record(
                observations("Voxtral"),
                project: .init(key: worktree.path, name: "wt")
            )
        }
        seeded.waitForPendingWrites()

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().projects.map(\.key), [main.path])
        XCTAssertEqual(reopened.confirmedTerms(projectKey: main.path), ["Voxtral"])

        let written = try XCTUnwrap(LearnedTermStore.terms(fromFileContents: try Data(contentsOf: fileURL)).value)
        XCTAssertEqual(written.projects.map(\.key), [main.path])
    }

    /// Was "reads as empty" until #989: an empty read let the next write
    /// replace every spelling, pin and project record.
    func testDamagedFileIsRefusedNotReadAsEmpty() {
        let load = LearnedTermStore.terms(fromFileContents: Data("{ not json".utf8))
        XCTAssertNil(load.value)
        XCTAssertEqual(load.problem, .unreadable)
    }

    /// A file written by a later build is not guessed at, nor discarded
    /// (#989: was "is discarded").
    func testFileFromTheFutureIsRefused() throws {
        let future = LearnedTerms(
            version: LearnedTerms.currentVersion + 1,
            projects: [
                LearnedTermProject(
                    key: project.key,
                    name: project.name,
                    terms: [
                        LearnedTerm(
                            term: "Voxtral", sources: ["repository"], dictations: 9,
                            firstSeen: Self.start, lastSeen: Self.start
                        )
                    ],
                    lastSeen: Self.start
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(future)

        let load = LearnedTermStore.terms(fromFileContents: data)
        XCTAssertNil(load.value)
        XCTAssertEqual(load.problem, .newerVersion(LearnedTerms.currentVersion + 1))
    }

    // MARK: A file this build cannot load (#989)

    private func assertKeepsItsBytes(
        _ contents: Data, problem: StoredFileProblem, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let fileURL = try makeFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.record(observations("Voxtral"), project: project)
        store.recordCorrection("herdr", project: project)
        store.recordOrigin(ProjectRemote(remoteURL: "git@github.com:o/r.git")!, projectKey: project.key)
        store.waitForPendingWrites()

        XCTAssertEqual(try Data(contentsOf: fileURL), contents, "the file keeps its bytes", file: file, line: line)
        XCTAssertEqual(store.problem, problem, file: file, line: line)
        XCTAssertEqual(store.snapshot().termCount, 0, "nothing is held that a relaunch would lose", file: file, line: line)
        let added = await store.recordCommandProposal(
            ["polishd"], proposer: "test", project: LearnedTermProjectIdentity(key: project.key, name: project.name),
            excluding: [])
        XCTAssertEqual(added, [], "a refused proposal still answers", file: file, line: line)
    }

    func testANewerFileKeepsItsBytesAfterAWrite() async throws {
        let json = #"{"version":\#(LearnedTerms.currentVersion + 1),"projects":[{"future":true}]}"#
        try await assertKeepsItsBytes(Data(json.utf8), problem: .newerVersion(LearnedTerms.currentVersion + 1))
    }

    func testACorruptFileKeepsItsBytesAfterAWrite() async throws {
        try await assertKeepsItsBytes(Data(#"{"version":1,"projects":[{"key":"/r""#.utf8), problem: .unreadable)
    }

    /// A try-pr build beside the installed app (#990): each loaded the file
    /// before the other wrote, and each keeps the other's spelling.
    func testTwoRunningCopiesKeepEachOthersTerms() throws {
        let fileURL = try makeFileURL()
        let installed = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        let tryBuild = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        installed.waitForPendingWrites()
        tryBuild.waitForPendingWrites()

        installed.recordCorrection("Voxtral", project: project)
        installed.waitForPendingWrites()
        tryBuild.recordCorrection("Mistral", project: project)
        tryBuild.waitForPendingWrites()
        installed.recordCorrection("Tekken", project: project)
        installed.waitForPendingWrites()

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(
            Set(reopened.confirmedTerms(projectKey: project.key)), ["Voxtral", "Mistral", "Tekken"])
    }

    /// A newer build running beside this one rewrote the file in its format:
    /// this copy's next change is refused and the file keeps its bytes (#990).
    func testACopyThatFindsANewerFileSinceItLoadedRefusesToWrite() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.recordCorrection("Voxtral", project: project)
        store.waitForPendingWrites()
        let newer = Data(#"{"version":\#(LearnedTerms.currentVersion + 1),"projects":[]}"#.utf8)
        try newer.write(to: fileURL)

        store.recordCorrection("Mistral", project: project)
        store.waitForPendingWrites()

        XCTAssertEqual(try Data(contentsOf: fileURL), newer)
        XCTAssertEqual(store.problem, .newerVersion(LearnedTerms.currentVersion + 1))
    }

    /// Start Over moves the refused file beside itself, next to an earlier
    /// one, and the store writes again.
    func testStartOverMovesTheFileAsideAndWritesAgain() async throws {
        let fileURL = try makeFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: fileURL)
        let earlier = directory.appendingPathComponent("learned-terms.json.unreadable")
        try Data("earlier".utf8).write(to: earlier)

        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.waitForPendingWrites()
        let aside = try await store.moveAsideAndStartOver()

        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        XCTAssertEqual(try Data(contentsOf: earlier), Data("earlier".utf8))
        XCTAssertNil(store.problem)
        for _ in 0..<3 { store.record(observations("Voxtral"), project: project) }
        store.waitForPendingWrites()
        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.confirmedTerms(projectKey: project.key), ["Voxtral"])
    }

    /// The store is also the read side of the feature, so what it hands back
    /// has to be the confirmed set, not everything it has ever seen.
    func testUnconfirmedTermsAreNotHandedOut() throws {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        store.record(observations("Voxtral", "polishd"), project: project)
        store.record(observations("Voxtral"), project: project)
        store.waitForPendingWrites()

        XCTAssertTrue(store.confirmedTerms(projectKey: project.key).isEmpty)
        XCTAssertEqual(store.confirmedTerms(projectKey: project.key, minimumDictations: 2), ["Voxtral"])
    }
}
