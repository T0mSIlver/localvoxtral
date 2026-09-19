import Foundation
import XCTest

@testable import localvoxtral

/// Combine: the user's own status line wrapped in a script that also runs our
/// connection indicator, and Remove putting their command back exactly.
final class ClaudeStatuslineCombineTests: XCTestCase {
    private static let hook = "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook"
    private static let hookCommand = hook + " --statusline"
    /// Quotes of both kinds, a `$`, and a pipe: the command must round-trip
    /// through the script byte for byte.
    private static let original = #"bash -c 'echo "$HOME" it'\''s' | tr a-z A-Z"#

    private func settings(_ entry: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var object = extra
        object["statusLine"] = entry
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func entry(of data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any]
        return try XCTUnwrap(object?["statusLine"] as? [String: Any])
    }

    private func service(
        settings: MemoryStatuslineFS, script: MemoryStatuslineFS
    ) -> ClaudeStatuslineInstallService {
        ClaudeStatuslineInstallService(
            fileSystem: settings, scriptFileSystem: script, isExecutableFile: { _ in true }
        )
    }

    // MARK: - The script text

    func testTheScriptRoundTripsTheUsersCommandExactly() {
        let text = ClaudeStatuslineCombine.script(original: Self.original, hookPath: Self.hook)
        let parsed = ClaudeStatuslineCombine.parse(text)
        XCTAssertEqual(parsed?.original, Self.original)
        XCTAssertEqual(parsed?.hookPath, Self.hook)
        XCTAssertNil(
            ClaudeStatuslineCombine.parse(text.replacingOccurrences(of: "sh -c", with: "bash -c")),
            "an edited script is not ours to rewrite or delete"
        )
    }

    /// Runs the real script with /bin/sh: the user's line, two spaces, the
    /// indicator; and the user's line alone once the app is gone.
    func testTheScriptPrintsBothOnOneLineAndFailsOpenWithoutTheApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-combine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = root.appendingPathComponent("localvoxtral-claude-hook")
        // Echoes what it read, proving the hook sees the same stdin.
        try Data("#!/bin/sh\nread -r line; printf 'lvx %s' \"$line\"\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let script = root.appendingPathComponent("combined.sh")
        let original = #"read -r line; printf 'mine %s\n' "$line""#

        func run() throws -> String {
            try Data(ClaudeStatuslineCombine.script(original: original, hookPath: hook.path).utf8)
                .write(to: script)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("{\"session_id\":\"s1\"}".utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        XCTAssertEqual(try run(), "mine {\"session_id\":\"s1\"}  lvx {\"session_id\":\"s1\"}\n")
        try FileManager.default.removeItem(at: hook)
        XCTAssertEqual(try run(), "mine {\"session_id\":\"s1\"}\n", "no app, the user's line alone")
    }

    // MARK: - Combine, update, remove

    func testCombineThenRemoveRestoresTheUsersEntry() throws {
        let settingsFS = MemoryStatuslineFS(data: try settings(
            ["type": "command", "command": Self.original, "padding": 1], extra: ["model": "opus"]
        ))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .foreign)
        XCTAssertEqual(ClaudeStatuslineInstallService.setupButtonTitle(for: .foreign), "Combine…")

        try service.combine(hookCommand: Self.hookCommand)
        XCTAssertEqual(scriptFS.permissions, 0o700)
        let combined = try entry(of: settingsFS.data)
        XCTAssertEqual(combined["command"] as? String, "~/.claude/localvoxtral-statusline.sh")
        XCTAssertEqual(combined["padding"] as? Int, 1, "the entry's other keys stay")
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combined)
        XCTAssertNil(ClaudeStatuslineInstallService.setupButtonTitle(for: .combined))
        XCTAssertTrue(ClaudeStatuslineInstallService.offersRemove(for: .combined))

        try service.remove()
        let restored = try entry(of: settingsFS.data)
        XCTAssertEqual(restored["command"] as? String, Self.original)
        XCTAssertEqual(restored["padding"] as? Int, 1)
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(settingsFS.data)) as? [String: Any]
        XCTAssertEqual(object?["model"] as? String, "opus")
        XCTAssertNil(scriptFS.data, "the script is deleted")
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .foreign)
    }

    func testAMovedAppMakesTheCombinedScriptOutdatedAndUpdateFixesIt() throws {
        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original]))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        let oldHook = "/tmp/try-pr/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        try service.combine(hookCommand: oldHook)

        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combinedOutdated)
        XCTAssertEqual(ClaudeStatuslineInstallService.setupButtonTitle(for: .combinedOutdated), "Update…")
        try service.updateCombined(hookCommand: Self.hookCommand)
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combined)
        XCTAssertEqual(
            ClaudeStatuslineCombine.parse(String(decoding: try XCTUnwrap(scriptFS.data), as: UTF8.self))?.original,
            Self.original, "the user's command survives the update"
        )
    }

    func testAMissingOrEditedScriptIsBrokenAndRemoveRefuses() throws {
        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original]))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        try service.combine(hookCommand: Self.hookCommand)

        scriptFS.data = Data("#!/bin/sh\necho mine\n".utf8)
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combinedBroken)
        XCTAssertThrowsError(try service.remove(), "the user's command lives only in the script")
        XCTAssertNil(ClaudeStatuslineInstallService.setupButtonTitle(for: .combinedBroken))
        XCTAssertFalse(ClaudeStatuslineInstallService.offersRemove(for: .combinedBroken))

        scriptFS.data = nil
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combinedBroken)
    }

    func testCombineNeverOverwritesAScriptItDidNotWrite() throws {
        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original]))
        let scriptFS = MemoryStatuslineFS(data: Data("#!/bin/sh\necho someone else's\n".utf8))
        let before = settingsFS.data
        XCTAssertThrowsError(
            try service(settings: settingsFS, script: scriptFS).combine(hookCommand: Self.hookCommand)
        )
        XCTAssertEqual(scriptFS.data, Data("#!/bin/sh\necho someone else's\n".utf8))
        XCTAssertEqual(settingsFS.data, before, "settings untouched when the script refuses")
    }

    /// A command may hold newlines; the script keeps them, and Remove still
    /// finds the whole command.
    func testAMultilineCommandSurvivesCombineAndRemove() throws {
        // Holds a line starting `hook=` and one starting `input=`, the two
        // assignments the script itself writes.
        let multiline = "input=$(cat)\nhook=x\necho \"$input\" | jq -r .model.display_name"
        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": multiline]))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        try service.combine(hookCommand: Self.hookCommand)
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combined)
        try service.remove()
        XCTAssertEqual(try entry(of: settingsFS.data)["command"] as? String, multiline)
    }

    /// An app under a folder with a space: the settings command quotes the
    /// path, and the script tests the whole path, not its first word.
    func testAnAppPathWithASpaceStaysOneWord() throws {
        let path = "/Users/me/My Apps/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook"
        let quoted = ClaudeStatuslineCombine.shellWord(path) + " --statusline"
        XCTAssertEqual(quoted, "'\(path)' --statusline")
        XCTAssertEqual(ClaudeStatuslineCombine.shellWord(Self.hook), Self.hook, "no quotes when none are needed")
        let quotes = #"/Users/me/Tom's "apps"/localvoxtral-claude-hook"#
        XCTAssertEqual(
            ClaudeStatuslineInstallService.shellWords(ClaudeStatuslineCombine.shellWord(quotes) + " --statusline"),
            [quotes, "--statusline"], "both quote kinds survive as one word"
        )
        XCTAssertEqual(
            ClaudeStatuslineCombine.parse(ClaudeStatuslineCombine.script(original: "x", hookPath: quotes))?.hookPath,
            quotes
        )

        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original]))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        try service.combine(hookCommand: quoted)
        let text = String(decoding: try XCTUnwrap(scriptFS.data), as: UTF8.self)
        XCTAssertEqual(ClaudeStatuslineCombine.parse(text)?.hookPath, path)
        XCTAssertEqual(service.status(currentHookCommand: quoted), .combined)
        XCTAssertEqual(
            service.status(currentHookCommand: "/Users/me/My --statusline"), .combinedOutdated,
            "a truncated path is another copy, not this one"
        )
    }

    /// Claude Code runs the script directly: without its execute bit it
    /// prints nothing, and Update puts the bit back.
    func testAScriptWithoutItsExecuteBitIsOutdated() throws {
        let settingsFS = MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original]))
        let scriptFS = MemoryStatuslineFS(data: nil)
        let service = service(settings: settingsFS, script: scriptFS)
        try service.combine(hookCommand: Self.hookCommand)
        scriptFS.permissions = 0o600
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combinedOutdated)
        try service.updateCombined(hookCommand: Self.hookCommand)
        XCTAssertEqual(scriptFS.permissions, 0o700)
        XCTAssertEqual(service.status(currentHookCommand: Self.hookCommand), .combined)
    }

    /// Combine is offered only where it would work.
    func testCombineIsNotOfferedWhereItWouldFail() throws {
        let notACommand = service(
            settings: MemoryStatuslineFS(data: try settings(["type": "text", "text": "hi"])),
            script: MemoryStatuslineFS(data: nil)
        )
        XCTAssertEqual(notACommand.status(currentHookCommand: Self.hookCommand), .foreignNotCombinable)

        let occupied = service(
            settings: MemoryStatuslineFS(data: try settings(["type": "command", "command": Self.original])),
            script: MemoryStatuslineFS(data: Data("#!/bin/sh\necho theirs\n".utf8))
        )
        XCTAssertEqual(occupied.status(currentHookCommand: Self.hookCommand), .foreignNotCombinable)
        XCTAssertNil(ClaudeStatuslineInstallService.setupButtonTitle(for: .foreignNotCombinable))
        XCTAssertFalse(ClaudeStatuslineInstallService.offersRemove(for: .foreignNotCombinable))
    }

    func testCombineRefusesWithoutAUserCommand() throws {
        for data in [nil, try settings(["type": "command", "command": Self.hookCommand])] {
            let settingsFS = MemoryStatuslineFS(data: data)
            let scriptFS = MemoryStatuslineFS(data: nil)
            XCTAssertThrowsError(
                try service(settings: settingsFS, script: scriptFS).combine(hookCommand: Self.hookCommand)
            )
            XCTAssertNil(scriptFS.data)
        }
    }
}

/// A file that remembers what was written, so status reads follow writes.
private final class MemoryStatuslineFS: ClaudeStatuslineFileSystem, @unchecked Sendable {
    var data: Data?
    var permissions: UInt16?

    init(data: Data?) { self.data = data }

    func readState() throws -> ClaudeStatuslineState {
        ClaudeStatuslineState(fileExists: data != nil, data: data, permissions: permissions)
    }
    func createDirectory(permissions: UInt16) throws {}
    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        self.data = data
        self.permissions = permissions
    }
    func deleteFile() throws {
        data = nil
        permissions = nil
    }
}
