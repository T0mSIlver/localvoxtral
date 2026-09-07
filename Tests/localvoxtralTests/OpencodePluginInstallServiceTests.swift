import Foundation
import XCTest

@testable import localvoxtral

/// Installer tests for the opencode plugin (`OpencodePluginInstallService`):
/// create, idempotent re-apply, removal, symlink refusal, unreadable refusal,
/// and the shared-file rule — `tui.json` keeps every key and entry that is
/// not ours.
final class OpencodePluginInstallServiceTests: XCTestCase {
    private static let bundledJS = Data("// localvoxtral opencode plugin (fixture)".utf8)

    private func tuiJSON(_ entries: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    private func service(
        state: OpencodePluginState,
        bundled: Data? = bundledJS
    ) -> (OpencodePluginInstallService, StubOpencodeFS) {
        let fs = StubOpencodeFS(state: state)
        let service = OpencodePluginInstallService(
            bundledPluginData: { bundled }, fileSystem: fs
        )
        return (service, fs)
    }

    // MARK: - Status derivation

    func testAbsentFileIsNotInstalled() {
        let (service, _) = service(state: OpencodePluginState())
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertEqual(
            OpencodePluginInstallService.sentence(for: .notInstalled), "Not installed."
        )
    }

    func testCopiedButUnlistedIsInstalledUnlisted() throws {
        let (service, _) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: false
        ))
        XCTAssertEqual(service.status(), .installedUnlisted)
        XCTAssertEqual(
            OpencodePluginInstallService.sentence(for: .installedUnlisted),
            "Installed, not listed in tui.json."
        )
    }

    func testCopiedAndListedIsInstalled() throws {
        let tui = try tuiJSON(["plugin": [OpencodePluginInstallService.tuiPluginEntry]])
        let (service, _) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: true,
            tuiData: tui
        ))
        XCTAssertEqual(service.status(), .installed)
        XCTAssertEqual(OpencodePluginInstallService.sentence(for: .installed), "Installed.")
    }

    func testUnreadablePluginFileIsUnknown() {
        let (service, _) = service(state: OpencodePluginState(
            pluginFileExists: true, pluginData: nil
        ))
        XCTAssertEqual(service.status(), .unknown)
    }

    func testUnparseableTUIIsUnknown() {
        let (service, _) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: true,
            tuiData: Data("garbage{".utf8)
        ))
        XCTAssertEqual(service.status(), .unknown)
    }

    // MARK: - tui.json pure logic

    func testTUIListingShapes() throws {
        XCTAssertEqual(OpencodePluginInstallService.tuiListsPlugin(in: nil), .notListed)
        let empty = try tuiJSON([:])
        XCTAssertEqual(OpencodePluginInstallService.tuiListsPlugin(in: empty), .notListed)
        let others = try tuiJSON(["plugin": ["./plugins/other.js"]])
        XCTAssertEqual(OpencodePluginInstallService.tuiListsPlugin(in: others), .notListed)
        let listed = try tuiJSON(["plugin": [
            "./plugins/other.js", OpencodePluginInstallService.tuiPluginEntry,
        ]])
        XCTAssertEqual(OpencodePluginInstallService.tuiListsPlugin(in: listed), .listed)
        XCTAssertEqual(
            OpencodePluginInstallService.tuiListsPlugin(in: Data("nope".utf8)), .unparseable
        )
        let misshapen = try tuiJSON(["plugin": "./plugins/localvoxtral.js"])
        XCTAssertEqual(
            OpencodePluginInstallService.tuiListsPlugin(in: misshapen), .unparseable
        )
    }

    func testAddingPreservesExistingEntries() throws {
        let existing = try tuiJSON([
            "theme": "dark",
            "plugin": ["./plugins/other.js"],
        ])
        let updated = try XCTUnwrap(OpencodePluginInstallService.tuiByAddingPlugin(to: existing))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        XCTAssertEqual(parsed["theme"] as? String, "dark", "other keys survive")
        XCTAssertEqual(
            Set((parsed["plugin"] as? [String]) ?? []),
            ["./plugins/other.js", OpencodePluginInstallService.tuiPluginEntry]
        )
    }

    func testAddingTwiceIsByteIdentical() throws {
        let once = try XCTUnwrap(OpencodePluginInstallService.tuiByAddingPlugin(to: nil))
        let twice = try XCTUnwrap(OpencodePluginInstallService.tuiByAddingPlugin(to: once))
        XCTAssertEqual(once, twice, "re-install changes nothing")
    }

    func testAddingRefusesAMisshapenPluginKey() throws {
        let misshapen = try tuiJSON(["plugin": "./plugins/localvoxtral.js"])
        XCTAssertNil(OpencodePluginInstallService.tuiByAddingPlugin(to: misshapen))
    }

    // MARK: - Install

    func testInstallCopiesAndLists() throws {
        let (service, fs) = service(state: OpencodePluginState(
            pluginsDirExists: false, configDirExists: false
        ))
        try service.install()
        XCTAssertTrue(fs.createdPluginsDir, "the plugins directory is created")
        XCTAssertTrue(fs.createdConfigDir, "the config directory is created")
        XCTAssertEqual(fs.writtenPlugin?.data, Self.bundledJS)
        XCTAssertEqual(fs.writtenPlugin?.permissions, 0o600)
        let tui = try XCTUnwrap(fs.writtenTUI?.data)
        XCTAssertEqual(OpencodePluginInstallService.tuiListsPlugin(in: tui), .listed)
        XCTAssertEqual(fs.writtenTUI?.permissions, 0o600)
        XCTAssertEqual(service.status(), .notInstalled, "the stub holds fixtures, not writes")
    }

    func testInstallKeepsExistingFileModes() throws {
        let tui = try tuiJSON(["plugin": ["./plugins/other.js"]])
        let (service, fs) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Data("stale".utf8),
            pluginPermissions: 0o644,
            tuiFileExists: true,
            tuiData: tui,
            tuiPermissions: 0o640
        ))
        try service.install()
        XCTAssertEqual(fs.writtenPlugin?.data, Self.bundledJS, "stale bytes are replaced")
        XCTAssertEqual(fs.writtenPlugin?.permissions, 0o644, "but the mode stays")
        XCTAssertEqual(fs.writtenTUI?.permissions, 0o640)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: fs.writtenTUI!.data) as? [String: Any]
        )
        XCTAssertTrue(
            ((parsed["plugin"] as? [String]) ?? []).contains("./plugins/other.js"),
            "the user's other plugin survives"
        )
    }

    func testInstallWithoutBundledBytesThrows() throws {
        let (service, fs) = service(
            state: OpencodePluginState(), bundled: nil
        )
        XCTAssertThrowsError(try service.install()) { error in
            XCTAssertEqual(
                error as? OpencodePluginInstallService.ServiceError, .bundledPluginUnavailable
            )
        }
        XCTAssertNil(fs.writtenPlugin)
        XCTAssertNil(fs.writtenTUI)
    }

    func testInstallRefusesSymlinks() throws {
        for state in [
            OpencodePluginState(pluginFileExists: true, pluginFileIsSymlink: true),
            OpencodePluginState(pluginsDirExists: true, pluginsDirIsSymlink: true),
            OpencodePluginState(tuiFileExists: true, tuiFileIsSymlink: true),
            OpencodePluginState(configDirExists: true, configDirIsSymlink: true),
        ] {
            let (service, fs) = service(state: state)
            XCTAssertThrowsError(try service.install()) { error in
                XCTAssertEqual(error as? OpencodePluginInstallService.ServiceError, .isSymlink)
            }
            XCTAssertNil(fs.writtenPlugin)
            XCTAssertNil(fs.writtenTUI)
        }
    }

    func testInstallRefusesUnreadableFiles() throws {
        for state in [
            OpencodePluginState(pluginFileExists: true, pluginData: nil),
            OpencodePluginState(tuiFileExists: true, tuiData: nil),
        ] {
            let (service, fs) = service(state: state)
            XCTAssertThrowsError(try service.install()) { error in
                XCTAssertEqual(error as? OpencodePluginInstallService.ServiceError, .unreadable)
            }
            XCTAssertNil(fs.writtenPlugin)
            XCTAssertNil(fs.writtenTUI)
        }
    }

    func testInstallRefusesAMisshapenTUI() throws {
        let misshapen = try tuiJSON(["plugin": "./plugins/localvoxtral.js"])
        let (service, fs) = service(state: OpencodePluginState(
            tuiFileExists: true, tuiData: misshapen
        ))
        XCTAssertThrowsError(try service.install()) { error in
            XCTAssertEqual(error as? OpencodePluginInstallService.ServiceError, .refused)
        }
        XCTAssertNil(fs.writtenTUI, "a config we cannot shape stays untouched")
    }

    // MARK: - Remove

    func testRemoveReversesBoth() throws {
        let tui = try XCTUnwrap(OpencodePluginInstallService.tuiByAddingPlugin(to: nil))
        let (service, fs) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: true,
            tuiData: tui,
            tuiPermissions: 0o600
        ))
        try service.remove()
        XCTAssertTrue(fs.deletedPlugin, "the copied file goes")
        XCTAssertTrue(fs.deletedTUI, "a tui.json holding only our entry is deleted, not emptied")
        XCTAssertNil(fs.writtenTUI)
    }

    func testRemoveKeepsOtherEntries() throws {
        let tui = try tuiJSON(["plugin": [
            "./plugins/other.js", OpencodePluginInstallService.tuiPluginEntry,
        ]])
        let (service, fs) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: true,
            tuiData: tui,
            tuiPermissions: 0o644
        ))
        try service.remove()
        XCTAssertTrue(fs.deletedPlugin)
        XCTAssertFalse(fs.deletedTUI, "other content keeps the file")
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: fs.writtenTUI!.data) as? [String: Any]
        )
        XCTAssertEqual(parsed["plugin"] as? [String], ["./plugins/other.js"])
        XCTAssertEqual(fs.writtenTUI?.permissions, 0o644)
    }

    func testRemoveRefusesAMisshapenTUI() throws {
        let misshapen = try tuiJSON(["plugin": 42])
        let (service, fs) = service(state: OpencodePluginState(
            pluginFileExists: true,
            pluginData: Self.bundledJS,
            tuiFileExists: true,
            tuiData: misshapen
        ))
        XCTAssertThrowsError(try service.remove()) { error in
            XCTAssertEqual(error as? OpencodePluginInstallService.ServiceError, .refused)
        }
        XCTAssertFalse(fs.deletedPlugin)
        XCTAssertFalse(fs.deletedTUI)
    }

    func testRemoveOnNothingInstalledIsANoOp() throws {
        let (service, fs) = service(state: OpencodePluginState())
        try service.remove()
        XCTAssertFalse(fs.deletedPlugin)
        XCTAssertFalse(fs.deletedTUI)
    }

    // MARK: - Live filesystem against a temp home

    func testLiveRoundTripInATempHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-opencode-test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let service = OpencodePluginInstallService(
            bundledPluginData: { Self.bundledJS },
            fileSystem: LiveOpencodePluginFileSystem(homeDirectoryURL: home)
        )
        XCTAssertEqual(service.status(), .notInstalled)
        try service.install()
        XCTAssertEqual(service.status(), .installed)
        try service.install()
        XCTAssertEqual(service.status(), .installed, "re-install is idempotent")
        try service.remove()
        XCTAssertEqual(service.status(), .notInstalled)
    }

    func testLiveRefusesASymlinkedConfigDir() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-opencode-link.\(UUID().uuidString)", isDirectory: true)
        let target = home.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".config", isDirectory: true),
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let service = OpencodePluginInstallService(
            bundledPluginData: { Self.bundledJS },
            fileSystem: LiveOpencodePluginFileSystem(homeDirectoryURL: home)
        )
        XCTAssertThrowsError(try service.install()) { error in
            XCTAssertEqual(error as? OpencodePluginInstallService.ServiceError, .isSymlink)
        }
    }
}

/// Fixture-driven test double for the opencode file system.
private final class StubOpencodeFS: OpencodePluginFileSystem, @unchecked Sendable {
    var state: OpencodePluginState
    var writtenPlugin: (data: Data, permissions: UInt16)?
    var writtenTUI: (data: Data, permissions: UInt16)?
    var createdPluginsDir = false
    var createdConfigDir = false
    var deletedPlugin = false
    var deletedTUI = false

    init(state: OpencodePluginState) { self.state = state }

    func readState() throws -> OpencodePluginState { state }
    func createPluginsDirectory(permissions: UInt16) throws { createdPluginsDir = true }
    func createConfigDirectory(permissions: UInt16) throws { createdConfigDir = true }
    func atomicWritePlugin(_ data: Data, permissions: UInt16) throws {
        writtenPlugin = (data, permissions)
    }
    func atomicWriteTUI(_ data: Data, permissions: UInt16) throws {
        writtenTUI = (data, permissions)
    }
    func deletePlugin() throws { deletedPlugin = true }
    func deleteTUI() throws { deletedTUI = true }
}
