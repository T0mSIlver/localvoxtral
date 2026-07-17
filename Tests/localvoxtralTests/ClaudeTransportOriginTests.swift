import Foundation
import XCTest
@testable import ClaudeContextWire
@testable import localvoxtral

// MARK: - Transport-derived origin

final class ClaudeWorkspaceReferenceTests: XCTestCase {
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh")

    func testLocalOriginYieldsUsableLocalPath() {
        let workspace = ClaudeWorkspaceReference.make(rawCwd: "/Users/me/repo", origin: local)
        XCTAssertEqual(workspace?.localPath?.path, "/Users/me/repo")
    }

    func testRemoteOriginNeverYieldsLocalPath() {
        let workspace = ClaudeWorkspaceReference.make(rawCwd: "/Users/me/repo", origin: remote)
        XCTAssertNil(workspace?.localPath, "a remote cwd must never become a LocalWorkspacePath")
        XCTAssertEqual(workspace, .remoteOpaque(label: "repo"))
    }

    func testRemoteWorkspaceDiscardsTheFullPath() throws {
        // The opaque label must not let a caller reconstruct where the remote
        // session lives.
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/home/victim/secrets/project", origin: remote)
        )
        guard case .remoteOpaque(let label) = workspace else {
            return XCTFail("expected remoteOpaque")
        }
        XCTAssertEqual(label, "project")
        XCTAssertFalse(label.contains("/"))
        XCTAssertFalse(label.contains("victim"))
        XCTAssertFalse(label.contains("secrets"))
    }

    func testLocalOriginRejectsRelativeCwd() {
        // We will not resolve a session's relative path against OUR cwd — they
        // are unrelated processes.
        XCTAssertNil(ClaudeWorkspaceReference.make(rawCwd: "relative/dir", origin: local))
    }

    func testEmptyAndNilCwdYieldNothing() {
        XCTAssertNil(ClaudeWorkspaceReference.make(rawCwd: nil, origin: local))
        XCTAssertNil(ClaudeWorkspaceReference.make(rawCwd: "", origin: local))
        XCTAssertNil(ClaudeWorkspaceReference.make(rawCwd: "", origin: remote))
    }

    func testDisplayNameIsSafeForBothOrigins() {
        let localWorkspace = ClaudeWorkspaceReference.make(rawCwd: "/a/b/proj", origin: local)
        XCTAssertEqual(localWorkspace?.displayName, "proj")
        let remoteWorkspace = ClaudeWorkspaceReference.make(rawCwd: "/a/b/proj", origin: remote)
        XCTAssertEqual(remoteWorkspace?.displayName, "proj")
    }

    // MARK: Opaque label sanitisation

    func testOpaqueLabelStripsTraversalAndSeparators() {
        XCTAssertEqual(ClaudeWorkspaceReference.opaqueLabel(for: "/a/../../etc"), "etc")
        // A cwd that is nothing but traversal leaves no label at all.
        XCTAssertEqual(ClaudeWorkspaceReference.opaqueLabel(for: "/a/b/.."), "")
        XCTAssertEqual(ClaudeWorkspaceReference.opaqueLabel(for: "/a/b/."), "")
    }

    func testOpaqueLabelStripsLeadingDots() {
        XCTAssertEqual(ClaudeWorkspaceReference.opaqueLabel(for: "/home/u/.config"), "config")
    }

    func testOpaqueLabelDropsShellAndPathMetacharacters() {
        let label = ClaudeWorkspaceReference.opaqueLabel(for: "/tmp/a b;rm -rf $HOME|x")
        XCTAssertFalse(label.contains(" "))
        XCTAssertFalse(label.contains(";"))
        XCTAssertFalse(label.contains("|"))
        XCTAssertFalse(label.contains("$"))
    }

    func testOpaqueLabelIsLengthCapped() {
        let label = ClaudeWorkspaceReference.opaqueLabel(for: "/x/" + String(repeating: "n", count: 500))
        XCTAssertEqual(label.count, 64)
    }

    func testRemoteCwdThatSanitisesToNothingYieldsNoWorkspace() {
        XCTAssertNil(ClaudeWorkspaceReference.make(rawCwd: "/a/..", origin: remote))
    }

    func testOriginIsLocalAuthenticatedPredicate() {
        XCTAssertTrue(local.isLocalAuthenticated)
        XCTAssertFalse(remote.isLocalAuthenticated)
    }
}

// MARK: - Remote records cannot reach the filesystem

/// Records every workspace a collector was asked to touch. Since
/// `ClaudeRepoCollecting` takes `LocalWorkspacePath` — a type only
/// constructible inside `ClaudeContextWire`, and only for a local origin — a
/// remote record has no way to reach this at all. The test proves the runtime
/// half; the compiler enforces the rest (there is no public initializer to
/// call).
final class TransportOriginSpyRepoCollector: ClaudeRepoCollecting, @unchecked Sendable {
    private(set) var collectedPaths: [String] = []

    func collect(
        workspace: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        transcript: String
    ) async -> ClaudeRepoSnapshot? {
        collectedPaths.append(workspace.path)
        return nil
    }
}

final class ClaudeRemotePathIsolationTests: XCTestCase {
    func testRemoteWorkspaceCannotBeHandedToACollector() async throws {
        let collector = TransportOriginSpyRepoCollector()
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/remote/repo", origin: .remote(channel: "ssh"))
        )

        // The only route from a workspace to the collector is `localPath`, and
        // for a remote workspace it is nil. There is no other accessor, and
        // `LocalWorkspacePath` cannot be constructed from outside the module.
        if let path = workspace.localPath {
            _ = await collector.collect(workspace: path, recentFiles: [], transcript: "")
        }

        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "a remote cwd must never trigger a filesystem collector"
        )
    }

    func testLocalWorkspaceReachesTheCollector() async throws {
        let collector = TransportOriginSpyRepoCollector()
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(
                rawCwd: "/local/repo", origin: .localAuthenticated(peerUID: 501)
            )
        )
        let path = try XCTUnwrap(workspace.localPath)
        _ = await collector.collect(workspace: path, recentFiles: [], transcript: "")
        XCTAssertEqual(collector.collectedPaths, ["/local/repo"])
    }

    // MARK: - Derivations preserve the boundary

    /// `ancestor` and `descendant` are the only ways a `LocalWorkspacePath`
    /// makes another one. If either accepted an arbitrary string, the type would
    /// stop being a proof — a caller could launder any path through a workspace
    /// it legitimately holds.
    func testAncestorOnlyAcceptsARealAncestor() throws {
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(
                rawCwd: "/local/repo/sub/dir", origin: .localAuthenticated(peerUID: 501)
            ).flatMap(\.localPath)
        )
        XCTAssertEqual(workspace.ancestor(atPath: "/local/repo")?.path, "/local/repo")
        XCTAssertEqual(workspace.ancestor(atPath: "/local/repo/sub/dir")?.path, "/local/repo/sub/dir")
        XCTAssertNil(workspace.ancestor(atPath: "/etc"))
        XCTAssertNil(workspace.ancestor(atPath: "/local/other"))
        // Prefix-but-not-ancestor: `/local/rep` is a string prefix of
        // `/local/repo/...` and must not pass as a parent directory.
        XCTAssertNil(workspace.ancestor(atPath: "/local/rep"))
    }

    func testDescendantRejectsEscapes() throws {
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(
                rawCwd: "/local/repo", origin: .localAuthenticated(peerUID: 501)
            ).flatMap(\.localPath)
        )
        XCTAssertEqual(workspace.descendant(relativePath: "a/b.swift")?.path, "/local/repo/a/b.swift")
        XCTAssertEqual(workspace.descendant(relativePath: "./a.swift")?.path, "/local/repo/a.swift")
        // Every one of these is a hook record or a tracked filename aiming a
        // read outside the workspace.
        XCTAssertNil(workspace.descendant(relativePath: "../secrets"))
        XCTAssertNil(workspace.descendant(relativePath: "a/../../secrets"))
        XCTAssertNil(workspace.descendant(relativePath: "/etc/passwd"))
        XCTAssertNil(workspace.descendant(relativePath: ""))
        XCTAssertNil(workspace.descendant(relativePath: "a\0b"))
    }
}
