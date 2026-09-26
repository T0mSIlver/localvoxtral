@testable import ClaudeContextWire
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

    func testWindowTitleCandidates() {
        let cases: [(name: String, title: String, expected: [String])] = [
            ("AbsolutePathWithShellDecoration", "/Users/x/dev/proj — zsh", ["/Users/x/dev/proj"]),
            ("TildePathIsExpanded", "~/dev/proj", ["/Users/tester/dev/proj"]),
            ("BareTildeExpandsToHome", "~", ["/Users/tester"]),
            // "proj — zsh — 80×24": a bare last-path-component is not resolvable.
            ("TerminalDotAppBareNameIsRejected", "proj — zsh — 80×24", []),
            ("ITerm2UserHostStyle", "user@host: ~/dev/proj", ["/Users/tester/dev/proj"]),
            ("EditorDecorationAndBoxDimensions", "/a — vim (80×24)", ["/a"]),
            ("TrailingCommaTrimmed", "~/dev/proj,", ["/Users/tester/dev/proj"]),
            ("BoxDimensionsOnlyYieldNoCandidate", "80×24", []),
            ("MultipleCandidatesInOrderOfAppearance", "host: ~/a and /b/c done", ["/Users/tester/a", "/b/c"]),
            ("DeduplicatesRepeatedCandidates", "/x/y and /x/y", ["/x/y"]),
        ]
        for (name, title, expected) in cases {
            XCTAssertEqual(candidates(title), expected, name)
        }
    }

    /// `existing` lists the only paths the injected existence check accepts.
    func testResolveWorkingDirectory() {
        let cases: [(name: String, title: String, homeDirectory: String, existing: [String], expected: String?)] = [
            (
                "ResolveReturnsFirstExistingDirectory",
                "cd /nope then ~/yes", home, ["/Users/tester/yes"], "/Users/tester/yes"
            ),
            ("ResolveReturnsNilWhenNoneExist", "/a /b", home, [], nil),
            // The T6 field case (2026-07-11): Ghostty's tab title is exactly
            // "../Desktop/projects/supervoxtral". The extracted absolute run
            // "/Desktop/projects/supervoxtral" does not exist; the home-anchored
            // expansion does and must resolve.
            (
                "GhosttyAbbreviatedTitleResolvesHomeAnchored",
                "../Desktop/projects/supervoxtral",
                "/Users/x",
                ["/Users/x/Desktop/projects/supervoxtral"],
                "/Users/x/Desktop/projects/supervoxtral"
            ),
            // A genuinely absolute path that exists must never be shadowed by its
            // home-anchored twin, even when both exist.
            (
                "ExistingAbsolutePathWinsOverHomeAnchoredTwin",
                "/opt/work/repo", home, ["/opt/work/repo", "\(home)/opt/work/repo"], "/opt/work/repo"
            ),
            // A genuinely absolute path that does not exist locally (an SSH or
            // container path, an unmounted volume) must resolve to NIL — never be
            // re-anchored under home, which would index a same-named local repo and
            // inject wrong-repo vocabulary. Only `../`-prefixed (explicitly elided)
            // titles get home-anchoring.
            ("NonExistentAbsolutePathDoesNotFallBackToHome", "/work/repo — zsh", home, ["\(home)/work/repo"], nil),
            // THE T6 field failure, canonical case (owner-confirmed 2026-07-11):
            // Ghostty's tab title elides with a Unicode HORIZONTAL ELLIPSIS, not
            // ASCII dots — the real title was "…/Desktop/projects/supervoxtral"
            // (reported by typing, which loses the distinction from "../"). The
            // ellipsis-elided title must home-anchor exactly like the ASCII form.
            (
                "T6GhosttyEllipsisElidedTitleResolvesHomeAnchored",
                "…/Desktop/projects/supervoxtral",
                "/Users/owner",
                ["/Users/owner/Desktop/projects/supervoxtral"],
                "/Users/owner/Desktop/projects/supervoxtral"
            ),
            // U+2025 TWO DOT LEADER is accepted as an elision mark too.
            (
                "TwoDotLeaderElidedTitleResolvesHomeAnchored",
                "‥/dev/proj — zsh", home, ["\(home)/dev/proj"], "/Users/tester/dev/proj"
            ),
            ("AbbreviatedTitleWithNothingExistingResolvesNil", "../foo", home, [], nil),
        ]
        for (name, title, homeDirectory, existing, expected) in cases {
            let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
                fromWindowTitle: title,
                homeDirectory: homeDirectory,
                isDirectory: { existing.contains($0) }
            )
            XCTAssertEqual(resolved, expected, name)
        }
    }

    // MARK: - Ghostty-abbreviated titles (leading components elided as `..`)

    /// The canonical T6 case (the `T6GhosttyEllipsisElidedTitleResolvesHomeAnchored`
    /// row of `testResolveWorkingDirectory`) through the PRODUCTION existence
    /// check (no injected predicate — the default real-filesystem one), against
    /// a real temp directory tree, so hermetic test defaults can never mask a
    /// broken production wiring again.
    func testT6GhosttyEllipsisElidedTitleResolvesWithRealFilesystemCheck() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("t6-home-\(UUID().uuidString)").path
        let repo = tempHome + "/Desktop/projects/supervoxtral"
        try FileManager.default.createDirectory(
            atPath: repo, withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempHome) }

        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
                fromWindowTitle: "…/Desktop/projects/supervoxtral",
                homeDirectory: tempHome
            ),
            repo
        )
    }

    func testHomeAnchoredFallbackCandidates() {
        let cases: [(name: String, title: String, expected: [String])] = [
            ("EllipsisFallbackCandidateShape", "…/Desktop/proj — zsh", ["/Users/tester/Desktop/proj"]),
            ("DotDotFallbackCandidateShape", "../Desktop/proj — zsh", ["/Users/tester/Desktop/proj"]),
            // A tilde run is already home-anchored: no fallback is generated.
            ("TildeRunHasNoFallback", "~/dev/proj", []),
            // An absolute run generates NO fallback: only `../` signals elision.
            ("AbsoluteRunHasNoFallback", "/work/repo — zsh", []),
        ]
        for (name, title, expected) in cases {
            XCTAssertEqual(
                TerminalWorkingDirectoryResolver.homeAnchoredFallbackCandidates(
                    fromWindowTitle: title,
                    homeDirectory: home
                ),
                expected,
                name
            )
        }
    }

    // MARK: - Redacted title-shape diagnostic

    /// Letters map to "a", digits to "9", separators/elision marks and spaces
    /// survive, everything else is "?" — never raw content.
    func testTitleShapeClassMapsContent() {
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.titleShape("…/Desktop/projects2 — zsh"),
            "…/aaaaaaa/aaaaaaaa9 ? aaa"
        )
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.titleShape("~/dev.proj"),
            "~/aaa.aaaa"
        )
    }

    func testTitleShapeCapsLength() {
        let shape = TerminalWorkingDirectoryResolver.titleShape(
            String(repeating: "secret", count: 30)
        )
        XCTAssertEqual(shape.count, 60)
        XCTAssertEqual(shape, String(repeating: "a", count: 60))
    }
}

// MARK: - Terminal descendant-process cwd resolver

final class TerminalDescendantProcessResolverTests: XCTestCase {
    private func makeRepo(named name: String) throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-process-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        return repo
    }

    func testNestedDescendantsAgreeOnOneRepoAndUnrelatedProcessIsIgnored() throws {
        let repo = try makeRepo(named: "one")
        let nested = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 100,
            processSnapshot: {
                // Reverse order proves traversal does not depend on snapshot order.
                [
                    .init(pid: 103, parentPID: 102),
                    .init(pid: 999, parentPID: 1),
                    .init(pid: 102, parentPID: 101),
                    .init(pid: 101, parentPID: 100),
                ]
            },
            workingDirectoryForPID: { pid in
                switch pid {
                case 101: repo.path
                case 102, 103: nested.path
                case 999: "/definitely/unrelated"
                default: nil
                }
            }
        )

        XCTAssertEqual(result, .unique(repo.resolvingSymlinksInPath().path))
    }

    func testDifferentRepoDescendantsAreAmbiguous() throws {
        let repoA = try makeRepo(named: "a")
        let repoB = try makeRepo(named: "b")

        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 200,
            processSnapshot: {
                [
                    .init(pid: 201, parentPID: 200),
                    .init(pid: 202, parentPID: 200),
                ]
            },
            workingDirectoryForPID: { $0 == 201 ? repoA.path : repoB.path }
        )

        XCTAssertEqual(result, .ambiguous)
    }

    func testUnreadableDescendantFailsClosedInsteadOfHidingAmbiguity() throws {
        let repo = try makeRepo(named: "readable")

        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 300,
            processSnapshot: {
                [
                    .init(pid: 301, parentPID: 300),
                    .init(pid: 302, parentPID: 300),
                ]
            },
            workingDirectoryForPID: { $0 == 301 ? repo.path : nil }
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testNonRepoDescendantFailsClosedBecauseItCouldBeFocusedTab() throws {
        let repo = try makeRepo(named: "background")
        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 400,
            processSnapshot: {
                [
                    .init(pid: 401, parentPID: 400),
                    .init(pid: 402, parentPID: 400),
                ]
            },
            workingDirectoryForPID: { $0 == 401 ? repo.path : NSTemporaryDirectory() }
        )
        XCTAssertEqual(result, .indeterminate)
    }

    func testNoDescendantsReturnsNone() {
        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 500,
            processSnapshot: { [.init(pid: 999, parentPID: 1)] },
            workingDirectoryForPID: { _ in XCTFail("unrelated cwd must not be read"); return nil }
        )
        XCTAssertEqual(result, .none)
    }

    /// A malformed snapshot with a ppid cycle must terminate rather than loop
    /// forever: pid 101 is a direct child of the terminal, 102's parent is 101,
    /// and a second (malformed) record makes 101's parent ALSO 102 — so 101 and
    /// 102 mutually parent each other. The descendant `Set` breaks the cycle
    /// (a revisit is a non-inserting no-op), the walk halts, and — both cyclic
    /// descendants sharing one repo — the sane result is `.unique`.
    func testCyclicPPIDDataTerminates() throws {
        let repo = try makeRepo(named: "cycle")

        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 100,
            processSnapshot: {
                [
                    .init(pid: 101, parentPID: 100),  // 101 is under the terminal
                    .init(pid: 102, parentPID: 101),  // 102's parent is 101
                    .init(pid: 101, parentPID: 102),  // malformed back-edge: 101's parent is also 102
                ]
            },
            workingDirectoryForPID: { pid in
                [101, 102].contains(pid) ? repo.path : nil
            }
        )

        XCTAssertEqual(result, .unique(repo.resolvingSymlinksInPath().path))
    }

    /// Two descendants whose CWDs are DIFFERENT symlink-alias spellings of the
    /// SAME repo root (the `/var` vs `/private/var` shape, here an explicit
    /// symlink) must collapse to one canonical root and resolve `.unique`, not
    /// be mistaken for two repos (`.ambiguous`). Exercises the
    /// `resolvingSymlinksInPath()` canonicalization in `resolveGitRoot`.
    func testSymlinkAliasCWDsCanonicalizeToUnique() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-symlink-\(UUID().uuidString)")
        let realRepo = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realRepo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let aliasRepo = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: aliasRepo, withDestinationURL: realRepo)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let result = TerminalDescendantProcessResolver.resolveGitRoot(
            terminalApplicationPID: 100,
            processSnapshot: {
                [
                    .init(pid: 101, parentPID: 100),
                    .init(pid: 102, parentPID: 100),
                ]
            },
            workingDirectoryForPID: { pid in
                switch pid {
                case 101: realRepo.path    // real spelling
                case 102: aliasRepo.path   // symlink-alias spelling of the same root
                default: nil
                }
            }
        )

        let expected = URL(fileURLWithPath: realRepo.path)
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(result, .unique(expected))
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

    func testMissWhenDictationFileMTimeChanged() {
        let cache = RepoVocabularyCache(ttl: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        let head = Date(timeIntervalSince1970: 500)
        cache.insert(root: "/r", vocabulary: vocab, headModificationDate: head, now: start)

        let miss = cache.lookup(
            root: "/r",
            now: start,
            currentHeadModificationDate: head,
            currentDictationFileModificationDate: Date(timeIntervalSince1970: 700)
        )
        XCTAssertNil(miss)
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

    func testDictationFileTermsJoinTheVocabularyFirstAndReachTheMatcher() async throws {
        let repo = makeFixtureRepo()
        try writeDictationFile("- Claude Code — the agent\n- `useAuth.ts`\n", repo: repo)
        let vocab = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path,
            cache: RepoVocabularyCache(),
            runLsFiles: { _ in
                RepoGitRunner.Output(
                    data: "src/useAuth.ts\u{0}src/SessionClock.swift\u{0}".data(using: .utf8)!,
                    exitCode: 0, timedOut: false, capped: false
                )
            }
        )
        let terms = try XCTUnwrap(vocab?.terms)
        XCTAssertEqual(Array(terms.prefix(2)), ["Claude Code", "useAuth.ts"])
        XCTAssertEqual(terms.filter { $0 == "useAuth.ts" }.count, 1)
        XCTAssertTrue(terms.contains("SessionClock.swift"))

        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "open clothes code please", vocabulary: try XCTUnwrap(vocab)
        )
        XCTAssertEqual(
            outcome.verificationCandidates,
            [ReplacementEntry(replaceWith: "Claude Code", matches: ["clothes code"])]
        )
    }

    /// An agent that writes a term expects the next dictation to use it, not
    /// one five minutes later when the cache would expire on its own.
    func testEditingTheDictationFileInvalidatesTheCachedVocabulary() async throws {
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

        let before = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path, cache: cache, now: clock, runLsFiles: run
        )
        XCTAssertEqual(before?.terms.contains("Voxtral"), false)

        let file = try writeDictationFile("- Voxtral\n", repo: repo)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_000)], ofItemAtPath: file.path
        )
        let after = await RepoVocabularyService.vocabulary(
            forWorkingDirectory: repo.path, cache: cache, now: clock, runLsFiles: run
        )
        XCTAssertEqual(after?.terms.first, "Voxtral")
        let count = await runCount.value
        XCTAssertEqual(count, 2)
    }

    @discardableResult
    private func writeDictationFile(_ text: String, repo: URL) throws -> URL {
        let github = repo.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        let file = github.appendingPathComponent("dictation.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
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
        XCTAssertEqual(titleEntries?.entries.first?.replaceWith, "useAuth.ts")

        // The resolved root is reported to the caller, which is how a
        // dictation's learned terms are attributed to a project without the
        // commit path walking the filesystem a second time.
        let reportedRoot = RepoVocabularyRootBox()
        _ = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(repo.path) — zsh",
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache(),
            rootSink: { root in reportedRoot.report(root) }
        )
        guard case .root(let reported) = reportedRoot.value else {
            return XCTFail("the pipeline resolved a repo but reported \(reportedRoot.value)")
        }
        XCTAssertEqual(
            URL(fileURLWithPath: reported).standardizedFileURL.path,
            URL(fileURLWithPath: repo.path).standardizedFileURL.path
        )

        // Reporting nil is not the same as staying silent: a terminal that is
        // not in a repository says so, which is what lets a dictation there be
        // attributed to no project rather than to none we could name.
        let noRepoRoot = RepoVocabularyRootBox()
        _ = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(FileManager.default.temporaryDirectory.path) — zsh",
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache(),
            rootSink: { root in noRepoRoot.report(root) }
        )
        XCTAssertEqual(noRepoRoot.value, .noRepository)

        // A usable focused-window title disambiguates the focused tab and must
        // stay tier 1 even when descendant inspection would fail closed.
        let titlePreferredEntries = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(repo.path) — zsh",
            terminalApplicationPID: 700,
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache(),
            processSnapshot: { [.init(pid: 701, parentPID: 700)] },
            workingDirectoryForPID: { _ in nil }
        )
        XCTAssertEqual(titlePreferredEntries?.entries.first?.replaceWith, "useAuth.ts")
    }

    /// A git repo with no commits whose `.github/dictation.md` holds `terms`:
    /// `ls-files` answers empty, so the file's terms are the whole vocabulary.
    private func makeRepoWithDictationTerms(_ name: String, terms: String) throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(runGit(["init", "-b", "main"], in: repo), 0)
        let github = repo.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        try terms.write(
            to: github.appendingPathComponent("dictation.md"), atomically: true, encoding: .utf8
        )
        return repo
    }

    /// The join named the session's directory; a title naming another repo
    /// (another tab, a stale title) does not override it (#661).
    func testAJoinedWorkspaceDecidesTheRepoOverTheTitle() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        let titled = try makeRepoWithDictationTerms("titled", terms: "- Parakeet Stream\n")
        let joined = try makeRepoWithDictationTerms("joined", terms: "- Voxtral Realtime\n")
        let subdirectory = joined.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let root = RepoVocabularyRootBox()
        let outcome = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(titled.path) — zsh",
            joinedWorkspaceDirectory: subdirectory.path,
            transcript: "ask voxtral realtime and parakeet stream",
            cache: RepoVocabularyCache(),
            rootSink: { root.report($0) }
        )

        let terms = outcome?.entries.map(\.replaceWith) ?? []
        XCTAssertTrue(terms.contains("Voxtral Realtime"), "entries: \(terms)")
        XCTAssertFalse(terms.contains("Parakeet Stream"), "entries: \(terms)")
        guard case .root(let reported) = root.value else {
            return XCTFail("the joined workspace's repo was not reported: \(root.value)")
        }
        XCTAssertEqual(
            URL(fileURLWithPath: reported).standardizedFileURL.path,
            joined.standardizedFileURL.path
        )
    }

    /// A joined workspace outside any repo is the answer, not a reason to
    /// guess from the title: no vocabulary, and "no repository" reported.
    func testAJoinedWorkspaceOutsideARepoYieldsNoVocabulary() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        let titled = try makeRepoWithDictationTerms("titled", terms: "- Parakeet Stream\n")
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }

        let root = RepoVocabularyRootBox()
        let outcome = await RepoVocabularyService.entries(
            forWindowTitle: "user@mac: \(titled.path) — zsh",
            joinedWorkspaceDirectory: plain.path,
            transcript: "ask parakeet stream",
            cache: RepoVocabularyCache(),
            rootSink: { root.report($0) }
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(root.value, .noRepository)
    }

    /// The Claude Desktop case end to end through the production pipeline: no
    /// terminal PID and a target that is not a terminal, and the joined
    /// workspace's `.github/dictation.md` still grounds the transcript.
    @MainActor
    func testThePipelineGroundsAJoinedWorkspaceWithoutATerminal() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        let repo = try makeRepoWithDictationTerms("desktop", terms: "- Voxtral Realtime\n")
        let pipeline = RepoVocabularyPipeline(
            settings: makeSettings(),
            commitTargetAppPID: { nil },
            targetBundleID: { ClaudeDesktopAllowlist.bundleID }
        )

        let root = RepoVocabularyRootBox()
        let outcome = await pipeline.grounding(
            endpointURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
            transcript: "ask voxtral realtime",
            joinedWorkspace: LocalWorkspacePath(verifiedLocal: repo.path),
            repositoryRoot: root
        )

        XCTAssertEqual(outcome?.entries.map(\.replaceWith), ["Voxtral Realtime"])
        guard case .root = root.value else {
            return XCTFail("the joined workspace's repo was not reported: \(root.value)")
        }

        // The same dictation without the join has nothing to read.
        let unjoined = await pipeline.grounding(
            endpointURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
            transcript: "ask voxtral realtime",
            joinedWorkspace: nil,
            repositoryRoot: nil
        )
        XCTAssertNil(unjoined)
    }

    func testTitleClobberedAgentResolvesRepoFromTerminalDescendant() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repovocab-agent-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(runGit(["init", "-b", "main"], in: repo), 0)
        runGit(["config", "user.email", "test@example.com"], in: repo)
        runGit(["config", "user.name", "Test"], in: repo)
        runGit(["config", "commit.gpgsign", "false"], in: repo)
        try "export const useAuth = () => {}\n".write(
            to: repo.appendingPathComponent("useAuth.ts"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(runGit(["add", "-A"], in: repo), 0)
        XCTAssertEqual(runGit(["commit", "-m", "init"], in: repo), 0)

        let entries = await RepoVocabularyService.entries(
            forWindowTitle: "Claude Code",
            terminalApplicationPID: 400,
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache(),
            processSnapshot: {
                [
                    .init(pid: 401, parentPID: 400), // shell
                    .init(pid: 402, parentPID: 401), // coding agent
                    .init(pid: 999, parentPID: 1),   // unrelated process
                ]
            },
            workingDirectoryForPID: { pid in
                [401, 402].contains(pid) ? repo.path : nil
            }
        )
        XCTAssertEqual(entries?.entries.first?.replaceWith, "useAuth.ts")
    }

    /// Fail-closed at the `entries()` level: an unusable (nil) title plus a
    /// valid terminal PID whose process snapshot is EMPTY must yield no
    /// vocabulary. No descendants is not a resolution — `resolveGitRoot`
    /// returns `.none`, `entries` finds no git root, and the whole pipeline
    /// returns nil (never reading a CWD).
    func testEmptySnapshotFailsClosedAtEntriesLevel() async {
        let entries = await RepoVocabularyService.entries(
            forWindowTitle: nil,
            terminalApplicationPID: 800,
            transcript: "open use auth dot t s please",
            cache: RepoVocabularyCache(),
            processSnapshot: { [] },
            workingDirectoryForPID: { _ in
                XCTFail("no descendants exist; cwd must not be read")
                return nil
            }
        )
        XCTAssertNil(entries)
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
