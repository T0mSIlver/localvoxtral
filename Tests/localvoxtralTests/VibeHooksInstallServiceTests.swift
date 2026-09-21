import Foundation
import XCTest

@testable import localvoxtral

/// In-memory `~/.vibe`: the two files the service touches, and a log of what
/// it did to them.
private final class StubVibeFS: VibeHooksFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: VibeHooksState
    private var _operations: [String] = []

    init(state: VibeHooksState) { _state = state }

    /// Applied to the state on the Nth `readState` call (1-based), to play an
    /// editor saving between the service's read and its write.
    var mutateOnRead: (call: Int, change: @Sendable (inout VibeHooksState) -> Void)?
    private var reads = 0

    var state: VibeHooksState { lock.withLock { _state } }
    var operations: [String] { lock.withLock { _operations } }
    var hooksText: String? { state.hooksData.map { String(decoding: $0, as: UTF8.self) } }

    func readState() throws -> VibeHooksState {
        lock.withLock {
            reads += 1
            if let mutateOnRead, mutateOnRead.call == reads { mutateOnRead.change(&_state) }
            return _state
        }
    }

    func createShimDirectory(permissions: UInt16) throws {
        lock.withLock {
            _operations.append("mkdir \(String(permissions, radix: 8))")
            _state.shimDirExists = true
        }
    }

    func atomicWriteShim(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write shim \(String(permissions, radix: 8))")
            _state.shimFileExists = true
            _state.shimData = data
            _state.shimPermissions = permissions
        }
    }

    func atomicWriteHooks(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write hooks \(String(permissions, radix: 8))")
            _state.hooksFileExists = true
            _state.hooksData = data
            _state.hooksPermissions = permissions
        }
    }

    func deleteShim() throws {
        lock.withLock {
            _operations.append("delete shim")
            _state.shimFileExists = false
            _state.shimData = nil
        }
    }

    func deleteHooks() throws {
        lock.withLock {
            _operations.append("delete hooks")
            _state.hooksFileExists = false
            _state.hooksData = nil
        }
    }
}

final class VibeHooksInstallServiceTests: XCTestCase {
    private static let shim = Data("#!/bin/sh\n# fixture shim\n".utf8)
    private static let block = """
    # >>> localvoxtral >>>
    [[hooks]]
    name = "localvoxtral-turn"
    type = "post_agent"
    command = "sh \\"$HOME/.vibe/localvoxtral/publish.sh\\""
    # <<< localvoxtral <<<

    """
    private static let userHooks = """
    [[hooks]]
    name = "deny-rm-rf"
    type = "pre_tool"
    match = "bash"
    command = "python guard.py"

    """

    private func service(
        state: VibeHooksState,
        shim: Data? = shim,
        block: String? = block
    ) -> (VibeHooksInstallService, StubVibeFS) {
        let fs = StubVibeFS(state: state)
        return (
            VibeHooksInstallService(
                bundledShimData: { shim }, bundledHooksBlock: { block }, fileSystem: fs
            ),
            fs
        )
    }

    private func installed(hooks: String = block, shim: Data = shim) -> VibeHooksState {
        VibeHooksState(
            shimFileExists: true, shimData: shim, shimPermissions: 0o700,
            hooksFileExists: true, hooksData: Data(hooks.utf8), hooksPermissions: 0o644
        )
    }

    // MARK: - Status

    func testStatusCoversEveryHalfInstalledShape() {
        XCTAssertEqual(service(state: VibeHooksState()).0.status(), .notInstalled)
        XCTAssertEqual(service(state: installed()).0.status(), .installed)
        XCTAssertEqual(
            service(state: VibeHooksState(shimFileExists: true, shimData: Self.shim)).0.status(),
            .shimWithoutHooks
        )
        XCTAssertEqual(
            service(state: VibeHooksState(hooksFileExists: true, hooksData: Data(Self.block.utf8))).0.status(),
            .hooksWithoutShim
        )
        // Someone else's hooks.toml with no block of ours is not an install.
        XCTAssertEqual(
            service(state: VibeHooksState(hooksFileExists: true, hooksData: Data(Self.userHooks.utf8))).0.status(),
            .notInstalled
        )
    }

    func testAStaleShimOrAStaleBlockIsAnUpdate() {
        XCTAssertEqual(service(state: installed(shim: Data("old".utf8))).0.status(), .updateAvailable)
        let oldBlock = Self.block.replacingOccurrences(of: "post_agent", with: "post_tool")
        XCTAssertEqual(service(state: installed(hooks: oldBlock)).0.status(), .updateAvailable)
    }

    func testUnreadableNonUTF8AndUnpairedMarkersAreUnknown() {
        XCTAssertEqual(
            service(state: VibeHooksState(hooksFileExists: true, hooksData: nil)).0.status(), .unknown
        )
        XCTAssertEqual(
            service(state: VibeHooksState(shimFileExists: true, shimData: nil)).0.status(), .unknown
        )
        XCTAssertEqual(
            service(state: VibeHooksState(hooksFileExists: true, hooksData: Data([0xFF, 0xFE]))).0.status(),
            .unknown
        )
        let unpaired = "# >>> localvoxtral >>>\n[[hooks]]\n"
        XCTAssertEqual(
            service(state: VibeHooksState(hooksFileExists: true, hooksData: Data(unpaired.utf8))).0.status(),
            .unknown
        )
        XCTAssertEqual(VibeHooksInstallService().status(), .unknown)
    }

    func testButtonsFollowTheStatus() {
        XCTAssertNil(VibeHooksInstallService.setupButtonTitle(for: .installed))
        XCTAssertEqual(VibeHooksInstallService.setupButtonTitle(for: .updateAvailable), "Update…")
        XCTAssertEqual(VibeHooksInstallService.setupButtonTitle(for: .hooksWithoutShim), "Set up…")
        XCTAssertFalse(VibeHooksInstallService.offersRemove(for: .notInstalled))
        XCTAssertTrue(VibeHooksInstallService.offersRemove(for: .shimWithoutHooks))
    }

    // MARK: - Install

    func testInstallIntoAnEmptyHomeCreatesBothFiles() throws {
        let (service, fs) = service(state: VibeHooksState(shimDirExists: false))
        try service.install()
        XCTAssertEqual(fs.operations, ["mkdir 700", "write shim 700", "write hooks 600"])
        XCTAssertEqual(fs.state.shimData, Self.shim)
        XCTAssertEqual(fs.hooksText, Self.block)
        XCTAssertEqual(service.status(), .installed)
    }

    func testInstallAppendsAfterTheUsersHooksAndKeepsTheirBytesAndMode() throws {
        let (service, fs) = service(state: VibeHooksState(
            hooksFileExists: true, hooksData: Data(Self.userHooks.utf8), hooksPermissions: 0o644
        ))
        try service.install()
        XCTAssertEqual(fs.hooksText, Self.userHooks + "\n" + Self.block)
        XCTAssertEqual(fs.state.hooksPermissions, 0o644)
    }

    func testReinstallIsByteIdenticalAndAnUpdateReplacesTheBlockInPlace() throws {
        let original = Self.userHooks + "\n" + Self.block + "\n[[hooks]]\nname = \"after\"\n"
        let (service, fs) = service(state: installed(hooks: original))
        try service.install()
        XCTAssertEqual(fs.hooksText, original)

        let stale = original.replacingOccurrences(of: "post_agent", with: "post_tool")
        let (updating, updatedFS) = self.service(state: installed(hooks: stale))
        try updating.install()
        XCTAssertEqual(updatedFS.hooksText, original, "the block is replaced where it stood")
    }

    func testInstallRefusesRatherThanWritePastSomethingItDoesNotUnderstand() {
        let cases: [(String, VibeHooksState, VibeHooksInstallService.ServiceError)] = [
            ("symlinked hooks.toml", VibeHooksState(hooksFileExists: true, hooksFileIsSymlink: true), .isSymlink),
            ("symlinked ~/.vibe", VibeHooksState(vibeDirIsSymlink: true), .isSymlink),
            ("symlinked shim", VibeHooksState(shimFileExists: true, shimFileIsSymlink: true), .isSymlink),
            ("symlinked shim dir", VibeHooksState(shimDirIsSymlink: true), .isSymlink),
            ("unreadable hooks.toml", VibeHooksState(hooksFileExists: true, hooksData: nil), .unreadable),
            ("non-UTF-8", VibeHooksState(hooksFileExists: true, hooksData: Data([0xFF])), .refused(.notUTF8)),
            (
                "unpaired marker",
                VibeHooksState(hooksFileExists: true, hooksData: Data("# >>> localvoxtral >>>\n".utf8)),
                .refused(.unpairedMarkers)
            ),
            (
                "our hook name outside the block",
                VibeHooksState(
                    hooksFileExists: true,
                    hooksData: Data("[[hooks]]\nname = \"localvoxtral-turn\"\ntype = \"post_agent\"\n".utf8)
                ),
                .refused(.conflictingHookName)
            ),
            (
                "our hook name under a quoted key, literal string",
                VibeHooksState(
                    hooksFileExists: true,
                    hooksData: Data("[[hooks]]\n\"name\" = 'localvoxtral-files'\n".utf8)
                ),
                .refused(.conflictingHookName)
            ),
            (
                "a multi-line name could spell ours on its next line",
                VibeHooksState(
                    hooksFileExists: true,
                    hooksData: Data("[[hooks]]\nname = \"\"\"\nlocalvoxtral-turn\"\"\"\n".utf8)
                ),
                .refused(.conflictingHookName)
            ),
            (
                "hooks as a plain array: appending [[hooks]] would break the whole file",
                VibeHooksState(
                    hooksFileExists: true,
                    hooksData: Data("hooks = [ { name = \"mine\", type = \"pre_tool\", command = \"guard.py\" } ]\n".utf8)
                ),
                .refused(.hooksIsNotAnArrayOfTables)
            ),
            (
                "hooks as a plain table",
                VibeHooksState(hooksFileExists: true, hooksData: Data("[hooks]\nname = \"mine\"\n".utf8)),
                .refused(.hooksIsNotAnArrayOfTables)
            ),
            (
                "a string left open at the end would swallow the block",
                VibeHooksState(hooksFileExists: true, hooksData: Data("note = \"\"\"\nnever closed\n".utf8)),
                .refused(.unclosedString)
            ),
            (
                "markers inside a multi-line string are the user's data",
                VibeHooksState(
                    hooksFileExists: true,
                    hooksData: Data(
                        "note = \"\"\"\n# >>> localvoxtral >>>\nuser data\n# <<< localvoxtral <<<\n\"\"\"\n".utf8
                    )
                ),
                .refused(.unclosedString)
            ),
            (
                "a key right after the block belongs to our last table",
                VibeHooksState(hooksFileExists: true, hooksData: Data((Self.block + "custom = 2\n").utf8)),
                .refused(.keyAfterBlock)
            ),
        ]
        for (label, state, expected) in cases {
            let (service, fs) = service(state: state)
            XCTAssertThrowsError(try service.install(), label) { error in
                XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, expected, label)
            }
            XCTAssertEqual(fs.operations, [], "\(label): nothing may be written")
        }
    }

    func testNamesThatMerelyLookLikeOursDoNotBlockAnInstall() throws {
        // Vibe deduplicates by EXACT name, so these are the user's own.
        let theirs = "namespace = \"localvoxtral-turn\"\n\n[[hooks]]\nname = \"localvoxtral-custom\"\n"
            + "# name = \"localvoxtral-turn\"\n"
        let (service, fs) = service(state: VibeHooksState(hooksFileExists: true, hooksData: Data(theirs.utf8)))
        try service.install()
        XCTAssertEqual(fs.hooksText, theirs + "\n" + Self.block)
        XCTAssertEqual(service.status(), .installed)
    }

    func testAConflictIsReportedAndOffersNoButtonThatWouldRefuse() {
        let duplicate = Self.block + "\n[[hooks]]\nname = \"localvoxtral-turn\"\ntype = \"post_agent\"\n"
        XCTAssertEqual(service(state: installed(hooks: duplicate)).0.status(), .conflictingHooks)
        XCTAssertEqual(
            service(state: installed(hooks: Self.block + "custom = 2\n")).0.status(), .conflictingHooks
        )
        XCTAssertNil(VibeHooksInstallService.setupButtonTitle(for: .conflictingHooks))
        XCTAssertFalse(VibeHooksInstallService.offersRemove(for: .conflictingHooks))
        XCTAssertEqual(
            VibeHooksInstallService.sentence(for: .conflictingHooks), "hooks.toml needs a manual fix."
        )
        // A comment or a new table after the block is fine.
        let fine = Self.block + "\n# mine\n[[hooks]]\nname = \"after\"\n"
        XCTAssertEqual(service(state: installed(hooks: fine)).0.status(), .installed)
    }

    func testTheShippedHookNamesAreTheOnesTheCollisionCheckKnows() throws {
        let blockURL = try XCTUnwrap(
            ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeHooksBlockFileName)
        )
        let names = try String(contentsOf: blockURL, encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("name = ") }
            .map { $0.dropFirst("name = \"".count).dropLast() }.map(String.init)
        XCTAssertEqual(Set(names), VibeHooksInstallService.hookNames)
    }

    func testAnEditThatLandsBetweenReadAndWriteIsNotOverwritten() {
        let (installing, installFS) = service(state: VibeHooksState(
            hooksFileExists: true, hooksData: Data(Self.userHooks.utf8)
        ))
        installFS.mutateOnRead = (2, { $0.hooksData = Data((Self.userHooks + "# saved just now\n").utf8) })
        XCTAssertThrowsError(try installing.install()) { error in
            XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, .changedOnDisk)
        }
        XCTAssertEqual(installFS.operations, [])

        let (removing, removeFS) = service(state: installed())
        removeFS.mutateOnRead = (2, { $0.hooksData = Data((Self.block + "\n[[hooks]]\nname = \"new\"\n").utf8) })
        XCTAssertThrowsError(try removing.remove()) { error in
            XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, .changedOnDisk)
        }
        XCTAssertEqual(removeFS.operations, [])
    }

    func testEveryRefusalTellsTheUserWhichFixApplies() {
        // The alert shows `String(describing:)`, so that has to be a sentence.
        let refusals: [VibeHooksInstallService.Refusal] = [
            .notUTF8, .unpairedMarkers, .unclosedString, .conflictingHookName, .keyAfterBlock,
            .hooksIsNotAnArrayOfTables,
        ]
        let sentences = refusals.map { String(describing: VibeHooksInstallService.ServiceError.refused($0)) }
        XCTAssertEqual(Set(sentences).count, refusals.count)
        for sentence in sentences + [String(describing: VibeHooksInstallService.ServiceError.changedOnDisk)] {
            XCTAssertTrue(sentence.contains("hooks.toml"), sentence)
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
        }
    }

    func testAStaticHooksValueShowsAsAConflictNotAsInstalled() {
        let existing = "hooks = []\n" + Self.block
        XCTAssertEqual(service(state: installed(hooks: existing)).0.status(), .conflictingHooks)
    }

    func testInstallNeedsBothBundledFilesAndAWellFormedBlock() {
        for (shim, block) in [(nil, Self.block), (Self.shim, nil), (Self.shim, "[[hooks]]\nname = \"x\"\n")]
            as [(Data?, String?)] {
            let (service, fs) = service(state: VibeHooksState(), shim: shim, block: block)
            XCTAssertThrowsError(try service.install()) { error in
                XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, .bundledFilesUnavailable)
            }
            XCTAssertEqual(fs.operations, [])
        }
    }

    // MARK: - Remove

    func testRemoveRestoresTheUsersFileByteForByte() throws {
        let (service, fs) = service(state: VibeHooksState(
            hooksFileExists: true, hooksData: Data(Self.userHooks.utf8), hooksPermissions: 0o644
        ))
        try service.install()
        try service.remove()
        XCTAssertEqual(fs.hooksText, Self.userHooks)
        XCTAssertFalse(fs.state.shimFileExists)
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertEqual(
            Array(fs.operations.suffix(2)), ["write hooks 644", "delete shim"],
            "the block goes before the script it names"
        )
    }

    func testRemoveDeletesAHooksFileThatHeldOnlyOurBlock() throws {
        let (service, fs) = service(state: installed())
        try service.remove()
        XCTAssertEqual(fs.operations, ["delete hooks", "delete shim"])
    }

    func testRemoveLeavesAFileWithoutOurBlockUntouched() throws {
        let (service, fs) = service(state: VibeHooksState(
            shimFileExists: true, shimData: Self.shim,
            hooksFileExists: true, hooksData: Data(Self.userHooks.utf8)
        ))
        try service.remove()
        XCTAssertEqual(fs.operations, ["delete shim"])
    }

    func testRemoveRefusesUnpairedMarkersAndKeepsTheShim() {
        let (service, fs) = service(state: installed(hooks: "# >>> localvoxtral >>>\n[[hooks]]\n"))
        XCTAssertThrowsError(try service.remove()) { error in
            XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, .refused(.unpairedMarkers))
        }
        XCTAssertEqual(fs.operations, [])
    }

    // MARK: - The shipped files

    func testTheShippedBlockInstallsAndReadsBackAsCurrent() throws {
        let shimURL = try XCTUnwrap(ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeShimFileName))
        let blockURL = try XCTUnwrap(
            ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeHooksBlockFileName)
        )
        let shim = try Data(contentsOf: shimURL)
        let block = try String(contentsOf: blockURL, encoding: .utf8)
        let (service, fs) = service(
            state: VibeHooksState(hooksFileExists: true, hooksData: Data(Self.userHooks.utf8)),
            shim: shim, block: block
        )
        try service.install()
        XCTAssertEqual(service.status(), .installed)
        XCTAssertTrue(try XCTUnwrap(fs.hooksText).hasSuffix(block))
        // The command the block names is the path the live file system writes.
        XCTAssertTrue(block.contains("$HOME/\(LiveVibeHooksFileSystem.shimRelativePath)"))
        XCTAssertEqual(VibeHooksInstallService.consentSentence.contains("~/.vibe/hooks.toml"), true)
    }
}

// MARK: - Packaged lookup

final class VibePackagedFilesTests: XCTestCase {
    /// `vibeFileURL` falls back to the repo checkout, so a test that uses its
    /// defaults cannot tell whether the PACKAGED locations resolve. These pass
    /// fixture directories instead.
    func testBothPackagedLocationsResolveBeforeTheCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for location in ["bundle", "app"] {
            let directory = root.appendingPathComponent(location)
                .appendingPathComponent(ClaudePluginAssets.vibePackagedDirectoryName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(location.utf8).write(to: directory.appendingPathComponent("publish.sh"))
        }
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        func resolved(resources: String, bundle: String) throws -> String {
            let url = try XCTUnwrap(ClaudePluginAssets.vibeFileURL(
                named: "publish.sh",
                resourcesURL: root.appendingPathComponent(resources),
                bundleResourcesURL: root.appendingPathComponent(bundle)
            ))
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(try resolved(resources: "app", bundle: "bundle"), "bundle")
        XCTAssertEqual(try resolved(resources: "app", bundle: "empty"), "app")
    }

    func testPackagingCopiesBothFilesWhereTheLookupReads() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/package_app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("Contents/Resources/\(ClaudePluginAssets.vibePackagedDirectoryName)/"))
        for name in [ClaudePluginAssets.vibeShimFileName, ClaudePluginAssets.vibeHooksBlockFileName] {
            XCTAssertTrue(script.contains("$VIBE_HOOKS_SOURCE/\(name)"), name)
        }
    }
}

// MARK: - Live file system

final class LiveVibeHooksFileSystemTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func liveService() -> VibeHooksInstallService {
        VibeHooksInstallService(
            bundledShimData: { Data("#!/bin/sh\n".utf8) },
            bundledHooksBlock: { "# >>> localvoxtral >>>\n[[hooks]]\n# <<< localvoxtral <<<\n" },
            fileSystem: LiveVibeHooksFileSystem(homeDirectoryURL: home)
        )
    }

    func testInstallThenRemoveOnARealDirectoryLeavesNothingBehind() throws {
        let service = liveService()
        XCTAssertEqual(service.status(), .notInstalled)
        try service.install()
        XCTAssertEqual(service.status(), .installed)

        let shim = home.appendingPathComponent(".vibe/localvoxtral/publish.sh").path
        let attributes = try FileManager.default.attributesOfItem(atPath: shim)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)

        try service.remove()
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".vibe/localvoxtral").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".vibe/hooks.toml").path))
    }

    func testASymlinkedVibeDirectoryIsRefused() throws {
        let real = home.appendingPathComponent("dotfiles-vibe")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".vibe"), withDestinationURL: real
        )
        XCTAssertThrowsError(try liveService().install()) { error in
            XCTAssertEqual(error as? VibeHooksInstallService.ServiceError, .isSymlink)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), [])
    }
}

// MARK: - Sidebar

final class VibeSidebarStatusTests: XCTestCase {
    func testTheDotFollowsTheInstallState() {
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .installed), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .updateAvailable), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .hooksWithoutShim), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .conflictingHooks), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .notInstalled), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.vibeDot(status: .unknown), .grey)
    }
}
