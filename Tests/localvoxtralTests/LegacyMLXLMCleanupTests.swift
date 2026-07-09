import Foundation
import XCTest
@testable import localvoxtral

final class LegacyMLXLMCleanupTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testRemovesOrphanedMLXLMPiecesAndKeepsEverythingElse() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let fileManager = FileManager.default

        // Orphaned mlx-lm install, as `uv tool install` left it.
        let legacyVenv = layout.tools.appendingPathComponent("mlx-lm", isDirectory: true)
        try fileManager.createDirectory(
            at: legacyVenv.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("home = python".utf8).write(to: legacyVenv.appendingPathComponent("pyvenv.cfg"))
        try fileManager.createDirectory(at: layout.toolBin, withIntermediateDirectories: true)
        // uv links bin entries into the venv; after the venv is gone these
        // dangle, which fileExists-based checks would miss.
        let serverLink = layout.toolBin.appendingPathComponent("mlx_lm.server")
        try fileManager.createSymbolicLink(
            at: serverLink,
            withDestinationURL: legacyVenv.appendingPathComponent("bin/mlx_lm.server")
        )
        let generateBin = layout.toolBin.appendingPathComponent("mlx_lm.generate")
        try Data("#!/bin/sh".utf8).write(to: generateBin)
        try fileManager.createDirectory(at: layout.downloads, withIntermediateDirectories: true)
        let legacyWheel = layout.downloads
            .appendingPathComponent("mlx_lm-0.31.3.post4-py3-none-any.whl")
        try Data("wheel".utf8).write(to: legacyWheel)

        // Still-managed voxmlx install — must survive untouched.
        let voxmlxVenv = layout.tools.appendingPathComponent("voxmlx", isDirectory: true)
        try fileManager.createDirectory(at: voxmlxVenv, withIntermediateDirectories: true)
        let voxmlxBin = layout.toolBin.appendingPathComponent("voxmlx-serve")
        try Data("#!/bin/sh".utf8).write(to: voxmlxBin)
        let voxmlxWheel = layout.downloads.appendingPathComponent("voxmlx-0.1.0-py3-none-any.whl")
        try Data("wheel".utf8).write(to: voxmlxWheel)
        let markerURL = root.appendingPathComponent("installed.json")
        try JSONSerialization.data(
            withJSONObject: ["mlx-lm": "0.31.3.post4", "voxmlx": "0.1.0"],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: markerURL)

        let removed = LegacyMLXLMCleanup(layout: layout).run()

        let removedPaths = Set(removed.map(\.path))
        XCTAssertTrue(removedPaths.contains(legacyVenv.path))
        XCTAssertTrue(removedPaths.contains(serverLink.path))
        XCTAssertTrue(removedPaths.contains(generateBin.path))
        XCTAssertTrue(removedPaths.contains(legacyWheel.path))
        XCTAssertTrue(removedPaths.contains(markerURL.path))
        XCTAssertEqual(removedPaths.count, 5)

        XCTAssertFalse(fileManager.fileExists(atPath: legacyVenv.path))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: serverLink.path))
        XCTAssertFalse(fileManager.fileExists(atPath: generateBin.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyWheel.path))

        XCTAssertTrue(fileManager.fileExists(atPath: voxmlxVenv.path))
        XCTAssertTrue(fileManager.fileExists(atPath: voxmlxBin.path))
        XCTAssertTrue(fileManager.fileExists(atPath: voxmlxWheel.path))
        let marker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as? [String: String]
        XCTAssertEqual(marker, ["voxmlx": "0.1.0"])
    }

    func testDanglingBinSymlinkAloneIsStillRemoved() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.toolBin, withIntermediateDirectories: true)
        let danglingLink = layout.toolBin.appendingPathComponent("mlx_lm.server")
        try fileManager.createSymbolicLink(
            at: danglingLink,
            withDestinationURL: layout.tools.appendingPathComponent("mlx-lm/bin/mlx_lm.server")
        )

        let removed = LegacyMLXLMCleanup(layout: layout).run()

        XCTAssertEqual(removed.map(\.path), [danglingLink.path])
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: danglingLink.path))
    }

    func testSecondRunAndMissingRootAreSilentNoOps() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let fileManager = FileManager.default
        let legacyVenv = layout.tools.appendingPathComponent("mlx-lm", isDirectory: true)
        try fileManager.createDirectory(at: legacyVenv, withIntermediateDirectories: true)

        XCTAssertFalse(LegacyMLXLMCleanup(layout: layout).run().isEmpty)
        XCTAssertTrue(LegacyMLXLMCleanup(layout: layout).run().isEmpty)

        let missingRoot = root.appendingPathComponent("never-created", isDirectory: true)
        let cleanup = LegacyMLXLMCleanup(layout: BackendInstallLayout(root: missingRoot))
        XCTAssertTrue(cleanup.run().isEmpty)
    }

    func testMarkerWithoutLegacyEntryIsLeftByteIdentical() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markerURL = root.appendingPathComponent("installed.json")
        let original = try JSONSerialization.data(
            withJSONObject: ["voxmlx": "0.1.0"],
            options: [.prettyPrinted, .sortedKeys]
        )
        try original.write(to: markerURL)

        XCTAssertTrue(LegacyMLXLMCleanup(layout: layout).run().isEmpty)
        XCTAssertEqual(try Data(contentsOf: markerURL), original)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-mlxlm-cleanup-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(url)
        return url
    }
}
