import ClaudeContextWire
import XCTest
@testable import localvoxtral

/// Which project a dictation is attributed to. Getting this wrong is not a
/// missed hint — it teaches one repo's vocabulary to another.
final class LearnedTermProjectResolverTests: XCTestCase {
    private func workspace(_ path: String) -> ClaudeWorkspaceReference {
        ClaudeWorkspaceReference.make(rawCwd: path, origin: .localAuthenticated(peerUID: 501))!
    }

    /// A session running in a subdirectory teaches the repository, so every
    /// session in one checkout shares one vocabulary.
    func testSessionInsideTheRepositoryKeysByTheRepository() {
        let identity = LearnedTermProjectResolver.resolve(
            repositoryRoot: .root("/Users/t/work/localvoxtral"),
            workspace: workspace("/Users/t/work/localvoxtral/Sources/localvoxtral")
        )

        XCTAssertEqual(identity?.key, "/Users/t/work/localvoxtral")
        XCTAssertEqual(identity?.name, "localvoxtral")
    }

    /// A root that does not contain the session's directory describes another
    /// tab. Merging the two would file one repo's terms under the other.
    func testUnrelatedRepositoryRootDoesNotClaimTheSession() {
        let identity = LearnedTermProjectResolver.resolve(
            repositoryRoot: .root("/Users/t/work/herdr"),
            workspace: workspace("/Users/t/work/localvoxtral")
        )

        XCTAssertEqual(identity?.key, "/Users/t/work/localvoxtral")
    }

    /// Prefix comparison on paths, not on strings: `/a/bc` is not inside
    /// `/a/b`.
    func testSiblingDirectoryIsNotInsideTheRepository() {
        let identity = LearnedTermProjectResolver.resolve(
            repositoryRoot: .root("/Users/t/work/voxtral"),
            workspace: workspace("/Users/t/work/voxtral-fork")
        )

        XCTAssertEqual(identity?.key, "/Users/t/work/voxtral-fork")
    }

    func testSessionWithNoRepositoryRootKeysByItsOwnDirectory() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(
                repositoryRoot: .unknown, workspace: workspace("/Users/t/notes")
            )?.key,
            "/Users/t/notes"
        )
    }

    /// A remote session's files are on another machine, so the local
    /// terminal's repository says nothing about them.
    func testRemoteWorkspaceKeysByLabelAndIgnoresTheLocalRepository() {
        let remote = ClaudeWorkspaceReference.make(
            rawCwd: "/home/dev/work/api", origin: .remote(channel: "ssh")
        )
        let identity = LearnedTermProjectResolver.resolve(
            repositoryRoot: .root("/Users/t/work/localvoxtral"), workspace: remote
        )

        XCTAssertEqual(identity?.key, "remote:api")
        XCTAssertEqual(identity?.name, "api")
    }

    func testUnjoinedDictationKeysByTheTerminalRepository() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(
                repositoryRoot: .root("/Users/t/work/localvoxtral"), workspace: nil
            ),
            LearnedTermProjectResolver.Identity(
                key: "/Users/t/work/localvoxtral", name: "localvoxtral"
            )
        )
    }

    /// The pipeline ran and this is not a repository: a real project-less
    /// dictation, which teaches the shared bucket.
    func testNoRepositoryAndNoSessionIsShared() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(repositoryRoot: .noRepository, workspace: nil),
            LearnedTermProjectResolver.shared
        )
    }

    /// Nobody looked — the setting is off, the endpoint is not permitted, a
    /// previous pipeline holds the gate, or the deadline expired. Filing this
    /// under `shared` would put one repo's spellings where every project-less
    /// dictation reads them, so the dictation teaches nothing.
    func testUnknownProjectTeachesNothing() {
        XCTAssertNil(
            LearnedTermProjectResolver.resolve(repositoryRoot: .unknown, workspace: nil)
        )
    }

    /// A joined session is stable evidence on its own: it keys the dictation
    /// even when the pipeline never ran.
    func testJoinedSessionKeysWithoutThePipeline() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(
                repositoryRoot: .unknown, workspace: workspace("/Users/t/work/localvoxtral")
            )?.key,
            "/Users/t/work/localvoxtral"
        )
    }

    /// One directory has one key however the path was spelled.
    func testPathsAreNormalizedBeforeTheyBecomeKeys() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(
                repositoryRoot: .root("/Users/t/work//localvoxtral/"),
                workspace: workspace("/Users/t/work/localvoxtral/Sources/..")
            )?.key,
            "/Users/t/work/localvoxtral"
        )
    }
}
