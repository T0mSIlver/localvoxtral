import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// An in-memory tree. Every collector test runs against this rather than a
/// temp directory: the repo's convention is injected seams, and a real
/// filesystem would make "does a deadline stop the reads" a wall-clock test.
private final class FakeFileSystem: ClaudeLocalFileReading, @unchecked Sendable {
    /// Absolute path -> contents.
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    /// Paths that a real `attributesOfItem` would report as `typeSymbolicLink`
    /// rather than a directory — the collector must refuse to walk THROUGH one.
    var symlinkedDirectories: Set<String> = []
    private(set) var reads: [String] = []

    func add(_ path: String, _ contents: String) {
        files[path] = Data(contents.utf8)
        addAncestorDirectories(of: path)
    }

    func addBinary(_ path: String, _ bytes: [UInt8]) {
        files[path] = Data(bytes)
        addAncestorDirectories(of: path)
    }

    /// A real tree has a directory for every path component, and the collector
    /// now checks that. Registering them here keeps the fake a model of a
    /// filesystem rather than a flat dictionary that happens to have slashes in
    /// its keys.
    private func addAncestorDirectories(of path: String) {
        var current = ""
        for component in path.split(separator: "/").dropLast() {
            current += "/" + component
            directories.insert(current)
        }
    }

    func isDirectory(_ path: LocalWorkspacePath) -> Bool {
        // Mirrors `ClaudeLocalFileSystem`, which reads attributes WITHOUT
        // following a final link: a symlink to a directory is not a directory.
        guard !symlinkedDirectories.contains(path.path) else { return false }
        return directories.contains(path.path)
    }

    func isRegularFile(_ path: LocalWorkspacePath) -> Bool {
        guard !symlinkedDirectories.contains(path.path) else { return false }
        return files[path.path] != nil
    }
    func fileSize(_ path: LocalWorkspacePath) -> Int? { files[path.path]?.count }

    func readFile(_ path: LocalWorkspacePath, maxBytes: Int) -> Data? {
        reads.append(path.path)
        guard let data = files[path.path] else { return nil }
        return data.count > maxBytes ? data.prefix(maxBytes) : data
    }
}

/// Scripted `git`. Keyed by the first argument (the subcommand), which is all
/// the collector varies.
private final class FakeGit: @unchecked Sendable {
    var outputs: [String: RepoGitRunner.Output] = [:]
    private(set) var invocations: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []

    func set(_ subcommand: String, _ text: String, exitCode: Int32 = 0) {
        outputs[subcommand] = RepoGitRunner.Output(
            data: Data(text.utf8), exitCode: exitCode, timedOut: false, capped: false
        )
    }

    func setData(_ subcommand: String, _ data: Data, exitCode: Int32 = 0) {
        outputs[subcommand] = RepoGitRunner.Output(
            data: data, exitCode: exitCode, timedOut: false, capped: false
        )
    }

    var run: @Sendable ([String], String, TimeInterval, Int) async -> RepoGitRunner.Output? {
        { [self] arguments, _, timeout, _ in
            invocations.append(arguments)
            timeouts.append(timeout)
            guard let subcommand = arguments.first else { return nil }
            // `diff --cached` and `diff` are different questions.
            let key = arguments.contains("--cached") ? "diff --cached" : subcommand
            return outputs[key]
        }
    }
}

private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(interval) } }
}

/// Collection: what the collector reads, what it refuses to read, and what
/// stops it.
final class ClaudeRepoCollectorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 3_000_000)

    private func workspace(_ path: String = "/repo") throws -> LocalWorkspacePath {
        try XCTUnwrap(
            ClaudeWorkspaceReference.make(
                rawCwd: path, origin: .localAuthenticated(peerUID: 501)
            ).flatMap(\.localPath)
        )
    }

    private func makeCollector(
        files: FakeFileSystem,
        git: FakeGit,
        clock: TestClock? = nil,
        limits: ClaudeRepoCollectorLimits = .default,
        gitRoot: String? = "/repo"
    ) -> ClaudeRepoCollector {
        ClaudeRepoCollector(
            limits: limits,
            files: files,
            now: (clock ?? TestClock(epoch)).now,
            runGit: git.run,
            findGitRoot: { _ in gitRoot }
        )
    }

    // MARK: - The happy path

    func testCollectsStatusDiffsAndTrackedFiles() async throws {
        let files = FakeFileSystem()
        let git = FakeGit()
        git.set("status", " M Sources/App.swift\n?? Notes.md")
        git.set("diff", "diff --git a/Sources/App.swift b/Sources/App.swift\n-old\n+new")
        git.set("diff --cached", "diff --git a/README.md b/README.md\n+staged")
        git.setData("ls-files", Data("Sources/App.swift\0README.md\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.statusLines, [" M Sources/App.swift", "?? Notes.md"])
        XCTAssertTrue(snapshot.unstagedDiff.contains("+new"))
        XCTAssertTrue(snapshot.stagedDiff.contains("+staged"))
        XCTAssertEqual(snapshot.trackedPaths, ["Sources/App.swift", "README.md"])
        XCTAssertEqual(snapshot.provenance.trackedFileCount, 2)
        XCTAssertEqual(snapshot.provenance.statusLineCount, 2)
    }

    // A repo that answers nothing is not context. Attaching an empty fence
    // would spend budget to say nothing.
    func testEmptyRepoYieldsNoSnapshot() async throws {
        let snapshot = await makeCollector(files: FakeFileSystem(), git: FakeGit()).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        XCTAssertNil(snapshot)
    }

    func testNonRepoWorkspaceYieldsNoSnapshotAndRunsNoGit() async throws {
        let git = FakeGit()
        let snapshot = await makeCollector(files: FakeFileSystem(), git: git, gitRoot: nil).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(git.invocations.isEmpty, "no repo means no subprocess at all")
    }

    // MARK: - Active-file prioritization

    // The headline behavior: the files the hooks said the agent just touched
    // are read, in touch order, and carry their touch kind.
    func testActiveFilesFromHookEventsArePrioritizedAndLabeled() async throws {
        let files = FakeFileSystem()
        files.add("/repo/Sources/App.swift", "struct App {}")
        files.add("/repo/Sources/Model.swift", "struct Model {}")
        let git = FakeGit()
        git.setData("ls-files", Data("Sources/App.swift\0Sources/Model.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/repo/Sources/Model.swift", kind: .edited, lastTouched: epoch),
                ClaudeRecentFile(path: "/repo/Sources/App.swift", kind: .read, lastTouched: epoch),
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles.map(\.path), ["Sources/Model.swift", "Sources/App.swift"])
        XCTAssertEqual(snapshot.activeFiles.map(\.touch), [.edited, .read])
        XCTAssertEqual(snapshot.activeFiles.first?.contents, "struct Model {}")
        XCTAssertEqual(snapshot.provenance.activeFileCount, 2)
    }

    // An untracked file the agent just CREATED is the most likely thing the
    // user is about to talk about. Requiring tracked-ness would miss it.
    func testUntrackedButJustEditedFileIsCollected() async throws {
        let files = FakeFileSystem()
        files.add("/repo/New.swift", "struct New {}")
        let git = FakeGit()
        git.setData("ls-files", Data("Old.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/repo/New.swift", kind: .edited, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles.map(\.path), ["New.swift"])
    }

    // A hook path outside the workspace names a file that is not this repo's
    // context — and, for a crafted record, a file we have no business reading.
    func testHookPathsOutsideTheWorkspaceAreNotRead() async throws {
        let files = FakeFileSystem()
        files.add("/etc/passwd", "root:x:0:0")
        files.add("/other/repo/Secret.swift", "secret")
        let git = FakeGit()
        git.setData("ls-files", Data("App.swift\0".utf8))

        let snapshot = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/etc/passwd", kind: .read, lastTouched: epoch),
                ClaudeRecentFile(path: "/other/repo/Secret.swift", kind: .read, lastTouched: epoch),
                ClaudeRecentFile(path: "/repo/../etc/passwd", kind: .read, lastTouched: epoch),
            ],
            transcript: ""
        )
        XCTAssertEqual(snapshot?.activeFiles ?? [], [])
        XCTAssertTrue(files.reads.isEmpty, "a path outside the workspace must never be opened")
    }

    // MARK: - Exclusions

    func testBinaryFilesAreExcluded() async throws {
        let files = FakeFileSystem()
        files.addBinary("/repo/tools/hookd", [0xCF, 0xFA, 0xED, 0xFE, 0x00])
        let git = FakeGit()
        git.setData("ls-files", Data("tools/hookd\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                    ClaudeRecentFile(path: "/repo/tools/hookd", kind: .read, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertEqual(snapshot.provenance.skippedBinary, 1)
    }

    func testGeneratedAndVendoredFilesAreExcluded() async throws {
        let files = FakeFileSystem()
        files.add("/repo/node_modules/left-pad/index.js", "module.exports = 1")
        files.add("/repo/.build/debug/App.o", "object")
        files.add("/repo/Package.resolved", "{}")
        let git = FakeGit()
        git.setData("ls-files", Data("App.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(
                    path: "/repo/node_modules/left-pad/index.js", kind: .read, lastTouched: epoch
                ),
                ClaudeRecentFile(path: "/repo/.build/debug/App.o", kind: .read, lastTouched: epoch),
                ClaudeRecentFile(path: "/repo/Package.resolved", kind: .read, lastTouched: epoch),
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertEqual(snapshot.provenance.skippedGenerated, 3)
        XCTAssertTrue(files.reads.isEmpty, "an excluded path must not even be opened")
    }

    // Logs are counted, never attached: highest-risk, lowest-value text in a
    // tree, and the NAME already tells the model what it is.
    func testLogsAreCountOnly() async throws {
        let files = FakeFileSystem()
        files.add("/repo/build.log", "token=abc123 secret leaked")
        let git = FakeGit()
        git.setData("ls-files", Data("App.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/repo/build.log", kind: .read, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertEqual(snapshot.provenance.skippedLogs, 1)
        XCTAssertTrue(files.reads.isEmpty)
        XCTAssertTrue(
            snapshot.provenance.summary.contains("skip-logs:1"),
            "a silent exclusion is indistinguishable from an empty repo in the field"
        )
    }

    func testSecretActivePathSurvivesAsOnlyFactWithoutReadingBytes() async throws {
        let files = FakeFileSystem()
        files.add("/repo/.env.production", "API_TOKEN=never-attach-this")
        let git = FakeGit()

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(
                    path: "/repo/.env.production", kind: .edited, lastTouched: epoch
                )
            ],
            transcript: "update env production"
        )
        let snapshot = try XCTUnwrap(
            collected,
            "a content-withheld active path must keep an otherwise-empty snapshot alive"
        )
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertEqual(snapshot.secretPaths, [".env.production"])
        XCTAssertEqual(snapshot.provenance.skippedSecrets, 1)
        XCTAssertTrue(snapshot.provenance.summary.contains("skip-secrets:1"))
        XCTAssertTrue(files.reads.isEmpty, "secret-shaped content must not even be opened")

        let prepared = ClaudeRepoContextPreparation.prepare(
            snapshot: snapshot,
            transcript: "update env production",
            renderBudget: 0
        )
        XCTAssertEqual(prepared.grounding.entries.first?.replaceWith, ".env.production")
        XCTAssertFalse(prepared.grounding.isFallbackOnly)
    }

    // A symlink is not a regular file. Lexical containment says where the NAME
    // points, not the inode — a tracked link to ~/.ssh/id_rsa is legal to have.
    func testSymlinksAreNotFollowed() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lvx-repo-symlink-\(UUID().uuidString)", isDirectory: true)
        let repo = parent.appendingPathComponent("repo", isDirectory: true)
        let secret = parent.appendingPathComponent("secret.txt")
        let link = repo.appendingPathComponent("link.swift")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("never-attach-this-secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        defer { try? FileManager.default.removeItem(at: parent) }

        let git = FakeGit()
        git.setData("ls-files", Data("link.swift\0".utf8))
        let collector = ClaudeRepoCollector(
            files: ClaudeLocalFileSystem(),
            now: TestClock(epoch).now,
            runGit: git.run,
            findGitRoot: { _ in repo.path }
        )

        let collected = await collector.collect(
            workspace: try workspace(repo.path),
            recentFiles: [
                ClaudeRecentFile(path: link.path, kind: .read, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertFalse(snapshot.provenance.deadlineExpired, "the test must reach the file check")
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertFalse(
            ClaudeRepoContextSelection.groundingText(snapshot: snapshot)
                .contains("never-attach-this-secret")
        )
    }

    func testIntermediateDirectorySymlinkOutsideRepoIsNotFollowed() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lvx-repo-dir-symlink-\(UUID().uuidString)", isDirectory: true)
        let repo = parent.appendingPathComponent("repo", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let link = repo.appendingPathComponent("linked", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("OutsideConfig.swift")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("never-attach-outside-directory-content".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: parent) }

        let git = FakeGit()
        git.setData("ls-files", Data("linked/OutsideConfig.swift\0".utf8))
        let collector = ClaudeRepoCollector(
            files: ClaudeLocalFileSystem(),
            now: TestClock(epoch).now,
            runGit: git.run,
            findGitRoot: { _ in repo.path }
        )
        let collected = await collector.collect(
            workspace: try workspace(repo.path),
            recentFiles: [
                ClaudeRecentFile(
                    path: link.appendingPathComponent("OutsideConfig.swift").path,
                    kind: .read,
                    lastTouched: epoch
                )
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles, [])
        XCTAssertEqual(snapshot.provenance.skippedUncontained, 1)
        XCTAssertFalse(
            ClaudeRepoContextSelection.groundingText(snapshot: snapshot)
                .contains("never-attach-outside-directory-content")
        )
    }

    // MARK: - Caps

    func testOversizedFilesAreTruncatedAndSayThatTheyAre() async throws {
        var limits = ClaudeRepoCollectorLimits.default
        limits.maxFileBytes = 100
        limits.truncatedFileBytes = 20
        let files = FakeFileSystem()
        files.add("/repo/Big.swift", String(repeating: "x", count: 500))
        let git = FakeGit()
        git.setData("ls-files", Data("Big.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git, limits: limits).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/repo/Big.swift", kind: .edited, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        let file = try XCTUnwrap(snapshot.activeFiles.first)
        XCTAssertEqual(file.contents.count, 20)
        XCTAssertTrue(file.isTruncated)
        // Truncated is ATTACHED, not skipped. Reporting it as a skip would make
        // a field log claim the file was dropped when its head is in the prompt.
        XCTAssertEqual(snapshot.provenance.truncatedFiles, 1)
        XCTAssertTrue(snapshot.provenance.summary.contains("truncated:1"))
        XCTAssertFalse(snapshot.provenance.summary.contains("skip"))
    }

    func testActiveFileCountIsCapped() async throws {
        var limits = ClaudeRepoCollectorLimits.default
        limits.maxActiveFiles = 2
        let files = FakeFileSystem()
        var recents: [ClaudeRecentFile] = []
        for index in 0..<10 {
            files.add("/repo/File\(index).swift", "struct F\(index) {}")
            recents.append(
                ClaudeRecentFile(path: "/repo/File\(index).swift", kind: .read, lastTouched: epoch)
            )
        }
        let git = FakeGit()
        git.setData("ls-files", Data("File0.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git, limits: limits).collect(
            workspace: try workspace(), recentFiles: recents, transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles.count, 2)
    }

    // MARK: - Deadline

    // A repo that is slow to answer yields a SMALLER snapshot, never a late
    // one. The clock is injected; nothing here sleeps.
    func testDeadlineStopsCollectionAndIsReported() async throws {
        let clock = TestClock(epoch)
        var limits = ClaudeRepoCollectorLimits.default
        limits.deadline = 1.0
        let files = FakeFileSystem()
        files.add("/repo/App.swift", "struct App {}")
        let git = FakeGit()
        git.set("status", " M App.swift")
        // Every git call burns the whole deadline.
        let slowGit = FakeGit()
        slowGit.outputs = git.outputs
        let collector = ClaudeRepoCollector(
            limits: limits,
            files: files,
            now: clock.now,
            runGit: { arguments, root, timeout, maxBytes in
                clock.advance(2.0)
                return await slowGit.run(arguments, root, timeout, maxBytes)
            },
            findGitRoot: { _ in "/repo" }
        )
        let collected = await collector.collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(path: "/repo/App.swift", kind: .edited, lastTouched: epoch)
            ],
            transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertTrue(snapshot.provenance.deadlineExpired)
        XCTAssertEqual(
            snapshot.activeFiles, [],
            "an expired deadline must stop file reads, not merely be recorded"
        )
        XCTAssertTrue(files.reads.isEmpty)
    }

    // A git call started just before the deadline must not run for its full
    // per-call timeout.
    func testPerCallGitTimeoutNeverOutlivesTheDeadline() async throws {
        let clock = TestClock(epoch)
        var limits = ClaudeRepoCollectorLimits.default
        limits.deadline = 0.5
        limits.gitTimeout = 5.0
        let git = FakeGit()
        git.set("status", " M App.swift")
        _ = await makeCollector(
            files: FakeFileSystem(), git: git, clock: clock, limits: limits
        ).collect(workspace: try workspace(), recentFiles: [], transcript: "")
        let first = try XCTUnwrap(git.timeouts.first)
        XCTAssertLessThanOrEqual(first, 0.5)
    }

    // MARK: - Git argument shape

    // `-C <root>` is added by the runner, so no caller can aim git elsewhere;
    // and the diff must never invoke a user-configured external differ.
    func testDiffRefusesExternalDiffPrograms() async throws {
        let git = FakeGit()
        git.set("status", " M App.swift")
        _ = await makeCollector(files: FakeFileSystem(), git: git).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        let diffCalls = git.invocations.filter { $0.first == "diff" }
        XCTAssertFalse(diffCalls.isEmpty)
        for call in diffCalls {
            XCTAssertTrue(call.contains("--no-ext-diff"))
            XCTAssertTrue(call.contains("--no-color"))
        }
    }

    // A clean non-zero exit is a real failure (not a repo, git error): skip it
    // rather than treat stderr-shaped noise as content.
    func testNonZeroGitExitIsSkipped() async throws {
        let git = FakeGit()
        git.set("status", "fatal: not a git repository", exitCode: 128)
        git.setData("ls-files", Data("App.swift\0".utf8))
        let collected = await makeCollector(files: FakeFileSystem(), git: git).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.statusLines, [])
    }

    // A diff containing raw bytes must not be pasted into a prompt.
    func testBinaryDiffIsDropped() async throws {
        let git = FakeGit()
        git.setData("diff", Data([0x64, 0x69, 0x66, 0x66, 0x00, 0xFF]))
        git.setData("ls-files", Data("App.swift\0".utf8))
        let collected = await makeCollector(files: FakeFileSystem(), git: git).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.unstagedDiff, "")
    }

    // The read path refuses a secret file's BYTES, but a tracked, modified
    // `.env` reaches the prompt anyway through `git diff` — the diff carries
    // the same contents the read filter exists to withhold. The secret file's
    // section must be dropped while an ordinary file's diff survives.
    func testSecretFileDiffSectionsAreWithheldWhileNormalDiffSurvives() async throws {
        let git = FakeGit()
        git.set(
            "diff",
            """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            diff --git a/.env b/.env
            index 3333333..4444444 100644
            --- a/.env
            +++ b/.env
            @@ -1 +1 @@
            -API_TOKEN=old-secret
            +API_TOKEN=new-secret
            """
        )
        git.set(
            "diff --cached",
            """
            diff --git a/config/.env.production b/config/.env.production
            index 5555555..6666666 100644
            --- a/config/.env.production
            +++ b/config/.env.production
            @@ -1 +1 @@
            -DB_PASSWORD=old
            +DB_PASSWORD=hunter2
            """
        )
        git.setData("ls-files", Data("Sources/App.swift\0.env\0config/.env.production\0".utf8))

        let collected = await makeCollector(files: FakeFileSystem(), git: git).collect(
            workspace: try workspace(), recentFiles: [], transcript: ""
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertTrue(snapshot.unstagedDiff.contains("+new"), "the ordinary diff must survive")
        XCTAssertFalse(snapshot.unstagedDiff.contains("API_TOKEN"))
        XCTAssertFalse(snapshot.unstagedDiff.contains(".env"))
        XCTAssertEqual(snapshot.stagedDiff, "", "a diff that is ALL secret withholds everything")
        XCTAssertEqual(snapshot.provenance.withheldDiffFiles, 2)
        XCTAssertTrue(
            snapshot.provenance.summary.contains("diff-withheld:2"),
            "a silent exclusion is indistinguishable from an empty repo in the field"
        )
    }

    // The pure section filter: renames carry the secret's contents under the
    // NEW name, logs are content-withheld for the same reason as reads, and a
    // section whose paths cannot be parsed at all is withheld rather than
    // trusted.
    func testDiffSectionWithholdingCoversRenamesLogsAndFailsClosed() {
        // A rename FROM a secret path leaks old contents under the new name.
        let renamed = ClaudeRepoContentFilter.withholdingSensitiveDiffSections(
            """
            diff --git a/.env b/config/settings.txt
            similarity index 90%
            rename from .env
            rename to config/settings.txt
            --- a/.env
            +++ b/config/settings.txt
            @@ -1 +1 @@
            -API_TOKEN=leak
            +API_TOKEN=leak
            """
        )
        XCTAssertEqual(renamed.withheldFileCount, 1)
        XCTAssertFalse(renamed.text.contains("API_TOKEN"))

        // A log's diff is log content — the read path never attaches it either.
        let log = ClaudeRepoContentFilter.withholdingSensitiveDiffSections(
            """
            diff --git a/build.log b/build.log
            --- a/build.log
            +++ b/build.log
            @@ -1 +1 @@
            +token=abc host=customer-db
            diff --git a/README.md b/README.md
            --- a/README.md
            +++ b/README.md
            @@ -1 +1 @@
            +hello
            """
        )
        XCTAssertEqual(log.withheldFileCount, 1)
        XCTAssertFalse(log.text.contains("customer-db"))
        XCTAssertTrue(log.text.contains("hello"))

        // No parseable path in a section: withhold it, never guess.
        let unparseable = ClaudeRepoContentFilter.withholdingSensitiveDiffSections(
            """
            diff --git "a/\\303\\251 b" "b/\\303\\251 b"
            old mode 100644
            new mode 100755
            """
        )
        XCTAssertEqual(unparseable.withheldFileCount, 1)
        XCTAssertEqual(unparseable.text, "")

        // A file whose CONTENT quotes diff-like lines cannot forge a section
        // boundary: content lines always carry a +/-/space prefix.
        let quoted = ClaudeRepoContentFilter.withholdingSensitiveDiffSections(
            """
            diff --git a/Notes.md b/Notes.md
            --- a/Notes.md
            +++ b/Notes.md
            @@ -1 +1 @@
            +diff --git a/.env b/.env
            """
        )
        XCTAssertEqual(quoted.withheldFileCount, 0)
        XCTAssertTrue(quoted.text.contains("+diff --git a/.env b/.env"))
    }

    // MARK: - Transcript-matched snippets

    func testTranscriptMatchedTrackedFilesAreRead() async throws {
        let files = FakeFileSystem()
        files.add("/repo/Sources/DictationViewModel.swift", "final class DictationViewModel {}")
        files.add("/repo/Sources/Unrelated.swift", "struct Unrelated {}")
        let git = FakeGit()
        git.setData(
            "ls-files",
            Data("Sources/DictationViewModel.swift\0Sources/Unrelated.swift\0".utf8)
        )

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [],
            transcript: "please fix the dictation view model so it stops crashing"
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.trackedFiles.map(\.path), ["Sources/DictationViewModel.swift"])
        XCTAssertEqual(
            snapshot.trackedFiles.first?.contents, "final class DictationViewModel {}"
        )
    }

    // A file already collected as active must not be read a second time as a
    // snippet.
    func testActiveFilesAreNotDuplicatedAsSnippets() async throws {
        let files = FakeFileSystem()
        files.add("/repo/DictationViewModel.swift", "final class DictationViewModel {}")
        let git = FakeGit()
        git.setData("ls-files", Data("DictationViewModel.swift\0".utf8))

        let collected = await makeCollector(files: files, git: git).collect(
            workspace: try workspace(),
            recentFiles: [
                ClaudeRecentFile(
                    path: "/repo/DictationViewModel.swift", kind: .edited, lastTouched: epoch
                )
            ],
            transcript: "the dictation view model"
        )
        let snapshot = try XCTUnwrap(collected)
        XCTAssertEqual(snapshot.activeFiles.count, 1)
        XCTAssertEqual(snapshot.trackedFiles, [])
    }
}

/// The exclusion and selection rules, in isolation.
final class ClaudeRepoContentFilterTests: XCTestCase {
    func testGeneratedComponentsMatchWholeComponentsOnly() {
        XCTAssertTrue(ClaudeRepoContentFilter.isGeneratedOrVendored("node_modules/x/index.js"))
        XCTAssertTrue(ClaudeRepoContentFilter.isGeneratedOrVendored("a/.build/x.o"))
        XCTAssertTrue(ClaudeRepoContentFilter.isGeneratedOrVendored("vendor/lib.go"))
        XCTAssertTrue(ClaudeRepoContentFilter.isGeneratedOrVendored("yarn.lock"))
        XCTAssertTrue(ClaudeRepoContentFilter.isGeneratedOrVendored("assets/logo.png"))
        // Substring matches must NOT exclude: a source directory whose name
        // merely starts with an excluded word is the user's own work.
        XCTAssertFalse(ClaudeRepoContentFilter.isGeneratedOrVendored("src/nodes/graph.ts"))
        XCTAssertFalse(ClaudeRepoContentFilter.isGeneratedOrVendored("Sources/App.swift"))
        XCTAssertFalse(ClaudeRepoContentFilter.isGeneratedOrVendored("builder/Main.swift"))
    }

    func testLogDetection() {
        XCTAssertTrue(ClaudeRepoContentFilter.isLogLike("build.log"))
        XCTAssertTrue(ClaudeRepoContentFilter.isLogLike("logs/run-1.txt"))
        XCTAssertFalse(ClaudeRepoContentFilter.isLogLike("Sources/Log.swift"))
        XCTAssertFalse(ClaudeRepoContentFilter.isLogLike("Logger.swift"))
    }

    func testSecretDetectionCoversCredentialConventionsWithoutHidingSourceFiles() {
        for path in [
            ".env",
            ".env.production",
            ".envrc",
            "config/apiKey.json",
            "config/privateKey.toml",
            "deploy/client-token.yaml",
            "certs/signing.pem",
            ".aws/credentials",
        ] {
            XCTAssertTrue(ClaudeRepoContentFilter.isSecretLike(path), path)
        }
        for path in [
            ".env.example",
            "Sources/SecretsManager.swift",
            "Sources/TokenGuard.swift",
            "config/tokenizer.json",
            "config/keyboard.json",
        ] {
            XCTAssertFalse(ClaudeRepoContentFilter.isSecretLike(path), path)
        }
    }

    func testBinaryDetectionUsesNulBytes() {
        XCTAssertTrue(ClaudeRepoContentFilter.looksBinary(Data([0x41, 0x00, 0x42])))
        XCTAssertFalse(ClaudeRepoContentFilter.looksBinary(Data("plain text".utf8)))
        // A NUL beyond the head window is not detected here — the UTF-8 decode
        // in the collector is the backstop.
        var tail = Data(repeating: 0x41, count: 100)
        tail.append(0x00)
        XCTAssertFalse(ClaudeRepoContentFilter.looksBinary(tail, headBytes: 10))
    }

    func testTranscriptMatchingIsSpokenFormAware() {
        let paths = ["Sources/DictationViewModel.swift", "Sources/App.swift"]
        XCTAssertEqual(
            ClaudeRepoContentFilter.transcriptMatchedPaths(
                trackedPaths: paths,
                excluding: [],
                transcript: "look at the dictation view model",
                limit: 5
            ),
            ["Sources/DictationViewModel.swift"]
        )
    }

    func testShortBasenamesAreNotSelected() {
        // `app.ts` normalizes to `appts` — far too collision-prone with prose
        // to pull a whole file in on.
        XCTAssertEqual(
            ClaudeRepoContentFilter.transcriptMatchedPaths(
                trackedPaths: ["src/app.ts"],
                excluding: [],
                transcript: "the app test is failing",
                limit: 5
            ),
            []
        )
    }

    func testLongestMatchWinsAndSelectionIsDeterministic() {
        let paths = ["Session.swift", "DictationViewModel+Session.swift"]
        let result = ClaudeRepoContentFilter.transcriptMatchedPaths(
            trackedPaths: paths,
            excluding: [],
            transcript: "open dictation view model plus session dot swift",
            limit: 5
        )
        XCTAssertEqual(result.first, "DictationViewModel+Session.swift")
        // Same inputs, same order, every time.
        for _ in 0..<5 {
            XCTAssertEqual(
                result,
                ClaudeRepoContentFilter.transcriptMatchedPaths(
                    trackedPaths: paths,
                    excluding: [],
                    transcript: "open dictation view model plus session dot swift",
                    limit: 5
                )
            )
        }
    }

    func testExcludedPathsAreNeverSelectedAsSnippets() {
        XCTAssertEqual(
            ClaudeRepoContentFilter.transcriptMatchedPaths(
                trackedPaths: ["node_modules/DictationViewModel.swift"],
                excluding: [],
                transcript: "the dictation view model",
                limit: 5
            ),
            []
        )
    }

    // MARK: - Basename forms

    // The extension-less stem is a form in its own right. Without it, matching
    // the whole basename means a speaker has to pronounce "dot swift" to select
    // a file, because `contains` is not a prefix test — which is the entire
    // spoken-form case this selector exists for.
    func testBasenameFormsIncludeTheExtensionLessStem() {
        let forms = ClaudeRepoContentFilter.basenameMatchForms("Sources/DictationViewModel.swift")
        XCTAssertEqual(forms, ["dictationviewmodelswift", "dictationviewmodel"])
    }

    // `+` survives `RepoVocabularyMatcher.normalize` (it strips `.`/`/`/`_`/`-`
    // and nothing else), so a `+` left in the file-side form can never match a
    // transcript. Both spoken readings are emitted; neither is guessed at.
    func testBasenameFormsExpandPlusBothWays() {
        let forms = ClaudeRepoContentFilter.basenameMatchForms("DictationViewModel+Session.swift")
        XCTAssertFalse(
            forms.contains { $0.contains("+") },
            "a form containing `+` is unmatchable against any transcript"
        )
        XCTAssertEqual(
            forms,
            [
                "dictationviewmodelplussessionswift",
                "dictationviewmodelsessionswift",
                "dictationviewmodelplussession",
                "dictationviewmodelsession",
            ],
            "longest first, so the caller's first match is the most specific"
        )
    }

    // Dropping the extension must not smuggle a short stem past the guard: the
    // length rule applies per form, not to the basename it came from.
    func testShortStemsAreExcludedEvenWhenTheBasenameIsLongEnough() {
        // `App.swift` -> `appswift` (8) clears the bar; its stem `app` (3) does
        // not, and must not.
        XCTAssertEqual(ClaudeRepoContentFilter.basenameMatchForms("Sources/App.swift"), ["appswift"])
        XCTAssertEqual(
            ClaudeRepoContentFilter.transcriptMatchedPaths(
                trackedPaths: ["Sources/App.swift"],
                excluding: [],
                transcript: "the app crashed again",
                limit: 5
            ),
            [],
            "a three-letter stem must never select a whole file"
        )
    }

    // The elided reading is not a curiosity: "+" is silent far more often than
    // it is spoken, and before this the file was unmatchable by ANY utterance.
    func testPlusFileIsSelectedWhenThePlusIsNotSpoken() {
        XCTAssertEqual(
            ClaudeRepoContentFilter.transcriptMatchedPaths(
                trackedPaths: ["DictationViewModel+Session.swift"],
                excluding: [],
                transcript: "open dictation view model session",
                limit: 5
            ),
            ["DictationViewModel+Session.swift"]
        )
    }
}
