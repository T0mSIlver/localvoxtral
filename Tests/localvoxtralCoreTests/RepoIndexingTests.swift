import Foundation
import XCTest
@testable import localvoxtralCore

// MARK: - Git-root walk + HEAD/branch parsing (fixture dirs, no git binary)

final class RepoIndexingWalkTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-walk-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsGitRootWalkingUp() {
        let repo = makeTempDir()
        write("ref: refs/heads/main\n", to: repo.appendingPathComponent(".git/HEAD"))
        let deep = repo.appendingPathComponent("sub/deep")
        try! FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let root = RepoIndexing.findGitRoot(startingAt: deep.path)
        XCTAssertEqual(root, repo.standardizedFileURL.path)
    }

    func testFindGitRootReturnsNilOutsideRepo() {
        let dir = makeTempDir()
        XCTAssertNil(RepoIndexing.findGitRoot(startingAt: dir.path))
    }

    func testBranchParsedFromHead() {
        let repo = makeTempDir()
        write("ref: refs/heads/feature/foo\n", to: repo.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(RepoIndexing.branch(root: repo.path), "feature/foo")
    }

    func testDetachedHeadYieldsNilBranch() {
        let repo = makeTempDir()
        write(
            "9fceb02d0ae598e95dc970b74767f19372d61af8\n",
            to: repo.appendingPathComponent(".git/HEAD")
        )
        XCTAssertNil(RepoIndexing.branch(root: repo.path))
    }

    func testWorktreeGitdirPointerFollowedToHead() {
        // A linked worktree: `.git` is a FILE pointing at the real gitdir, whose
        // HEAD holds the worktree's branch.
        let mainRepo = makeTempDir()
        let worktreeGitDir = mainRepo.appendingPathComponent(".git/worktrees/wt")
        write("ref: refs/heads/wt-branch\n", to: worktreeGitDir.appendingPathComponent("HEAD"))

        let worktree = makeTempDir()
        write("gitdir: \(worktreeGitDir.path)\n", to: worktree.appendingPathComponent(".git"))

        XCTAssertEqual(
            RepoIndexing.findGitRoot(startingAt: worktree.path),
            worktree.standardizedFileURL.path
        )
        XCTAssertEqual(RepoIndexing.branch(root: worktree.path), "wt-branch")
    }
}

// MARK: - Main checkout of a worktree (#652)

final class RepoIndexingMainCheckoutTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-main-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPlainCheckoutIsItsOwnMainCheckout() {
        let repo = makeTempDir()
        write("ref: refs/heads/main\n", to: repo.appendingPathComponent(".git/HEAD"))

        XCTAssertEqual(RepoIndexing.mainCheckout(ofRoot: repo.path), repo.path)
    }

    /// The layout `git worktree add` writes: a `.git` file naming
    /// `<main>/.git/worktrees/<name>`, whose `commondir` is `../..`.
    func testLinkedWorktreeResolvesToTheMainCheckout() {
        let main = makeTempDir()
        let worktreeGitDir = main.appendingPathComponent(".git/worktrees/wt")
        write("ref: refs/heads/wt\n", to: worktreeGitDir.appendingPathComponent("HEAD"))
        write("../..\n", to: worktreeGitDir.appendingPathComponent("commondir"))

        let inside = main.appendingPathComponent(".claude/worktrees/wt")
        let outside = makeTempDir()
        for worktree in [inside, outside] {
            write("gitdir: \(worktreeGitDir.path)\n", to: worktree.appendingPathComponent(".git"))
            XCTAssertEqual(RepoIndexing.mainCheckout(ofRoot: worktree.path), main.path)
        }
    }

    /// A submodule's `.git` file points into the parent's `.git/modules`, and
    /// that directory is its own common dir: the submodule is its own project.
    func testSubmoduleKeepsItsOwnRoot() {
        let parent = makeTempDir()
        write("ref: refs/heads/main\n", to: parent.appendingPathComponent(".git/HEAD"))
        write(
            "ref: refs/heads/main\n",
            to: parent.appendingPathComponent(".git/modules/vendor/lib/HEAD")
        )
        let submodule = parent.appendingPathComponent("vendor/lib")
        write("gitdir: ../../.git/modules/vendor/lib\n", to: submodule.appendingPathComponent(".git"))

        XCTAssertEqual(RepoIndexing.mainCheckout(ofRoot: submodule.path), submodule.path)
    }

    /// A bare repository has no checkout; its worktrees share the bare
    /// directory, which stands for the repository.
    func testWorktreeOfABareRepositoryResolvesToTheSharedGitDirectory() {
        let bare = makeTempDir().appendingPathComponent("api.git")
        let worktreeGitDir = bare.appendingPathComponent("worktrees/feature")
        write("ref: refs/heads/feature\n", to: worktreeGitDir.appendingPathComponent("HEAD"))
        write("../..\n", to: worktreeGitDir.appendingPathComponent("commondir"))
        let worktree = makeTempDir()
        write("gitdir: \(worktreeGitDir.path)\n", to: worktree.appendingPathComponent(".git"))

        XCTAssertEqual(RepoIndexing.mainCheckout(ofRoot: worktree.path), bare.path)
    }

    /// The fixtures above are a claim about git's layout; this checks the
    /// claim against git itself, which the issue names as the reference.
    func testAgreesWithGitRevParseOnARealWorktree() throws {
        let main = makeTempDir().appendingPathComponent("repo")
        let worktree = main.deletingLastPathComponent().appendingPathComponent("repo-wt")
        try git(["init", "-q", main.path])
        try git(["-C", main.path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["-C", main.path, "worktree", "add", "-q", worktree.path])

        let common = try git([
            "-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ])
        let root = try XCTUnwrap(RepoIndexing.findGitRoot(startingAt: worktree.path))
        XCTAssertEqual(
            URL(fileURLWithPath: RepoIndexing.mainCheckout(ofRoot: root)).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: common).deletingLastPathComponent().resolvingSymlinksInPath().path
        )
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ls-files parsing + vocabulary build (synthesized bytes)

final class RepoIndexingParsingTests: XCTestCase {
    func testParsesCleanNullDelimitedPaths() {
        let data = "a/b.ts\u{0}c/d.swift\u{0}".data(using: .utf8)!
        XCTAssertEqual(
            RepoIndexing.parseNullDelimitedPaths(data),
            ["a/b.ts", "c/d.swift"]
        )
    }

    func testDropsTruncatedFinalEntry() {
        // No trailing NUL: the final entry was cut mid-write (timeout/cap).
        let data = "a/b.ts\u{0}c/d.sw".data(using: .utf8)!
        XCTAssertEqual(RepoIndexing.parseNullDelimitedPaths(data), ["a/b.ts"])
    }

    func testCapsAtMaxEntries() {
        let data = "x\u{0}y\u{0}z\u{0}".data(using: .utf8)!
        XCTAssertEqual(
            RepoIndexing.parseNullDelimitedPaths(data, maxEntries: 2),
            ["x", "y"]
        )
    }

    func testEmptyDataYieldsNoPaths() {
        XCTAssertEqual(RepoIndexing.parseNullDelimitedPaths(Data()), [])
    }

    func testBuildVocabularyBasenamesComponentsAndBranch() {
        let vocab = RepoIndexing.buildVocabulary(
            paths: ["useAuth.ts", "Sources/App/UserSessionManager.swift"],
            branch: "feat/repo-vocabulary"
        )
        XCTAssertTrue(vocab.terms.contains("useAuth.ts"))
        XCTAssertTrue(vocab.terms.contains("UserSessionManager.swift"))
        // Bare common-word components carry no technical signal — excluded
        // (they would capitalize ordinary prose as false hints).
        XCTAssertFalse(vocab.terms.contains("Sources"))
        XCTAssertFalse(vocab.terms.contains("App"))
        // A branch with separators is technical and included as a term.
        XCTAssertTrue(vocab.terms.contains("feat/repo-vocabulary"))
        XCTAssertEqual(vocab.branch, "feat/repo-vocabulary")
    }

    func testBuildVocabularyExcludesNonTechnicalTerms() {
        let vocab = RepoIndexing.buildVocabulary(
            paths: [
                "Tests/FooTests.swift",
                "Resources/image.png",
                "docs/readme.txt",
                "Makefile",
            ],
            branch: "main"
        )
        XCTAssertTrue(vocab.terms.contains("FooTests.swift"))
        XCTAssertTrue(vocab.terms.contains("image.png"))
        XCTAssertTrue(vocab.terms.contains("readme.txt"))
        // Common-word components: excluded (would inject `- Tests: tests`
        // style false hints that capitalize ordinary prose).
        XCTAssertFalse(vocab.terms.contains("Tests"))
        XCTAssertFalse(vocab.terms.contains("Resources"))
        XCTAssertFalse(vocab.terms.contains("docs"))
        // Accepted loss (documented in `isTechnicalTerm`): bare names without
        // separators or internal capitals carry no machine-checkable signal.
        XCTAssertFalse(vocab.terms.contains("Makefile"))
        // A plain-word branch is excluded from TERMS but still reported.
        XCTAssertFalse(vocab.terms.contains("main"))
        XCTAssertEqual(vocab.branch, "main")
    }

    func testIsTechnicalTermRule() {
        XCTAssertTrue(RepoIndexing.isTechnicalTerm("useAuth.ts"))          // dot
        XCTAssertTrue(RepoIndexing.isTechnicalTerm("feat/polish-guard"))   // separators
        XCTAssertTrue(RepoIndexing.isTechnicalTerm("snake_case"))          // underscore
        XCTAssertTrue(RepoIndexing.isTechnicalTerm("UserSessionManager"))  // PascalCase
        XCTAssertTrue(RepoIndexing.isTechnicalTerm("useAuth"))             // camelCase
        XCTAssertFalse(RepoIndexing.isTechnicalTerm("Tests"))              // leading cap only
        XCTAssertFalse(RepoIndexing.isTechnicalTerm("Resources"))
        XCTAssertFalse(RepoIndexing.isTechnicalTerm("docs"))               // all lowercase
        XCTAssertFalse(RepoIndexing.isTechnicalTerm("LICENSE"))            // all caps, no lower
        XCTAssertFalse(RepoIndexing.isTechnicalTerm("Makefile"))           // accepted loss
    }
}
