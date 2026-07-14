import XCTest

@testable import PolishHelperCore

final class HFCacheModelLocatorTests: XCTestCase {
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "hf-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: cacheRoot)
    }

    private func makeSnapshot(repo: String, revision: String, withConfig: Bool = true) throws -> URL {
        let snapshot = cacheRoot
            .appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots/\(revision)")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        if withConfig {
            try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))
        }
        return snapshot
    }

    private func writeMainRef(repo: String, revision: String) throws {
        let refs = cacheRoot
            .appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "refs")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data("\(revision)\n".utf8).write(to: refs.appending(path: "main"))
    }

    func testResolvesSnapshotNamedByMainRef() throws {
        let repo = "mlx-community/Qwen3.5-0.8B-8bit"
        _ = try makeSnapshot(repo: repo, revision: "old")
        let wanted = try makeSnapshot(repo: repo, revision: "abc123")
        try writeMainRef(repo: repo, revision: "abc123")

        let located = try HFCacheModelLocator.locate(repoID: repo, cacheRoot: cacheRoot)
        XCTAssertEqual(located.standardizedFileURL, wanted.standardizedFileURL)
    }

    /// Regression, 2026-07-14: main moved to a revision the app never
    /// downloaded (its index named a vision shard our include patterns skip)
    /// and the helper loaded it anyway, dying in load_safetensors. A pinned
    /// revision must win over refs/main.
    func testPinnedRevisionWinsOverMainRef() throws {
        let repo = "mlx-community/Qwen3.5-4B-OptiQ-4bit"
        let pinned = try makeSnapshot(repo: repo, revision: "pinned-sha")
        _ = try makeSnapshot(repo: repo, revision: "upstream-head")
        try writeMainRef(repo: repo, revision: "upstream-head")

        let located = try HFCacheModelLocator.locate(
            repoID: repo,
            revision: "pinned-sha",
            cacheRoot: cacheRoot
        )
        XCTAssertEqual(located.standardizedFileURL, pinned.standardizedFileURL)
    }

    /// Never silently fall back to another snapshot: loading weights the app
    /// did not download is the failure mode this pin exists to prevent, so an
    /// uncached pin is a hard, actionable error.
    func testUncachedPinnedRevisionThrowsInsteadOfFallingBack() throws {
        let repo = "mlx-community/Qwen3.5-4B-OptiQ-4bit"
        _ = try makeSnapshot(repo: repo, revision: "upstream-head")
        try writeMainRef(repo: repo, revision: "upstream-head")

        XCTAssertThrowsError(
            try HFCacheModelLocator.locate(
                repoID: repo,
                revision: "pinned-sha",
                cacheRoot: cacheRoot
            )
        ) { error in
            guard
                case HFCacheModelLocator.LocatorError.pinnedRevisionNotCached(
                    _,
                    let revision,
                    _
                ) = error
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(revision, "pinned-sha")
        }
    }

    func testFallsBackToNewestSnapshotWithConfigWhenRefMissing() throws {
        let repo = "org/model"
        _ = try makeSnapshot(repo: repo, revision: "no-config", withConfig: false)
        let usable = try makeSnapshot(repo: repo, revision: "usable")

        let located = try HFCacheModelLocator.locate(repoID: repo, cacheRoot: cacheRoot)
        XCTAssertEqual(located.standardizedFileURL, usable.standardizedFileURL)
    }

    func testMissingModelThrowsActionableError() {
        XCTAssertThrowsError(
            try HFCacheModelLocator.locate(repoID: "org/absent", cacheRoot: cacheRoot)
        ) { error in
            guard case HFCacheModelLocator.LocatorError.modelNotCached(let repoID, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(repoID, "org/absent")
        }
    }

    func testSnapshotsWithoutConfigThrow() throws {
        let repo = "org/broken"
        _ = try makeSnapshot(repo: repo, revision: "x", withConfig: false)
        XCTAssertThrowsError(
            try HFCacheModelLocator.locate(repoID: repo, cacheRoot: cacheRoot)
        ) { error in
            guard case HFCacheModelLocator.LocatorError.noUsableSnapshot = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCacheRootResolutionRespectsEnvOverrides() {
        let home = URL(filePath: "/Users/x")
        XCTAssertEqual(
            HFCacheModelLocator.defaultCacheRoot(environment: [:], home: home).path,
            "/Users/x/.cache/huggingface/hub"
        )
        XCTAssertEqual(
            HFCacheModelLocator.defaultCacheRoot(environment: ["HF_HOME": "/hf"], home: home).path,
            "/hf/hub"
        )
        XCTAssertEqual(
            HFCacheModelLocator.defaultCacheRoot(
                environment: ["HF_HUB_CACHE": "/direct", "HF_HOME": "/hf"], home: home
            ).path,
            "/direct"
        )
    }
}
