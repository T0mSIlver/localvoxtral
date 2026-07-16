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

    // MARK: - Ghostty-abbreviated titles (leading components elided as `..`)

    /// The T6 field case (2026-07-11): Ghostty's tab title is exactly
    /// "../Desktop/projects/supervoxtral". The extracted absolute run
    /// "/Desktop/projects/supervoxtral" does not exist; the home-anchored
    /// expansion does and must resolve.
    func testGhosttyAbbreviatedTitleResolvesHomeAnchored() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "../Desktop/projects/supervoxtral",
            homeDirectory: "/Users/x",
            isDirectory: { $0 == "/Users/x/Desktop/projects/supervoxtral" }
        )
        XCTAssertEqual(resolved, "/Users/x/Desktop/projects/supervoxtral")
    }

    /// A genuinely absolute path that exists must never be shadowed by its
    /// home-anchored twin, even when both exist.
    func testExistingAbsolutePathWinsOverHomeAnchoredTwin() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "/opt/work/repo",
            homeDirectory: home,
            isDirectory: { $0 == "/opt/work/repo" || $0 == "\(self.home)/opt/work/repo" }
        )
        XCTAssertEqual(resolved, "/opt/work/repo")
    }

    /// A genuinely absolute path that does not exist locally (an SSH or
    /// container path, an unmounted volume) must resolve to NIL — never be
    /// re-anchored under home, which would index a same-named local repo and
    /// inject wrong-repo vocabulary. Only `../`-prefixed (explicitly elided)
    /// titles get home-anchoring.
    func testNonExistentAbsolutePathDoesNotFallBackToHome() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "/work/repo — zsh",
            homeDirectory: home,
            isDirectory: { $0 == "\(self.home)/work/repo" }
        )
        XCTAssertNil(resolved)
    }

    /// THE T6 field failure, canonical case (owner-confirmed 2026-07-11):
    /// Ghostty's tab title elides with a Unicode HORIZONTAL ELLIPSIS, not
    /// ASCII dots — the real title was "…/Desktop/projects/supervoxtral"
    /// (reported by typing, which loses the distinction from "../"). The
    /// ellipsis-elided title must home-anchor exactly like the ASCII form.
    func testT6GhosttyEllipsisElidedTitleResolvesHomeAnchored() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "…/Desktop/projects/supervoxtral",
            homeDirectory: "/Users/owner",
            isDirectory: { $0 == "/Users/owner/Desktop/projects/supervoxtral" }
        )
        XCTAssertEqual(resolved, "/Users/owner/Desktop/projects/supervoxtral")
    }

    /// The same canonical T6 case through the PRODUCTION existence check (no
    /// injected predicate — the default real-filesystem one), against a real
    /// temp directory tree, so hermetic test defaults can never mask a broken
    /// production wiring again.
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

    /// U+2025 TWO DOT LEADER is accepted as an elision mark too.
    func testTwoDotLeaderElidedTitleResolvesHomeAnchored() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "‥/dev/proj — zsh",
            homeDirectory: home,
            isDirectory: { $0 == "\(self.home)/dev/proj" }
        )
        XCTAssertEqual(resolved, "/Users/tester/dev/proj")
    }

    func testEllipsisFallbackCandidateShape() {
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.homeAnchoredFallbackCandidates(
                fromWindowTitle: "…/Desktop/proj — zsh",
                homeDirectory: home
            ),
            ["/Users/tester/Desktop/proj"]
        )
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

    func testAbbreviatedTitleWithNothingExistingResolvesNil() {
        let resolved = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
            fromWindowTitle: "../foo",
            homeDirectory: home,
            isDirectory: { _ in false }
        )
        XCTAssertNil(resolved)
    }

    func testHomeAnchoredFallbackCandidateShapes() {
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.homeAnchoredFallbackCandidates(
                fromWindowTitle: "../Desktop/proj — zsh",
                homeDirectory: home
            ),
            ["/Users/tester/Desktop/proj"]
        )
        // A tilde run is already home-anchored: no fallback is generated.
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.homeAnchoredFallbackCandidates(
                fromWindowTitle: "~/dev/proj",
                homeDirectory: home
            ),
            []
        )
        // An absolute run generates NO fallback: only `../` signals elision.
        XCTAssertEqual(
            TerminalWorkingDirectoryResolver.homeAnchoredFallbackCandidates(
                fromWindowTitle: "/work/repo — zsh",
                homeDirectory: home
            ),
            []
        )
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

    func testGroundedFuzzyTierAbstainsForTiedDistanceOneCandidates() {
        let transcript = "Open ConfigC.swift."
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: transcript,
            vocabulary: RepoVocabulary(
                terms: ["ConfigA.swift", "ConfigB.swift"],
                branch: nil
            )
        )

        XCTAssertTrue(result.isEmpty, "entries: \(result)")
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(entries: result, to: transcript),
            transcript
        )
    }

    func testGroundedCandidatesUseAlignedFallbackAfterExistingMatcherMisses() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Open uzoft.ts and add a null check.",
            vocabulary: RepoVocabulary(terms: ["useAuth.ts"], branch: nil)
        )
        XCTAssertEqual(
            result,
            [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["uzoft.ts"])]
        )
    }

    func testAlignedFallbackRecoversLongFrenchPhoneticDamage() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Regarde de dictation vie ou modèle.",
            vocabulary: RepoVocabulary(terms: ["DictationViewModel.swift"], branch: nil)
        )
        XCTAssertEqual(result.first?.replaceWith, "DictationViewModel.swift")
        XCTAssertEqual(result.first?.matches, ["dictation vie ou modèle"])
    }

    func testAlignedFallbackRecoversRecordedContextMisses() {
        let cases: [(transcript: String, exact: String, heard: String)] = [
            (
                "Rebase my brand John to feed/Polish helper MLX Swift.",
                "feat/polish-helper-mlx-swift",
                "feed/Polish helper MLX Swift"
            ),
            (
                "Why is local voxtral cotisin identity not picked up by the runner?",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "local voxtral cotisin identity"
            ),
            (
                "The crash is in Pozik's pipe read next Chong.",
                "POSIXPipeRead.nextChunk(fromDescriptor:)",
                "Pozik's pipe read next Chong"
            ),
            (
                "Pourquoi la variable locale Voxtral co-design identity est ignorée?",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "locale Voxtral co-design identity"
            ),
            (
                "Move the token refresh into off service.ts.",
                "AuthService.ts",
                "service.ts"
            ),
        ]

        for item in cases {
            let result = RepoVocabularyMatcher.groundedCandidateEntries(
                transcript: item.transcript,
                vocabulary: RepoVocabulary(terms: [item.exact], branch: nil)
            )
            XCTAssertEqual(result.first?.replaceWith, item.exact, item.transcript)
            XCTAssertEqual(result.first?.matches, [item.heard], item.transcript)
        }
    }

    func testAlignedFallbackAbstainsWhenCandidatesAreAmbiguous() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Open auth sir vice here.",
            vocabulary: RepoVocabulary(
                terms: ["AuthService.ts", "AuthServices.ts"],
                branch: nil
            )
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }

    func testAlignedFallbackAbstainsOnUnrelatedProse() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Please improve the error message for users.",
            vocabulary: RepoVocabulary(
                terms: ["UserSessionManager.swift", "AuthService.ts"],
                branch: nil
            )
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }

    func testAlignedFallbackDoesNotForceUnspokenFileExtensionWithoutFileCue() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Fix the user session manager.",
            vocabulary: RepoVocabulary(terms: ["UserSessionManager.swift"], branch: nil)
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }

    func testAlignedFallbackAbstainsOnGluedSingleTokenThatWouldDeleteProse() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "Ouvreusot.ts maintenant.",
            vocabulary: RepoVocabulary(terms: ["useAuth.ts"], branch: nil)
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }

    func testPreapplyApprovedMappingPreservesPunctuation() {
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: [
                    ReplacementEntry(
                        replaceWith: "useAuth.ts",
                        matches: ["use auth dot t s"]
                    )
                ],
                to: "Open use auth dot t s, then add a null check."
            ),
            "Open useAuth.ts, then add a null check."
        )
    }

    func testPreapplyApprovedMappingsUsesLongestAliasFirst() {
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: [
                    ReplacementEntry(replaceWith: "Auth", matches: ["auth"]),
                    ReplacementEntry(
                        replaceWith: "AuthService.ts",
                        matches: ["auth service dot t s"]
                    ),
                ],
                to: "Open auth service dot t s and inspect auth."
            ),
            "Open AuthService.ts and inspect Auth."
        )
    }

    func testPreapplyRepoClipboardConflictUsesLongerExactTermPrecedence() {
        let repoEntry = ReplacementEntry(
            replaceWith: "RepoAPI",
            matches: ["heard api"]
        )
        let clipboardEntry = ReplacementEntry(
            replaceWith: "ClipboardAPI",
            matches: ["heard api"]
        )

        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: [repoEntry, clipboardEntry],
                to: "Open heard api."
            ),
            "Open ClipboardAPI."
        )
    }

    func testFrenchComposedAndDecomposedAccentsFallbackAndPreapplyPreservePunctuation() {
        let accentForms = ["modèle", "mode\u{0300}le"]
        for accentForm in accentForms {
            let transcript = "Regarde, dictation vie ou \(accentForm)."
            let entries = RepoVocabularyMatcher.groundedCandidateEntries(
                transcript: transcript,
                vocabulary: RepoVocabulary(
                    terms: ["DictationViewModel.swift"],
                    branch: nil
                )
            )

            XCTAssertEqual(entries.first?.matches, ["dictation vie ou \(accentForm)"])
            XCTAssertEqual(
                RepoVocabularyMatcher.preapplying(entries: entries, to: transcript),
                "Regarde, DictationViewModel.swift."
            )
        }
    }

    func testPreapplyApprovedMappingDoesNotRewriteInsideIdentifier() {
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["auth"])],
                to: "Keep preauth_handler unchanged."
            ),
            "Keep preauth_handler unchanged."
        )
    }

    func testPreapplySkipsUnsafeControlCharacterTerm() {
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: [ReplacementEntry(replaceWith: "bad\nname.ts", matches: ["bad name"])],
                to: "Open bad name now."
            ),
            "Open bad name now."
        )
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

    func testAlignedFallbackAbstainsCleanlyWithLargeAmbiguousVocabulary() {
        let terms = (0..<20_000).map { "GeneratedFile\($0).swift" }
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "please improve overall error handling for generated files",
            vocabulary: RepoVocabulary(terms: terms, branch: nil)
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }
}

// MARK: - Service orchestration (injected subprocess + fixture .git)

final class ClipboardVocabularyTests: XCTestCase {
    // MARK: - Entity extraction (reuses the guard's recognizer)

    func testEntitiesRecognizeCodeLikeTokensAndDedupe() {
        let excerpt = """
        Fix UserSessionManager.swift and rerun with --force.
        See src/auth/useAuth.ts and $HOME_DIR, then UserSessionManager.swift again.
        """
        XCTAssertEqual(
            ClipboardVocabulary.entities(inExcerpt: excerpt),
            ["UserSessionManager.swift", "--force", "src/auth/useAuth.ts", "$HOME_DIR"]
        )
    }

    func testEntitiesUnwrapBacktickSpans() {
        XCTAssertEqual(
            ClipboardVocabulary.entities(inExcerpt: "call `resolveWorkingDirectory` here"),
            ["resolveWorkingDirectory"]
        )
    }

    func testEntitiesRecognizeBareContextIdentifiersMissedByGuardGrammar() {
        XCTAssertEqual(
            ClipboardVocabulary.entities(
                inExcerpt: "LOCALVOXTRAL_CODESIGN_IDENTITY ShortcutRecorder POSIXPipeRead.nextChunk(fromDescriptor:)"
            ),
            [
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "ShortcutRecorder",
                "POSIXPipeRead.nextChunk(fromDescriptor:)",
            ]
        )
    }

    func testSupplementalEntityExtractionRejectsOrdinaryClipboardProse() {
        XCTAssertTrue(
            ClipboardVocabulary.entities(
                inExcerpt: "Please remember that authentication service behavior matters"
            ).isEmpty
        )
    }

    func testSupplementalEntitiesRejectColonAndHyphenatedProse() {
        let cases: [(excerpt: String, transcript: String)] = [
            ("Description: details", "description"),
            ("well-known", "well known"),
        ]

        for item in cases {
            XCTAssertTrue(
                ClipboardVocabulary.entities(inExcerpt: item.excerpt).isEmpty,
                "excerpt: \(item.excerpt)"
            )
            XCTAssertTrue(
                ClipboardVocabulary.candidateEntries(
                    transcript: item.transcript,
                    excerpt: item.excerpt
                ).isEmpty,
                "excerpt: \(item.excerpt)"
            )
        }
    }

    func testProseExcerptYieldsNoEntities() {
        XCTAssertTrue(
            ClipboardVocabulary.entities(
                inExcerpt: "just a plain sentence with no code tokens at all"
            ).isEmpty
        )
    }

    // MARK: - Transcript matching (same matcher as repo vocabulary)

    /// The T5 field case (2026-07-11): clipboard holds the exact identifier,
    /// the STT glued the dictated tail into `manager.swift`. The transcript
    /// n-gram must match the clipboard entity and yield the structured
    /// (spoken, exact) pair the session can pre-apply before polishing.
    func testT5TranscriptGramMatchesClipboardEntity() {
        let result = ClipboardVocabulary.candidateEntries(
            transcript: "look at user session manager.swift",
            excerpt: "UserSessionManager.swift"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "UserSessionManager.swift")
        XCTAssertEqual(result.first?.matches, ["user session manager.swift"])
    }

    func testSupplementalEntitiesGroundCommonTechnicalDictationDamage() {
        let cases: [(transcript: String, excerpt: String, expected: String)] = [
            (
                "set local voxtral code sign identity before packaging",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "LOCALVOXTRAL_CODESIGN_IDENTITY"
            ),
            (
                "the crash is in posix pipe read next chunk from descriptor",
                "POSIXPipeRead.nextChunk(fromDescriptor:)",
                "POSIXPipeRead.nextChunk(fromDescriptor:)"
            ),
            (
                "check whether shortcut recorder is initialized",
                "ShortcutRecorder",
                "ShortcutRecorder"
            ),
        ]

        for testCase in cases {
            let result = ClipboardVocabulary.candidateEntries(
                transcript: testCase.transcript,
                excerpt: testCase.excerpt
            )
            XCTAssertEqual(
                result.first?.replaceWith,
                testCase.expected,
                "transcript: \(testCase.transcript); entries: \(result)"
            )
        }
    }

    func testUnrelatedTranscriptYieldsNoEntries() {
        XCTAssertTrue(
            ClipboardVocabulary.candidateEntries(
                transcript: "completely unrelated dictation about lunch",
                excerpt: "UserSessionManager.swift"
            ).isEmpty
        )
    }
}

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
        XCTAssertEqual(titleEntries?.entries.first?.replaceWith, "useAuth.ts")

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
