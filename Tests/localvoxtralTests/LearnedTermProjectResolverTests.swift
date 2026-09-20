import ClaudeContextWire
import XCTest
@testable import localvoxtral

/// Which project a dictation is attributed to. Getting this wrong is not a
/// missed hint — it teaches one repo's vocabulary to another.
final class LearnedTermProjectResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-project-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("localvoxtral", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private var expectedKey: String {
        URL(fileURLWithPath: root.path).standardizedFileURL.path
    }

    private func workspace(_ path: String) -> ClaudeWorkspaceReference {
        ClaudeWorkspaceReference.make(rawCwd: path, origin: .localAuthenticated(peerUID: 501))!
    }

    /// The joined session's workspace is the signal that names the tree the
    /// speaker is talking about, so it decides even when a title is available.
    func testJoinedWorkspaceDecides() throws {
        let identity = LearnedTermProjectResolver.resolve(
            workspace: workspace(root.path),
            windowTitle: "~/elsewhere/other-repo — zsh"
        )

        XCTAssertEqual(identity.key, expectedKey)
        XCTAssertEqual(identity.name, "localvoxtral")
    }

    /// A subdirectory of the repo is the same project: every worktree folder
    /// teaches one vocabulary.
    func testSubdirectoryResolvesToTheRepositoryRoot() throws {
        let nested = root.appendingPathComponent("Sources/localvoxtral", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(workspace: workspace(nested.path), windowTitle: nil).key,
            expectedKey
        )
    }

    /// A remote session's files are on another machine: the label is all we
    /// hold, and the key says so rather than pretending to be a path.
    func testRemoteWorkspaceKeysByLabel() {
        let remote = ClaudeWorkspaceReference.make(rawCwd: "/home/dev/work/api", origin: .remote(channel: "ssh"))
        let identity = LearnedTermProjectResolver.resolve(workspace: remote, windowTitle: nil)

        XCTAssertEqual(identity.key, "remote:api")
        XCTAssertEqual(identity.name, "api")
    }

    func testTerminalTitleResolvesTheProjectWithoutAJoin() {
        let identity = LearnedTermProjectResolver.resolve(
            workspace: nil,
            windowTitle: "\(root.path) — zsh"
        )

        XCTAssertEqual(identity.key, expectedKey)
    }

    /// A directory outside a repository is not a project. Keying by the bare
    /// path would mint one for every folder the speaker passes through.
    func testDirectoryOutsideARepositoryIsShared() throws {
        let plain = root.deletingLastPathComponent()
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(workspace: workspace(plain.path), windowTitle: nil),
            LearnedTermProjectResolver.shared
        )
    }

    func testNoWorkspaceAndNoTitleIsShared() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(workspace: nil, windowTitle: nil),
            LearnedTermProjectResolver.shared
        )
    }

    /// A title that names no directory (a TUI has replaced it) is not a guess
    /// to act on.
    func testUnresolvableTitleIsShared() {
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(workspace: nil, windowTitle: "claude — Claude Code"),
            LearnedTermProjectResolver.shared
        )
    }
}
