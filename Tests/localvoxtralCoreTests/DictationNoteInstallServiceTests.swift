import Foundation
import XCTest
import LocalvoxtralCLICore
import localvoxtralTestSupport

@testable import localvoxtralCore

final class DictationNoteInstallServiceTests: XCTestCase {
    private static let claudeFile = ".claude/CLAUDE.md"
    private static let opencodeFile = ".config/opencode/AGENTS.md"
    private static let vibeFile = ".vibe/AGENTS.md"
    private static let codexFile = ".codex/AGENTS.md"
    private static let codexOverride = ".codex/AGENTS.override.md"
    private static let snippet = DictationNoteInstallService.snippet
    private static let userText = "# Working with me\n\n- Be blunt.\n- Keep it short.\n"

    private func service(
        _ agent: DictationNoteAgent, _ fs: MemoryDictationNoteFileSystem
    ) -> DictationNoteInstallService {
        DictationNoteInstallService(agent: agent, fileSystem: fs)
    }

    private func service(_ fs: MemoryDictationNoteFileSystem) -> DictationNoteInstallService {
        service(.claudeCode, fs)
    }

    // MARK: - The four fixture files

    func testAbsentFileIsCreatedWithOnlyTheBlock() throws {
        let fs = MemoryDictationNoteFileSystem()
        XCTAssertEqual(service(fs).status(), .notAdded)

        try service(fs).add()

        XCTAssertEqual(fs.text(Self.claudeFile), Self.snippet + "\n")
        XCTAssertEqual(fs.snapshot.createdDirectories, [Self.claudeFile])
        XCTAssertEqual(service(fs).status(), .added(path: Self.claudeFile))
    }

    func testAFileWithOtherContentKeepsEveryByteAndGetsTheBlockAppended() throws {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: Self.userText])

        try service(fs).add()

        XCTAssertEqual(fs.text(Self.claudeFile), Self.userText + "\n" + Self.snippet + "\n")
        XCTAssertTrue(fs.snapshot.createdDirectories.isEmpty)
        XCTAssertEqual(fs.snapshot.writes.map(\.permissions), [0o644])

        try service(fs).remove()
        XCTAssertEqual(fs.text(Self.claudeFile), Self.userText, "add then remove is byte-identical")
    }

    func testABlockAlreadyPresentIsNotWrittenAgain() throws {
        let text = Self.userText + "\n" + Self.snippet + "\n\n## More of mine\n"
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: text])
        XCTAssertEqual(service(fs).status(), .added(path: Self.claudeFile))
        XCTAssertNil(DictationNoteInstallService.addButtonTitle(for: service(fs).status()))

        try service(fs).add()

        XCTAssertTrue(fs.snapshot.writes.isEmpty)
        XCTAssertEqual(fs.text(Self.claudeFile), text)
    }

    func testABlockEditedByTheUserReadsAsAnotherVersionAndUpdateReplacesOnlyIt() throws {
        let edited = Self.snippet.replacingOccurrences(of: "ask me before acting", with: "just guess")
        let before = Self.userText + "\n" + edited + "\n\n## More of mine\n"
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: before])
        let status = service(fs).status()
        XCTAssertEqual(status, .differs(path: Self.claudeFile))
        XCTAssertEqual(DictationNoteInstallService.addButtonTitle(for: status), "Update")
        XCTAssertTrue(DictationNoteInstallService.offersRemove(for: status))

        try service(fs).add()

        XCTAssertEqual(fs.text(Self.claudeFile), Self.userText + "\n" + Self.snippet + "\n\n## More of mine\n")
    }

    // MARK: - Remove

    func testRemoveKeepsTheRestOfTheFile() throws {
        let fs = MemoryDictationNoteFileSystem(
            files: [Self.claudeFile: Self.userText + "\n" + Self.snippet + "\n\n## After\n"]
        )

        try service(fs).remove()

        XCTAssertEqual(fs.text(Self.claudeFile), Self.userText + "\n## After\n")
        XCTAssertEqual(service(fs).status(), .notAdded)
    }

    func testRemoveDeletesAFileItLeavesEmpty() throws {
        let fs = MemoryDictationNoteFileSystem(files: [Self.vibeFile: Self.snippet + "\n"])

        try service(.vibe, fs).remove()

        XCTAssertEqual(fs.snapshot.deletes, [Self.vibeFile])
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
    }

    func testRemoveWithNoBlockOrNoFileWritesNothing() throws {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: Self.userText])
        try service(fs).remove()
        try service(.vibe, fs).remove()
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
        XCTAssertTrue(fs.snapshot.deletes.isEmpty)
    }

    // MARK: - Files the service will not write into

    func testUnpairedMarkersAreRefusedAndLeftAlone() {
        let text = Self.userText + DictationNoteInstallService.block.markerBegin + "\nmine\n"
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: text])
        let status = service(fs).status()
        XCTAssertEqual(status, .needsManualFix(path: Self.claudeFile, .unpairedMarkers))
        XCTAssertNil(DictationNoteInstallService.addButtonTitle(for: status))
        XCTAssertFalse(DictationNoteInstallService.offersRemove(for: status))

        XCTAssertThrowsError(try service(fs).add())
        XCTAssertThrowsError(try service(fs).remove())
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
        XCTAssertEqual(fs.text(Self.claudeFile), text)
    }

    func testSymlinkUnreadableAndNonUTF8FilesAreRefused() {
        let cases: [(DictationNoteFile, DictationNoteInstallService.Refusal)] = [
            (DictationNoteFile(exists: true, isSymlink: true), .symlink),
            (DictationNoteFile(exists: true, data: nil), .unreadable),
            (DictationNoteFile(exists: true, data: Data([0xFF, 0xFE, 0x00])), .notUTF8),
        ]
        for (file, refusal) in cases {
            let fs = MemoryDictationNoteFileSystem()
            fs.set(Self.claudeFile, file)
            XCTAssertEqual(service(fs).status(), .needsManualFix(path: Self.claudeFile, refusal))
            XCTAssertThrowsError(try service(fs).add()) { error in
                XCTAssertEqual(
                    error as? DictationNoteInstallService.ServiceError,
                    .refused(path: Self.claudeFile, refusal)
                )
            }
            XCTAssertTrue(fs.snapshot.writes.isEmpty)
        }
    }

    func testAFileEditedWhileAddingIsNotOverwritten() {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: Self.userText])
        fs.editBetweenReads(Self.claudeFile, Self.userText + "- A line saved meanwhile.\n")

        XCTAssertThrowsError(try service(fs).add()) { error in
            XCTAssertEqual(
                error as? DictationNoteInstallService.ServiceError, .changedOnDisk(path: Self.claudeFile)
            )
        }
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
    }

    func testCRLFFileStaysCRLF() throws {
        let crlf = "# Mine\r\n\r\n- Be blunt.\r\n"
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: crlf])

        try service(fs).add()

        let text = try XCTUnwrap(fs.text(Self.claudeFile))
        XCTAssertEqual(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), false)
        XCTAssertEqual(service(fs).status(), .added(path: Self.claudeFile))
    }

    // MARK: - Which file each agent reads

    func testOpencodeUsesItsOwnFileWhenItExists() throws {
        let fs = MemoryDictationNoteFileSystem(
            files: [Self.opencodeFile: Self.userText, Self.claudeFile: Self.userText]
        )

        try service(.opencode, fs).add()

        XCTAssertEqual(fs.snapshot.writes.map(\.path), [Self.opencodeFile])
        XCTAssertEqual(fs.text(Self.claudeFile), Self.userText)
    }

    /// opencode reads `~/.claude/CLAUDE.md` only while its own file is absent.
    /// Creating its own file would hide the user's CLAUDE.md from it, so the
    /// note goes where opencode already reads, and Claude Code shares it.
    func testOpencodeWithoutItsOwnFileWritesTheCLAUDEmdItReads() throws {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeFile: Self.userText])

        try service(.opencode, fs).add()

        XCTAssertEqual(fs.snapshot.writes.map(\.path), [Self.claudeFile])
        XCTAssertEqual(service(.opencode, fs).status(), .added(path: Self.claudeFile))
        XCTAssertEqual(service(.claudeCode, fs).status(), .added(path: Self.claudeFile))
    }

    func testOpencodeWithNeitherFileCreatesItsOwn() throws {
        let fs = MemoryDictationNoteFileSystem()

        try service(.opencode, fs).add()

        XCTAssertEqual(fs.snapshot.writes.map(\.path), [Self.opencodeFile])
    }

    func testVibeUsesItsHomeAGENTSmd() throws {
        let fs = MemoryDictationNoteFileSystem()
        try service(.vibe, fs).add()
        XCTAssertEqual(fs.snapshot.writes.map(\.path), [Self.vibeFile])
    }

    /// Codex 0.156 reads AGENTS.override.md instead of AGENTS.md when the
    /// override holds more than whitespace, and skips a blank one.
    func testCodexWritesTheFileCodexReads() throws {
        let cases: [(files: [String: String], target: String)] = [
            ([:], Self.codexFile),
            ([Self.codexFile: Self.userText], Self.codexFile),
            ([Self.codexOverride: Self.userText, Self.codexFile: Self.userText], Self.codexOverride),
            ([Self.codexOverride: Self.userText], Self.codexOverride),
            ([Self.codexOverride: " \n\n", Self.codexFile: Self.userText], Self.codexFile),
            // A new override would hide an AGENTS.md written later.
            ([Self.codexOverride: ""], Self.codexFile),
        ]
        for (files, target) in cases {
            let fs = MemoryDictationNoteFileSystem(files: files)

            try service(.codex, fs).add()

            XCTAssertEqual(fs.snapshot.writes.map(\.path), [target], "\(files.keys.sorted())")
            XCTAssertEqual(service(.codex, fs).status(), .added(path: target))
        }
    }

    /// A symlinked override is what Codex reads; the row reports it rather
    /// than writing into AGENTS.md, which Codex would ignore.
    func testCodexDoesNotWritePastAnOverrideItCannotRead() {
        let fs = MemoryDictationNoteFileSystem(files: [Self.codexFile: Self.userText])
        fs.set(Self.codexOverride, DictationNoteFile(exists: true, isSymlink: true))

        XCTAssertEqual(service(.codex, fs).status(), .needsManualFix(path: Self.codexOverride, .symlink))
        XCTAssertThrowsError(try service(.codex, fs).add())
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
    }

    // MARK: - The note itself

    /// Codex truncates AGENTS.md at 32 KiB without a warning, and every
    /// agent pays for these bytes on every turn.
    func testTheNoteStaysShort() {
        XCTAssertLessThan(Self.snippet.utf8.count, 512)
    }

    /// The note names the command as the CLI ships it (#740): a name
    /// appended to it parses as a proposal, not a usage error.
    func testTheNotesProposeCommandIsOneTheCLIRuns() throws {
        let quoted = try XCTUnwrap(Self.snippet.firstMatch(of: /`(localvoxtral [^`]*)`/)?.1)
        let words = quoted.split(separator: " ").dropFirst().map(String.init) + ["QuillDoc"]
        let parser = AgentCLIArguments(
            now: Date(timeIntervalSince1970: 0), timeZone: .gmt, workingDirectory: "/work/quillmark", environment: [:])

        guard case .run(let invocation) = parser.parse(words) else {
            return XCTFail("`\(quoted)` does not parse: \(parser.parse(words))")
        }
        XCTAssertEqual(invocation.request.knownCommand, .termsPropose)
        XCTAssertEqual(invocation.request.terms, ["QuillDoc"])
    }
}

/// The live file system on a real temporary home.
final class LiveDictationNoteFileSystemTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func service(_ agent: DictationNoteAgent) -> DictationNoteInstallService {
        DictationNoteInstallService(agent: agent, fileSystem: LiveDictationNoteFileSystem(homeDirectoryURL: home))
    }

    func testAddCreatesTheDirectoryAndRemoveDeletesTheFileItCreated() throws {
        try service(.opencode).add()
        let file = home.appendingPathComponent(".config/opencode/AGENTS.md")
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), DictationNoteInstallService.snippet + "\n"
        )

        try service(.opencode).remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAddKeepsTheFileMode() throws {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("CLAUDE.md")
        try Data("mine\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        try service(.claudeCode).add()

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.uint16Value, 0o600)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("mine\n\n"))
    }

    func testASymlinkedFileIsRefusedAndItsTargetUntouched() throws {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("dotfiles-CLAUDE.md")
        try Data("mine\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("CLAUDE.md"), withDestinationURL: target
        )

        XCTAssertEqual(service(.claudeCode).status(), .needsManualFix(path: ".claude/CLAUDE.md", .symlink))
        XCTAssertThrowsError(try service(.claudeCode).add())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "mine\n")
    }

    func testASymlinkedDirectoryIsRefused() throws {
        let real = home.appendingPathComponent("real-vibe", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("mine\n".utf8).write(to: real.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".vibe"), withDestinationURL: real
        )

        XCTAssertEqual(service(.vibe).status(), .needsManualFix(path: ".vibe/AGENTS.md", .symlink))
        XCTAssertThrowsError(try service(.vibe).add())
        XCTAssertEqual(
            try String(contentsOf: real.appendingPathComponent("AGENTS.md"), encoding: .utf8), "mine\n"
        )
    }
}
