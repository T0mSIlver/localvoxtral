import Foundation
import XCTest
@testable import localvoxtral

final class PolishModelCatalogTests: XCTestCase {
    func testCatalogLookupAndDefaultOption() {
        let defaultOption = PolishModelCatalog.defaultOption

        XCTAssertEqual(defaultOption.repoID, "mlx-community/Qwen3.5-0.8B-8bit")
        XCTAssertEqual(PolishModelCatalog.option(forRepoID: defaultOption.repoID), defaultOption)
        XCTAssertNil(PolishModelCatalog.option(forRepoID: "unknown/model"))
        XCTAssertNil(defaultOption.samplingDefaults)
        XCTAssertNil(defaultOption.chatTemplateArguments)
        XCTAssertEqual(
            PolishModelCatalog.option(
                forRepoID: "mlx-community/Qwen3.5-4B-OptiQ-4bit"
            )?.chatTemplateArguments,
            ["enable_thinking": false]
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
