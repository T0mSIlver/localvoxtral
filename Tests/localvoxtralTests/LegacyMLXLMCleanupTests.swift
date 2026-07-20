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
        //
        // The wheel installs a BARE `mlx_lm` console script alongside the dotted
        // entry points. Fixturing only the dotted names is what let the bare one
        // ship unremoved: the old `"mlx_lm."` prefix deleted its siblings and
        // left it behind.
        let consoleScriptLink = layout.toolBin.appendingPathComponent("mlx_lm")
        try fileManager.createSymbolicLink(
            at: consoleScriptLink,
            withDestinationURL: legacyVenv.appendingPathComponent("bin/mlx_lm")
        )
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

        // Legacy voxmlx install is deliberately preserved for part-4 cleanup.
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
        XCTAssertTrue(removedPaths.contains(consoleScriptLink.path))
        XCTAssertTrue(removedPaths.contains(serverLink.path))
        XCTAssertTrue(removedPaths.contains(generateBin.path))
        XCTAssertTrue(removedPaths.contains(legacyWheel.path))
        XCTAssertTrue(removedPaths.contains(markerURL.path))
        XCTAssertEqual(removedPaths.count, 6)

        XCTAssertFalse(fileManager.fileExists(atPath: legacyVenv.path))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: consoleScriptLink.path))
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

    /// The field state observed on a real 0.7.4 → 0.8.0 upgrade: a first cleanup
    /// pass (dotted prefix) had already removed `mlx_lm.server` and friends, so
    /// the bare `mlx_lm` shim was the only legacy entry left — dangling, and
    /// enough to make a later `uv tool install mlx-lm` fail with "Executable
    /// already exists". Re-running cleanup must finish the job.
    func testBareConsoleScriptLeftByAnEarlierPassIsStillRemoved() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.toolBin, withIntermediateDirectories: true)

        let bareShim = layout.toolBin.appendingPathComponent("mlx_lm")
        try fileManager.createSymbolicLink(
            at: bareShim,
            withDestinationURL: layout.tools.appendingPathComponent("mlx-lm/bin/mlx_lm")
        )
        // voxmlx sits in the same directory and must survive: the undotted
        // prefix must not start matching its neighbours.
        let voxmlxBin = layout.toolBin.appendingPathComponent("voxmlx-serve")
        try Data("#!/bin/sh".utf8).write(to: voxmlxBin)

        let removed = LegacyMLXLMCleanup(layout: layout).run()

        XCTAssertEqual(removed.map(\.path), [bareShim.path])
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: bareShim.path))
        XCTAssertTrue(fileManager.fileExists(atPath: voxmlxBin.path))
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
