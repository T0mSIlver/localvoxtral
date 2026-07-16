import Foundation
import XCTest
@testable import ClaudeContextWire

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

/// Records every workspace a collector was asked to touch. Since the protocol
/// takes `LocalWorkspacePath` — a type only constructible inside
/// `ClaudeContextWire`, and only for a local origin — a remote record has no
/// way to reach this at all. The test proves the runtime half; the compiler
/// enforces the rest (there is no public initializer to call).
final class SpyRepoCollector: ClaudeLocalRepoCollecting, @unchecked Sendable {
    private(set) var collectedPaths: [String] = []

    func collectRepositoryContext(for workspace: LocalWorkspacePath) -> [String] {
        collectedPaths.append(workspace.path)
        return []
    }
}

final class ClaudeRemotePathIsolationTests: XCTestCase {
    func testRemoteWorkspaceCannotBeHandedToACollector() throws {
        let collector = SpyRepoCollector()
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/remote/repo", origin: .remote(channel: "ssh"))
        )

        // The only route from a workspace to the collector is `localPath`, and
        // for a remote workspace it is nil. There is no other accessor, and
        // `LocalWorkspacePath` cannot be constructed from outside the module.
        if let path = workspace.localPath {
            _ = collector.collectRepositoryContext(for: path)
        }

        XCTAssertTrue(
            collector.collectedPaths.isEmpty,
            "a remote cwd must never trigger a filesystem collector"
        )
    }

    func testLocalWorkspaceReachesTheCollector() throws {
        let collector = SpyRepoCollector()
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(
                rawCwd: "/local/repo", origin: .localAuthenticated(peerUID: 501)
            )
        )
        let path = try XCTUnwrap(workspace.localPath)
        _ = collector.collectRepositoryContext(for: path)
        XCTAssertEqual(collector.collectedPaths, ["/local/repo"])
    }
}
