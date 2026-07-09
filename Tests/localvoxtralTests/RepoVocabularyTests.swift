import Foundation
import XCTest
@testable import localvoxtral

// MARK: - Terminal window-title parser

final class TerminalWorkingDirectoryResolverTests: XCTestCase {
    private let home = "/Users/tester"

    private func candidates(_ title: String) -> [String] {
        TerminalWorkingDirectoryResolver.workingDirectoryCandidates(
            fromWindowTitle: title, homeDirectory: home
        )
    }

    func testAbsolutePathWithShellDecoration() {
        XCTAssertEqual(candidates("/Users/x/dev/proj — zsh"), ["/Users/x/dev/proj"])
    }

    func testTildePathIsExpanded() {
        XCTAssertEqual(candidates("~/dev/proj"), ["/Users/tester/dev/proj"])
    }

    func testBareTildeExpandsToHome() {
        XCTAssertEqual(candidates("~"), ["/Users/tester"])
    }

    func testTerminalDotAppBareNameIsRejected() {
        // "proj — zsh — 80×24": a bare last-path-component is not resolvable.
        XCTAssertEqual(candidates("proj — zsh — 80×24"), [])
    }

    func testITerm2UserHostStyle() {
        XCTAssertEqual(candidates("user@host: ~/dev/proj"), ["/Users/tester/dev/proj"])
    }

    func testEditorDecorationAndBoxDimensions() {
        XCTAssertEqual(candidates("/a — vim (80×24)"), ["/a"])
    }

    func testTrailingCommaTrimmed() {
        XCTAssertEqual(candidates("~/dev/proj,"), ["/Users/tester/dev/proj"])
    }

    func testBoxDimensionsOnlyYieldNoCandidate() {
        XCTAssertEqual(candidates("80×24"), [])
    }

    func testMultipleCandidatesInOrderOfAppearance() {
        XCTAssertEqual(
            candidates("host: ~/a and /b/c done"),
            ["/Users/tester/a", "/b/c"]
        )
    }

    func testDeduplicatesRepeatedCandidates() {
        XCTAssertEqual(candidates("/x/y and /x/y"), ["/x/y"])
    }

    func testResolveReturnsFirstExistingDirectory() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "cd /nope then ~/yes",
            homeDirectory: home,
            isDirectory: { $0 == "/Users/tester/yes" }
        )
        XCTAssertEqual(resolved, "/Users/tester/yes")
    }

    func testResolveReturnsNilWhenNoneExist() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "/a /b",
            homeDirectory: home,
            isDirectory: { _ in false }
        )
        XCTAssertNil(resolved)
    }
}

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

// MARK: - TTL cache (injected clock + mtime)

final class RepoVocabularyCacheTests: XCTestCase {
    private let vocab = RepoVocabulary(terms: ["useAuth.ts"], branch: "main")

    func testHitWithinTTLAndUnchangedHead() {
        let cache = RepoVocabularyCache(ttl: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        let head = Date(timeIntervalSince1970: 500)
        cache.insert(root: "/r", vocabulary: vocab, headModificationDate: head, now: start)

        let hit = cache.lookup(
            root: "/r",
            now: start.addingTimeInterval(299),
            currentHeadModificationDate: head
        )
        XCTAssertEqual(hit, vocab)
    }

    func testMissAfterTTLExpiry() {
        let cache = RepoVocabularyCache(ttl: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        let head = Date(timeIntervalSince1970: 500)
        cache.insert(root: "/r", vocabulary: vocab, headModificationDate: head, now: start)

        let miss = cache.lookup(
            root: "/r",
            now: start.addingTimeInterval(301),
            currentHeadModificationDate: head
        )
        XCTAssertNil(miss)
    }

    func testMissWhenHeadMTimeChanged() {
        let cache = RepoVocabularyCache(ttl: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        cache.insert(
            root: "/r",
            vocabulary: vocab,
            headModificationDate: Date(timeIntervalSince1970: 500),
            now: start
        )

        let miss = cache.lookup(
            root: "/r",
            now: start,
            currentHeadModificationDate: Date(timeIntervalSince1970: 600)
        )
        XCTAssertNil(miss)
    }
}

// MARK: - Matcher

final class RepoVocabularyMatcherTests: XCTestCase {
    private func entries(_ transcript: String, terms: [String]) -> [ReplacementEntry] {
        RepoVocabularyMatcher.candidateEntries(
            transcript: transcript,
            vocabulary: RepoVocabulary(terms: terms, branch: nil)
        )
    }

    func testCanonicalUseAuthExample() {
        let result = entries("open use auth dot t s and fix the import", terms: ["useAuth.ts"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "useAuth.ts")
        XCTAssertEqual(result.first?.matches, ["use auth dot t s"])
    }

    func testCanonicalUserSessionManagerExample() {
        let result = entries(
            "rename the user session manager dot swift file",
            terms: ["UserSessionManager.swift"]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "UserSessionManager.swift")
        XCTAssertEqual(result.first?.matches, ["user session manager dot swift"])
    }

    func testEditDistanceOneNearMiss() {
        // "use auth s" -> "useauths" (8), one deletion from "useauthts".
        let result = entries("please use auth s now", terms: ["useAuth.ts"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "useAuth.ts")
    }

    func testShortFormTermsRejected() {
        // Bare "app"/"src" normalize to < 4 chars: no standalone entries.
        XCTAssertTrue(entries("open the app and src", terms: ["app", "src"]).isEmpty)
    }

    func testShortComponentCountsInsideLongerNGram() {
        // "app" alone is too short, but "app dot t s x" -> "apptsx" matches app.tsx.
        let result = entries("edit app dot t s x here", terms: ["app.tsx"])
        XCTAssertEqual(result.first?.replaceWith, "app.tsx")
    }

    func testPureStopwordNGramsRejected() {
        // "the file" is all stopwords: never a file match even if it normalizes
        // to a real term.
        XCTAssertTrue(entries("open the file now", terms: ["thefile"]).isEmpty)
    }

    func testEntryCapAtTwelve() {
        let terms = (0..<15).map { "alphafile\(String(format: "%02d", $0))" }
        let transcript = terms.joined(separator: " ")
        XCTAssertEqual(entries(transcript, terms: terms).count, 12)
    }

    func testRankingLongerNormalizedFirst() {
        let result = entries("config configuration", terms: ["config", "configuration"])
        XCTAssertEqual(result.map(\.replaceWith), ["configuration", "config"])
    }

    func testPromptSectionRendersDictionaryShape() {
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot t s"]),
        ])
        XCTAssertTrue(section.contains("Repository vocabulary"))
        XCTAssertTrue(section.contains("- useAuth.ts: use auth dot t s"))
    }

    func testAppendedSectionStandsAloneWhenBaseEmpty() {
        let appended = RepoVocabularyMatcher.appendedPromptSection(
            base: "",
            entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth"])]
        )
        XCTAssertTrue(appended.hasPrefix("Repository vocabulary"))
    }

    func testAppendedSectionUnchangedWithNoEntries() {
        XCTAssertEqual(
            RepoVocabularyMatcher.appendedPromptSection(base: "Replacement dictionary:\n- x: y", entries: []),
            "Replacement dictionary:\n- x: y"
        )
    }

    func testPromptSectionSanitizesEmbeddedNewlineIntoSingleLine() {
        // `git ls-files -z` preserves newlines in file names; the rendered
        // dictionary line must stay a single intact `- key: aliases` line.
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "use\nAuth.ts", matches: ["use auth dot t s"]),
        ])
        let entryLines = section.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(entryLines.count, 1)
        XCTAssertEqual(entryLines.first, "- useAuth.ts: use auth dot t s")
    }

    func testPromptSectionStripsControlCharactersFromAliases() {
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "ok.ts", matches: ["use\u{0007}\tok"]),
        ])
        XCTAssertTrue(section.contains("- ok.ts: useok"))
    }

    func testPromptSectionDropsUnrenderableEntries() {
        // Key empty after sanitization, key reduced to a dash run, and an entry
        // whose every alias sanitizes away: none may render (and with nothing
        // renderable the whole section is empty).
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "\u{0007}\n", matches: ["spoken"]),
            ReplacementEntry(replaceWith: "---", matches: ["spoken"]),
            ReplacementEntry(replaceWith: "ok.ts", matches: ["\n", "\u{0000}"]),
        ])
        XCTAssertEqual(section, "")
    }

    func testCommonComponentWordsDoNotBecomeMatcherEntries() {
        // A repo full of Tests/Resources directories must not turn ordinary
        // prose into capitalization "corrections": the technical-signal gate
        // keeps those components out of the vocabulary entirely.
        let vocab = RepoIndexing.buildVocabulary(
            paths: ["Tests/FooTests.swift", "Resources/image.png"],
            branch: nil
        )
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: "run the tests and update the resources please",
            vocabulary: vocab
        )
        XCTAssertTrue(entries.isEmpty, "entries: \(entries)")
    }

    func testMatcherHandlesLargeVocabulary() {
        // 20k technical terms x a 300-word transcript. No wall-clock assertion
        // (repo rule) — the guarantee is the complexity restructure (exact tier
        // = one index lookup per gram; fuzzy tier = ±1-length buckets swept at
        // most once per distinct gram); this pins CORRECTNESS at that scale and
        // acts as a canary: a return to O(grams x terms) Levenshtein would make
        // it obviously pathological.
        var terms = (0..<20_000).map { "GeneratedFile\($0).swift" }
        terms.append("useAuth.ts")
        let vocab = RepoVocabulary(terms: terms, branch: nil)
        let filler = Array(
            repeating: "please improve overall code quality generally",
            count: 50
        ).joined(separator: " ")
        let transcript = filler + " then open use auth dot t s directly"
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: transcript, vocabulary: vocab
        )
        XCTAssertTrue(entries.contains { $0.replaceWith == "useAuth.ts" })
    }
}

// MARK: - Service orchestration (injected subprocess + fixture .git)

final class RepoVocabularyServiceTests: XCTestCase {
    private func makeFixtureRepo() -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-svc-\(UUID().uuidString)")
        let gitDir = repo.appendingPathComponent(".git")
        try! FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try! "ref: refs/heads/main\n".write(
            to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        return repo
    }

    func testTimedOutRunStillUsesCleanlyReadPartialData() async {
        let repo = makeFixtureRepo()
        // Simulate a killed subprocess: partial, non-clean exit, timedOut flag.
        let output = RepoGitRunner.Output(
            data: "a/b.ts\u{0}c/incomplete".data(using: .utf8)!,
            exitCode: -9,
            timedOut: true,
            capped: false
        )
        let vocab = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path,
            cache: RepoVocabularyCache(),
            runLsFiles: { _ in output }
        )
        // "c/incomplete" is dropped (no trailing NUL); "a/b.ts" survives.
        XCTAssertEqual(vocab?.terms.contains("b.ts"), true)
        XCTAssertEqual(vocab?.branch, "main")
    }

    func testCleanNonZeroExitIsSkipped() async {
        let repo = makeFixtureRepo()
        let output = RepoGitRunner.Output(
            data: Data(), exitCode: 128, timedOut: false, capped: false
        )
        let vocab = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path,
            cache: RepoVocabularyCache(),
            runLsFiles: { _ in output }
        )
        XCTAssertNil(vocab)
    }

    func testCacheHitAvoidsSecondSubprocess() async {
        let repo = makeFixtureRepo()
        let runCount = RunCounter()
        let cache = RepoVocabularyCache()
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 5_000) }
        let run: @Sendable (String) async -> RepoGitRunner.Output? = { _ in
            await runCount.increment()
            return RepoGitRunner.Output(
                data: "useAuth.ts\u{0}".data(using: .utf8)!,
                exitCode: 0, timedOut: false, capped: false
            )
        }

        _ = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path, cache: cache, now: clock, runLsFiles: run
        )
        _ = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path, cache: cache, now: clock, runLsFiles: run
        )
        let count = await runCount.value
        XCTAssertEqual(count, 1)
    }

    private actor RunCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

// MARK: - Real-git indexer end to end

final class RepoVocabularyIndexerEndToEndTests: XCTestCase {
    @discardableResult
    private func runGit(_ args: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        // Isolate from the developer's global gitconfig / signing / hooks.
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOME"] = directory.path
        process.environment = env
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testHarvestsVocabularyFromRealRepo() async throws {
        // The Mac build host always has /usr/bin/git; use it plainly (no skip).
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(runGit(["init", "-b", "main"], in: repo), 0)
        runGit(["config", "user.email", "test@example.com"], in: repo)
        runGit(["config", "user.name", "Test"], in: repo)
        runGit(["config", "commit.gpgsign", "false"], in: repo)

        try "export const useAuth = () => {}\n".write(
            to: repo.appendingPathComponent("useAuth.ts"), atomically: true, encoding: .utf8
        )
        let nested = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "final class UserSessionManager {}\n".write(
            to: nested.appendingPathComponent("UserSessionManager.swift"),
            atomically: true, encoding: .utf8
        )

        XCTAssertEqual(runGit(["add", "-A"], in: repo), 0)
        XCTAssertEqual(runGit(["commit", "-m", "init"], in: repo), 0)

        let vocab = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path,
            cache: RepoVocabularyCache()
        )
        let terms = try XCTUnwrap(vocab?.terms)
        XCTAssertTrue(terms.contains("useAuth.ts"), "terms: \(terms)")
        XCTAssertTrue(terms.contains("UserSessionManager.swift"), "terms: \(terms)")
        XCTAssertTrue(["main", "master"].contains(vocab?.branch), "branch: \(String(describing: vocab?.branch))")

        // Matching the harvested vocabulary end to end.
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: "open use auth dot t s then user session manager dot swift",
            vocabulary: vocab!
        )
        XCTAssertTrue(entries.contains { $0.replaceWith == "useAuth.ts" })
        XCTAssertTrue(entries.contains { $0.replaceWith == "UserSessionManager.swift" })

        // The full title -> cwd -> vocabulary -> entries pipeline (the exact
        // off-main section the view model runs detached).
        let titleEntries = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(repo.path) — zsh",
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache()
        )
        XCTAssertEqual(titleEntries?.first?.replaceWith, "useAuth.ts")
    }

    /// Byte-cap path of the real subprocess runner: a tiny `maxBytes` trips the
    /// cap on the first read, the runner marks `capped` (not `timedOut`) and
    /// still returns the bytes read so far. This exercises the restructured
    /// wait logic where the cap path must NOT re-wait on the reader semaphore
    /// (the reader already exited and its signal was consumed by the first
    /// wait). The remaining branch — a genuine 2 s TIMEOUT with a live reader —
    /// needs `ls-files` to stall mid-stream, which cannot be arranged
    /// deterministically without wall-clock waits, so it stays covered by the
    /// stubbed-Output service tests instead.
    func testLsFilesByteCapMarksCappedAndKeepsData() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(runGit(["init", "-b", "main"], in: repo), 0)
        runGit(["config", "user.email", "test@example.com"], in: repo)
        runGit(["config", "user.name", "Test"], in: repo)
        runGit(["config", "commit.gpgsign", "false"], in: repo)
        for index in 0..<5 {
            try "x\n".write(
                to: repo.appendingPathComponent("file-\(index).txt"),
                atomically: true, encoding: .utf8
            )
        }
        XCTAssertEqual(runGit(["add", "-A"], in: repo), 0)
        XCTAssertEqual(runGit(["commit", "-m", "init"], in: repo), 0)

        let rawOutput = await RepoGitRunner.lsFiles(
            root: repo.path, timeoutSeconds: 2.0, maxBytes: 4
        )
        let output = try XCTUnwrap(rawOutput)
        XCTAssertTrue(output.capped)
        XCTAssertFalse(output.timedOut)
        XCTAssertGreaterThanOrEqual(output.data.count, 4)
        // Whatever was read parses without error (complete entries only; a
        // truncated tail is dropped by design).
        _ = RepoIndexing.parseNullDelimitedPaths(output.data)
    }
}
