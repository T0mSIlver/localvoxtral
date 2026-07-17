import Foundation
import XCTest

@testable import localvoxtral

final class LegacyVoxmlxCleanupTests: XCTestCase {
    func testRemovesRetiredInstallOnlyUnderAppOwnedRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyVoxmlxCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned/backends", isDirectory: true)
        let layout = BackendInstallLayout(root: root)
        let outside = parent.appendingPathComponent("outside/voxmlx", isDirectory: true)

        for directory in [
            layout.tools.appendingPathComponent("voxmlx/bin", isDirectory: true),
            layout.toolBin,
            layout.downloads,
            root.appendingPathComponent("uv", isDirectory: true),
            root.appendingPathComponent("uv-cache", isDirectory: true),
            root.appendingPathComponent("python", isDirectory: true),
            outside,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("legacy".utf8).write(
            to: layout.tools.appendingPathComponent("voxmlx/bin/python")
        )
        try Data("entry".utf8).write(to: layout.toolBin.appendingPathComponent("voxmlx-serve"))
        try Data("wheel".utf8).write(to: layout.downloads.appendingPathComponent("voxmlx.whl"))
        try Data("keep".utf8).write(to: layout.tools.appendingPathComponent("keep.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        let marker = try JSONSerialization.data(
            withJSONObject: ["voxmlx": "0.1.0", "future": "1"],
            options: [.sortedKeys]
        )
        try marker.write(to: root.appendingPathComponent("installed.json"))

        let removed = LegacyVoxmlxCleanup(layout: layout).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.tools.appendingPathComponent("voxmlx").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.toolBin.appendingPathComponent("voxmlx-serve").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloads.appendingPathComponent("voxmlx.whl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("uv").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("uv-cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("python").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.tools.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(removed.isEmpty)

        let rewritten = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("installed.json"))
        ) as? [String: String]
        XCTAssertEqual(rewritten, ["future": "1"])
    }

    func testMissingRootAndSecondRunAreIdempotentNoOps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-voxmlx-root-\(UUID().uuidString)", isDirectory: true)
        let cleanup = LegacyVoxmlxCleanup(layout: BackendInstallLayout(root: root))

        XCTAssertEqual(cleanup.run(), [])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tools/voxmlx", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertFalse(cleanup.run().isEmpty)
        XCTAssertEqual(cleanup.run(), [])
    }
}
