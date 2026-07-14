import Foundation
import XCTest
@testable import localvoxtral

final class PolishModelCatalogTests: XCTestCase {
    func testCatalogLookupAndDefaultOption() {
        let defaultOption = PolishModelCatalog.defaultOption

        // Owner decision 2026-07-11: the 4B is the default for ALL users.
        XCTAssertEqual(defaultOption.repoID, "mlx-community/Qwen3.5-4B-OptiQ-4bit")
        XCTAssertEqual(PolishModelCatalog.option(forRepoID: defaultOption.repoID), defaultOption)
        XCTAssertNil(PolishModelCatalog.option(forRepoID: "unknown/model"))
        // nil sampling defaults = the engine's deterministic temp-0.3 default
        // (proven better than Qwen's recommended sampling on the eval, #97).
        XCTAssertNil(defaultOption.samplingDefaults)
        XCTAssertEqual(defaultOption.chatTemplateArguments, ["enable_thinking": false])
        // The 0.8B stays selectable with its legacy request shape (nil kwargs).
        XCTAssertNil(
            PolishModelCatalog.option(
                forRepoID: "mlx-community/Qwen3.5-0.8B-8bit"
            )?.chatTemplateArguments
        )
    }

    /// Every catalog model names an exact commit. A bare repo id tracks main,
    /// and upstream rewriting model.safetensors.index.json is precisely how
    /// the polish helper started dying on load (2026-07-14).
    func testEveryCatalogOptionPinsACommitRevision() {
        for option in PolishModelCatalog.options {
            XCTAssertEqual(
                option.revision.count,
                40,
                "\(option.repoID) must pin a full commit sha, got '\(option.revision)'"
            )
            XCTAssertTrue(
                option.revision.allSatisfy(\.isHexDigit),
                "\(option.repoID) pin is not a sha: '\(option.revision)'"
            )
        }
    }

    /// Regression, 2026-07-14: a pinned model is "downloaded" only when ITS
    /// snapshot is complete. Before the pin, isDownloaded followed refs/main,
    /// so an install still holding an older (or newer) revision read as ready
    /// and the helper was launched against weights we never fetched.
    func testPinnedModelIgnoresACompleteSnapshotOfAnotherRevision() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "owner/model"
        let repoDirectory = cacheRoot.appending(path: "models--owner--model")
        let otherRevision = "0000000000000000000000000000000000000000"
        let pinned = "1111111111111111111111111111111111111111"

        // A complete snapshot of some OTHER revision, and refs/main naming it.
        let snapshot = repoDirectory.appending(path: "snapshots/\(otherRevision)")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data().write(to: snapshot.appending(path: "config.json"))
        try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))
        try FileManager.default.createDirectory(
            at: repoDirectory.appending(path: "refs"),
            withIntermediateDirectories: true
        )
        try Data("\(otherRevision)\n".utf8).write(to: repoDirectory.appending(path: "refs/main"))

        XCTAssertTrue(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))
        XCTAssertFalse(
            PolishModelCache.isDownloaded(
                repoID: repoID,
                revision: pinned,
                cacheRoot: cacheRoot
            )
        )

        // Only the pinned snapshot's own completeness flips it.
        let pinnedSnapshot = repoDirectory.appending(path: "snapshots/\(pinned)")
        try FileManager.default.createDirectory(
            at: pinnedSnapshot,
            withIntermediateDirectories: true
        )
        try Data().write(to: pinnedSnapshot.appending(path: "config.json"))
        XCTAssertFalse(
            PolishModelCache.isDownloaded(repoID: repoID, revision: pinned, cacheRoot: cacheRoot)
        )
        try Data("weights".utf8).write(to: pinnedSnapshot.appending(path: "model.safetensors"))
        XCTAssertTrue(
            PolishModelCache.isDownloaded(repoID: repoID, revision: pinned, cacheRoot: cacheRoot)
        )
    }

    func testPickerEntriesAppendCustomStoredModelWithoutRewritingIt() {
        let customRepoID = "example/custom-polisher"

        let entries = PolishModelPickerSupport.entries(storedRepoID: customRepoID)

        XCTAssertEqual(entries.count, PolishModelCatalog.options.count + 1)
        XCTAssertEqual(entries.last?.repoID, customRepoID)
        XCTAssertEqual(entries.last?.label, "Custom: \(customRepoID)")
        XCTAssertNil(entries.last?.option)
    }

    func testPickerEntriesDoNotDuplicateCatalogModel() {
        let entries = PolishModelPickerSupport.entries(
            storedRepoID: PolishModelCatalog.defaultOption.repoID
        )

        XCTAssertEqual(entries.count, PolishModelCatalog.options.count)
    }

    func testCachePresenceRequiresConfigANDCompleteWeights() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "owner/model"
        let snapshot = cacheRoot
            .appending(path: "models--owner--model/snapshots/revision")
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )

        XCTAssertFalse(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))

        // config.json lands FIRST in a real download — its presence alone is
        // the mid-download state and must NOT read as downloaded (field
        // finding: the picker said "downloaded" while 3 GB were in flight).
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "config.json").path,
                contents: Data()
            )
        )
        XCTAssertFalse(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))

        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "model.safetensors").path,
                contents: Data("weights".utf8)
            )
        )
        XCTAssertTrue(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))
    }

    func testCachePresenceChecksAllShardsAgainstTheWeightIndex() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "owner/model"
        let snapshot = cacheRoot
            .appending(path: "models--owner--model/snapshots/revision")
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "config.json").path,
                contents: Data()
            )
        )
        let index: [String: Any] = [
            "weight_map": [
                "a.weight": "model-00001-of-00002.safetensors",
                "b.weight": "model-00002-of-00002.safetensors",
            ]
        ]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: snapshot.appending(path: "model.safetensors.index.json"))

        // One of two shards present (the index itself downloads early): the
        // snapshot is incomplete even though *a* safetensors file exists.
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "model-00001-of-00002.safetensors").path,
                contents: Data("shard".utf8)
            )
        )
        XCTAssertFalse(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))

        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "model-00002-of-00002.safetensors").path,
                contents: Data("shard".utf8)
            )
        )
        XCTAssertTrue(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))
    }

    func testCachePresenceFollowsMainReference() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoDirectory = cacheRoot.appending(path: "models--owner--model")
        let snapshot = repoDirectory.appending(path: "snapshots/main-revision")
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repoDirectory.appending(path: "refs"),
            withIntermediateDirectories: true
        )
        try Data("main-revision\n".utf8).write(to: repoDirectory.appending(path: "refs/main"))
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "config.json").path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "model.safetensors").path,
                contents: Data("weights".utf8)
            )
        )

        XCTAssertTrue(
            PolishModelCache.isDownloaded(repoID: "owner/model", cacheRoot: cacheRoot)
        )
    }

    func testCachePresenceIgnoresDanglingWeightSymlink() throws {
        // hf's cache links snapshot files to blobs only on completion, but a
        // link to a blob deleted by cache GC must not read as downloaded.
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "owner/model"
        let snapshot = cacheRoot
            .appending(path: "models--owner--model/snapshots/revision")
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshot.appending(path: "config.json").path,
                contents: Data()
            )
        )
        try FileManager.default.createSymbolicLink(
            at: snapshot.appending(path: "model.safetensors"),
            withDestinationURL: cacheRoot.appending(path: "models--owner--model/blobs/missing")
        )

        XCTAssertFalse(PolishModelCache.isDownloaded(repoID: repoID, cacheRoot: cacheRoot))
    }
}
