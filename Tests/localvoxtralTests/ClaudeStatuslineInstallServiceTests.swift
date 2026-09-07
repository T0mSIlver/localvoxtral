import Foundation
import XCTest

@testable import localvoxtral

/// Installer tests for the Claude Code status line
/// (`ClaudeStatuslineInstallService`): create, idempotent re-apply, removal,
/// symlink refusal, unreadable refusal, and the foreign-statusline rule — the
/// row must never overwrite a script the user wrote.
final class ClaudeStatuslineInstallServiceTests: XCTestCase {
    private static let hookCommand =
        "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"

    private func settingsJSON(_ entries: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    // MARK: - Status derivation

    func testAbsentFileIsNotConfigured() {
        let service = ClaudeStatuslineInstallService(fileSystem: StubStatuslineFS(
            state: ClaudeStatuslineState(fileExists: false)
        ))
        XCTAssertEqual(service.status(), .notConfigured)
        XCTAssertEqual(ClaudeStatuslineInstallService.sentence(for: .notConfigured), "Not installed.")
    }

    func testOurEntryIsInstalled() throws {
        let existing = try XCTUnwrap(ClaudeStatuslineInstallService.updatedSettingsData(
            existing: nil, hookCommand: Self.hookCommand
        ))
        let service = ClaudeStatuslineInstallService(
            fileSystem: StubStatuslineFS(
                state: ClaudeStatuslineState(fileExists: true, data: existing)
            ),
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(service.status(), .installed)
        XCTAssertEqual(ClaudeStatuslineInstallService.sentence(for: .installed), "Installed.")
    }

    func testStalePathReportsUpdateInsteadOfInstalled() throws {
        // M2: the entry points at an app that moved — the path no longer
        // resolves, so the row must surface it instead of claiming health.
        let stale = "/Volumes/Old/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": stale],
        ])
        let staleService = ClaudeStatuslineInstallService(
            fileSystem: StubStatuslineFS(
                state: ClaudeStatuslineState(fileExists: true, data: existing)
            ),
            isExecutableFile: { _ in false }
        )
        XCTAssertEqual(staleService.status(), .stalePath)
        XCTAssertEqual(
            ClaudeStatuslineInstallService.sentence(for: .stalePath),
            "Installed, path no longer exists — Update."
        )
        let healthyService = ClaudeStatuslineInstallService(
            fileSystem: StubStatuslineFS(
                state: ClaudeStatuslineState(fileExists: true, data: existing)
            ),
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(healthyService.status(), .installed)
    }

    func testUpdateRewritesAStalePath() throws {
        // M2: Update on a stale entry rewrites the path (and keeps padding).
        let stale = "/Volumes/Old/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": stale, "padding": 2],
        ])
        let updated = try XCTUnwrap(ClaudeStatuslineInstallService.updatedSettingsData(
            existing: existing, hookCommand: Self.hookCommand
        ))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        let entry = try XCTUnwrap(parsed["statusLine"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, Self.hookCommand, "Update rewrites the path")
        XCTAssertEqual(entry["padding"] as? Int, 2, "padding survives the rewrite")
    }

    func testForeignCommandIsForeign() throws {
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": "~/.claude/my-statusline.sh"],
        ])
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: existing), .foreign
        )
        XCTAssertEqual(
            ClaudeStatuslineInstallService.sentence(for: .foreign),
            "Your own status line is configured."
        )
    }

    func testWrapperAroundOurBinaryIsStillForeign() throws {
        // The README's composition recipe wraps our binary inside the user's
        // own script. That script is theirs: re-applying must not replace it
        // with a bare command.
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": "sh ~/.claude/combined.sh"],
        ])
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: existing), .foreign
        )
    }

    func testSubstringMatchesAreForeign() throws {
        // B1: a longer flag, a wrapper name containing ours, and a command
        // that merely mentions both strings must never classify as ours.
        for command in [
            "/usr/local/bin/localvoxtral-claude-hook --statusline-compat",
            "localvoxtral-claude-hook-statusline --statusline",
            "echo localvoxtral-claude-hook --statusline",
        ] {
            let existing = try settingsJSON([
                "statusLine": ["type": "command", "command": command],
            ])
            XCTAssertEqual(
                ClaudeStatuslineInstallService.deriveStatus(settingsData: existing), .foreign,
                "must stay foreign: \(command)"
            )
        }
    }

    func testSubstringMatchesRefuseApplyAndRemove() throws {
        for command in [
            "/usr/local/bin/localvoxtral-claude-hook --statusline-compat",
            "localvoxtral-claude-hook-statusline --statusline",
            "echo localvoxtral-claude-hook --statusline",
        ] {
            let existing = try settingsJSON([
                "statusLine": ["type": "command", "command": command],
            ])
            let applyFS = StubStatuslineFS(state: ClaudeStatuslineState(
                fileExists: true, data: existing, permissions: 0o644
            ))
            XCTAssertThrowsError(
                try ClaudeStatuslineInstallService(fileSystem: applyFS)
                    .apply(hookCommand: Self.hookCommand)
            ) { error in
                XCTAssertEqual(error as? ClaudeStatuslineError, .refused, "\(command)")
            }
            XCTAssertNil(applyFS.written, "never overwritten: \(command)")
            let removeFS = StubStatuslineFS(state: ClaudeStatuslineState(
                fileExists: true, data: existing, permissions: 0o644
            ))
            XCTAssertThrowsError(
                try ClaudeStatuslineInstallService(fileSystem: removeFS).remove()
            ) { error in
                XCTAssertEqual(error as? ClaudeStatuslineError, .refused, "\(command)")
            }
            XCTAssertNil(removeFS.written, "never rewritten: \(command)")
            XCTAssertFalse(removeFS.deleted, "never deleted: \(command)")
        }
    }

    func testEditedOursRefusesInsteadOfDeleting() throws {
        // M3: the user customized our entry (a pipe, an extra flag) — the
        // entry stopped being purely ours, and Remove must refuse rather
        // than delete the customization.
        for command in [
            "\(Self.hookCommand) | jq -r .text",
            "\(Self.hookCommand) --extra",
        ] {
            let existing = try settingsJSON([
                "statusLine": ["type": "command", "command": command],
            ])
            XCTAssertEqual(
                ClaudeStatuslineInstallService.deriveStatus(settingsData: existing), .edited,
                "edited entry reads as edited: \(command)"
            )
            XCTAssertEqual(
                ClaudeStatuslineInstallService.sentence(for: .edited),
                "Edited by you; remove it in settings.json."
            )
            let applyFS = StubStatuslineFS(state: ClaudeStatuslineState(
                fileExists: true, data: existing, permissions: 0o644
            ))
            XCTAssertThrowsError(
                try ClaudeStatuslineInstallService(fileSystem: applyFS)
                    .apply(hookCommand: Self.hookCommand)
            ) { error in
                XCTAssertEqual(error as? ClaudeStatuslineError, .refused, "\(command)")
            }
            XCTAssertNil(applyFS.written, "an edited entry is never overwritten: \(command)")
            let removeFS = StubStatuslineFS(state: ClaudeStatuslineState(
                fileExists: true, data: existing, permissions: 0o644
            ))
            XCTAssertThrowsError(
                try ClaudeStatuslineInstallService(fileSystem: removeFS).remove()
            ) { error in
                XCTAssertEqual(error as? ClaudeStatuslineError, .refused, "\(command)")
            }
            XCTAssertNil(removeFS.written, "an edited entry is never rewritten: \(command)")
            XCTAssertFalse(removeFS.deleted, "an edited entry is never deleted: \(command)")
        }
    }

    func testNonCommandShapeIsForeign() throws {
        let existing = try settingsJSON(["statusLine": ["type": "unsupported"]])
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: existing), .foreign
        )
    }

    func testUnparseableFileIsUnknown() {
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: Data("not json{".utf8)),
            .unknown
        )
        XCTAssertEqual(
            ClaudeStatuslineInstallService.sentence(for: .unknown),
            "Could not read your Claude settings."
        )
    }

    func testExistingButUnreadableFileIsUnknown() {
        let service = ClaudeStatuslineInstallService(fileSystem: StubStatuslineFS(
            state: ClaudeStatuslineState(fileExists: true, data: nil)
        ))
        XCTAssertEqual(service.status(), .unknown)
    }

    func testMissingServiceIsUnknown() {
        XCTAssertEqual(ClaudeStatuslineInstallService(fileSystem: nil).status(), .unknown)
    }

    // MARK: - Preview

    func testPreviewRendersTheExactEntry() throws {
        let preview = try XCTUnwrap(ClaudeStatuslineInstallService.preview(
            hookCommand: Self.hookCommand
        ))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: String]
        )
        XCTAssertEqual(parsed["type"], "command")
        XCTAssertEqual(parsed["command"], Self.hookCommand)
    }

    func testPreviewIsNilWithoutAHookCommand() {
        XCTAssertNil(ClaudeStatuslineInstallService.preview(hookCommand: nil))
    }

    // MARK: - Apply

    func testApplyCreatesTheFileAt0600() throws {
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: false, directoryExists: false
        ))
        try ClaudeStatuslineInstallService(fileSystem: fs).apply(hookCommand: Self.hookCommand)
        XCTAssertTrue(fs.createdDirectory, "the .claude directory is created")
        let written = try XCTUnwrap(fs.written)
        XCTAssertEqual(written.permissions, 0o600, "a file we create gets 0600")
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: written.data), .installed
        )
    }

    func testApplyPreservesUnknownKeys() throws {
        let existing = try settingsJSON(["theme": "dark", "other": ["nested": true]])
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: existing, permissions: 0o644
        ))
        try ClaudeStatuslineInstallService(fileSystem: fs).apply(hookCommand: Self.hookCommand)
        let written = try XCTUnwrap(fs.written)
        XCTAssertEqual(written.permissions, 0o644, "an existing file keeps its mode")
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: written.data) as? [String: Any]
        )
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        XCTAssertEqual((parsed["other"] as? [String: Bool])?["nested"], true)
        XCTAssertEqual(
            ClaudeStatuslineInstallService.deriveStatus(settingsData: written.data), .installed
        )
    }

    func testUpdatePreservesOtherEntryKeys() throws {
        // M1: Claude Code's documented `padding` key (and any future key)
        // must survive our own offered Update.
        let existing = try settingsJSON([
            "statusLine": [
                "type": "command",
                "command": Self.hookCommand,
                "padding": 2,
                "futureKey": "keep-me",
            ],
        ])
        let updated = try XCTUnwrap(ClaudeStatuslineInstallService.updatedSettingsData(
            existing: existing, hookCommand: Self.hookCommand
        ))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        let entry = try XCTUnwrap(parsed["statusLine"] as? [String: Any])
        XCTAssertEqual(entry["padding"] as? Int, 2, "padding survives Update")
        XCTAssertEqual(entry["futureKey"] as? String, "keep-me", "unknown keys survive")
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["command"] as? String, Self.hookCommand)
    }

    func testReapplyIsByteIdentical() throws {
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(fileExists: false))
        let service = ClaudeStatuslineInstallService(fileSystem: fs)
        try service.apply(hookCommand: Self.hookCommand)
        let first = try XCTUnwrap(fs.written?.data)
        fs.state = ClaudeStatuslineState(fileExists: true, data: first, permissions: 0o600)
        fs.written = nil
        try service.apply(hookCommand: Self.hookCommand)
        XCTAssertEqual(fs.written?.data, first, "a second run changes nothing")
    }

    func testApplyRefusesAForeignEntry() throws {
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": "~/.claude/mine.sh"],
        ])
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: existing, permissions: 0o644
        ))
        XCTAssertThrowsError(
            try ClaudeStatuslineInstallService(fileSystem: fs).apply(hookCommand: Self.hookCommand)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatuslineError, .refused)
        }
        XCTAssertNil(fs.written, "a foreign status line is never overwritten")
    }

    func testApplyRefusesUnparseableJSON() throws {
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: Data("garbage{".utf8), permissions: 0o644
        ))
        XCTAssertThrowsError(
            try ClaudeStatuslineInstallService(fileSystem: fs).apply(hookCommand: Self.hookCommand)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatuslineError, .refused)
        }
        XCTAssertNil(fs.written)
    }

    func testApplyRefusesSymlinks() throws {
        for state in [
            ClaudeStatuslineState(fileExists: true, fileIsSymlink: true),
            ClaudeStatuslineState(fileExists: false, directoryIsSymlink: true),
        ] {
            let fs = StubStatuslineFS(state: state)
            XCTAssertThrowsError(
                try ClaudeStatuslineInstallService(fileSystem: fs)
                    .apply(hookCommand: Self.hookCommand)
            ) { error in
                XCTAssertEqual(error as? ClaudeStatuslineError, .isSymlink)
            }
            XCTAssertNil(fs.written, "nothing may be written through a link")
        }
    }

    func testApplyRefusesAnUnreadableFile() throws {
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: nil
        ))
        XCTAssertThrowsError(
            try ClaudeStatuslineInstallService(fileSystem: fs).apply(hookCommand: Self.hookCommand)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatuslineError, .unreadable)
        }
        XCTAssertNil(fs.written, "an unreadable file is never blanked")
    }

    // MARK: - Remove

    func testCreateThenRemoveReturnsToAbsent() throws {
        // Byte-identical removal for the file we created: absent before,
        // absent after.
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(fileExists: false))
        let service = ClaudeStatuslineInstallService(fileSystem: fs)
        try service.apply(hookCommand: Self.hookCommand)
        fs.state = ClaudeStatuslineState(
            fileExists: true, data: fs.written?.data, permissions: 0o600
        )
        fs.written = nil
        try service.remove()
        XCTAssertTrue(fs.deleted, "a file holding only our entry is deleted")
        XCTAssertNil(fs.written)
    }

    func testRemoveRestoresAPreExistingFileSemantically() throws {
        // A file the user had keeps every other key; only our entry goes.
        // (Formatting normalizes through the JSON round-trip; the contract is
        // semantic preservation, pinned here on parsed values.)
        let before = try settingsJSON(["theme": "dark"])
        let installed = try XCTUnwrap(ClaudeStatuslineInstallService.updatedSettingsData(
            existing: before, hookCommand: Self.hookCommand
        ))
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: installed, permissions: 0o644
        ))
        try ClaudeStatuslineInstallService(fileSystem: fs).remove()
        let written = try XCTUnwrap(fs.written)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: written.data) as? [String: Any]
        )
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        XCTAssertNil(parsed["statusLine"], "only our key goes")
    }

    func testRemoveLeavesAForeignEntryUntouched() throws {
        let existing = try settingsJSON([
            "statusLine": ["type": "command", "command": "~/.claude/mine.sh"],
        ])
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: existing, permissions: 0o644
        ))
        XCTAssertThrowsError(
            try ClaudeStatuslineInstallService(fileSystem: fs).remove()
        ) { error in
            XCTAssertEqual(error as? ClaudeStatuslineError, .refused)
        }
        XCTAssertNil(fs.written)
        XCTAssertFalse(fs.deleted)
    }

    func testRemoveWithNoEntryWritesNothing() throws {
        // m3: a file that never had our entry must not be rewritten with
        // byte-identical content — no mtime churn, no race window.
        let existing = try settingsJSON(["theme": "dark"])
        XCTAssertEqual(
            ClaudeStatuslineInstallService.removalSettingsData(existing: existing), .noChange
        )
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: existing, permissions: 0o644
        ))
        XCTAssertNoThrow(try ClaudeStatuslineInstallService(fileSystem: fs).remove())
        XCTAssertNil(fs.written, "no write call when the entry is absent")
        XCTAssertFalse(fs.deleted)
    }

    func testRemoveOnAnAbsentFileIsANoOp() throws {
        let fs = StubStatuslineFS(state: ClaudeStatuslineState(fileExists: false))
        try ClaudeStatuslineInstallService(fileSystem: fs).remove()
        XCTAssertNil(fs.written)
        XCTAssertFalse(fs.deleted)
    }

    // MARK: - Live filesystem against a temp home

    func testLiveRoundTripInATempHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-statusline-test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // M2: status is `.installed` only when the configured path resolves,
        // so the live round-trip uses a real executable temp file as the hook.
        let hook = home.appendingPathComponent("localvoxtral-claude-hook", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: hook.path, contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        ))
        let hookCommand = "\(hook.path) --statusline"

        let service = ClaudeStatuslineInstallService(
            fileSystem: LiveClaudeStatuslineFileSystem(homeDirectoryURL: home)
        )
        XCTAssertEqual(service.status(), .notConfigured)
        try service.apply(hookCommand: hookCommand)
        XCTAssertEqual(service.status(), .installed)
        try service.apply(hookCommand: hookCommand)
        XCTAssertEqual(service.status(), .installed)
        try service.remove()
        XCTAssertEqual(service.status(), .notConfigured)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/settings.json").path
        ))
    }

    func testLiveRefusesASymlinkedClaudeDir() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-statusline-link.\(UUID().uuidString)", isDirectory: true)
        let target = home.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude", isDirectory: true), withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let service = ClaudeStatuslineInstallService(
            fileSystem: LiveClaudeStatuslineFileSystem(homeDirectoryURL: home)
        )
        XCTAssertThrowsError(try service.apply(hookCommand: Self.hookCommand)) { error in
            XCTAssertEqual(error as? ClaudeStatuslineError, .isSymlink)
        }
    }
}

/// Fixture-driven test double for the statusline file system.
private final class StubStatuslineFS: ClaudeStatuslineFileSystem, @unchecked Sendable {
    var state: ClaudeStatuslineState
    var written: (data: Data, permissions: UInt16)?
    var createdDirectory = false
    var deleted = false

    init(state: ClaudeStatuslineState) { self.state = state }

    func readState() throws -> ClaudeStatuslineState { state }
    func createDirectory(permissions: UInt16) throws { createdDirectory = true }
    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        written = (data, permissions)
    }
    func deleteFile() throws { deleted = true }
}
