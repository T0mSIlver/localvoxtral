import Foundation
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

final class AgentSkillInstallServiceTests: XCTestCase {
    private static let skill = Data("---\nname: localvoxtral-doctor\n---\nbody\n".utf8)
    private static let claudeSkill = ".claude/skills/localvoxtral-doctor/SKILL.md"

    private func service(
        _ fs: MemoryDictationNoteFileSystem, _ agent: DictationNoteAgent = .claudeCode
    ) -> AgentSkillInstallService {
        AgentSkillInstallService(agent: agent, bundledSkill: { Self.skill }, fileSystem: fs)
    }

    func testEachAgentGetsTheSkillInItsOwnDirectory() throws {
        let expected: [DictationNoteAgent: String] = [
            .claudeCode: ".claude/skills/localvoxtral-doctor/SKILL.md",
            .opencode: ".config/opencode/skills/localvoxtral-doctor/SKILL.md",
            .vibe: ".vibe/skills/localvoxtral-doctor/SKILL.md",
            .codex: ".codex/skills/localvoxtral-doctor/SKILL.md",
        ]
        for agent in DictationNoteAgent.allCases {
            let fs = MemoryDictationNoteFileSystem()
            XCTAssertEqual(service(fs, agent).status(), .notAdded, "\(agent)")

            try service(fs, agent).add()

            let path = try XCTUnwrap(expected[agent])
            XCTAssertEqual(fs.snapshot.files.keys.sorted(), [path], "\(agent)")
            XCTAssertEqual(fs.snapshot.files[path]?.data, Self.skill, "\(agent)")
            XCTAssertEqual(service(fs, agent).status(), .added(path: path), "\(agent)")
        }
    }

    func testAnotherVersionIsOfferedAsUpdateAndReplaced() throws {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeSkill: "older\n"])
        let status = service(fs).status()
        XCTAssertEqual(status, .differs(path: Self.claudeSkill))
        XCTAssertEqual(DictationNoteInstallService.addButtonTitle(for: status), "Update")
        XCTAssertEqual(
            AgentSkillInstallService.sentence(for: status, agent: .claudeCode),
            "~/.claude/skills holds another version."
        )

        try service(fs).add()

        XCTAssertEqual(fs.snapshot.files[Self.claudeSkill]?.data, Self.skill)
        XCTAssertEqual(service(fs).status(), .added(path: Self.claudeSkill))
    }

    func testRemoveKeepsTheDirectoryWhileTheUserHasAFileInIt() throws {
        let note = ".claude/skills/localvoxtral-doctor/notes.md"
        let fs = MemoryDictationNoteFileSystem(files: [note: "mine\n"])
        try service(fs).add()

        try service(fs).remove()

        XCTAssertEqual(fs.snapshot.files.keys.sorted(), [note])
        XCTAssertEqual(fs.snapshot.removedDirectories, [])
        XCTAssertEqual(service(fs).status(), .notAdded)
    }

    func testASymlinkedSkillIsRefusedAndLeftAlone() {
        let fs = MemoryDictationNoteFileSystem()
        fs.set(Self.claudeSkill, DictationNoteFile(exists: true, isSymlink: true))

        XCTAssertEqual(service(fs).status(), .needsManualFix(path: Self.claudeSkill, .symlink))
        for action in [{ try self.service(fs).add() }, { try self.service(fs).remove() }] {
            XCTAssertThrowsError(try action()) { error in
                XCTAssertEqual(
                    error as? DictationNoteInstallService.ServiceError,
                    .refused(path: Self.claudeSkill, .symlink)
                )
            }
        }
        XCTAssertTrue(fs.snapshot.writes.isEmpty)
        XCTAssertTrue(fs.snapshot.deletes.isEmpty)
    }

    func testAnEditBetweenReadAndWriteIsNotOverwritten() {
        let fs = MemoryDictationNoteFileSystem(files: [Self.claudeSkill: "older\n"])
        fs.editBetweenReads(Self.claudeSkill, "edited\n")
        // The row reads the status, then the press reads once more before
        // the edit lands and once after.
        XCTAssertEqual(service(fs).status(), .differs(path: Self.claudeSkill))

        XCTAssertThrowsError(try service(fs).add()) { error in
            XCTAssertEqual(
                error as? DictationNoteInstallService.ServiceError, .changedOnDisk(path: Self.claudeSkill)
            )
        }
        XCTAssertEqual(fs.text(Self.claudeSkill), "edited\n")
    }

    func testWithoutTheBundledSkillTheRowOffersNothing() {
        let fs = MemoryDictationNoteFileSystem()
        let service = AgentSkillInstallService(agent: .vibe, bundledSkill: { nil }, fileSystem: fs)

        XCTAssertEqual(service.status(), .unknown)
        XCTAssertNil(DictationNoteInstallService.addButtonTitle(for: service.status()))
        XCTAssertThrowsError(try service.add())
    }

    /// Vibe skips a skill whose name differs from its directory, and every
    /// agent needs the description to know when to load it.
    func testTheShippedSkillIsNamedForItsDirectoryAndHasADescription() throws {
        let data = try XCTUnwrap(
            ClaudePluginAssets.doctorSkill(marketplaceURL: ClaudePluginAssets.developmentMarketplaceURL())
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let frontmatter = try XCTUnwrap(text.components(separatedBy: "---\n").dropFirst().first)
        let fields = frontmatter.split(separator: "\n")
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(fields.contains("name: \(AgentSkillInstallService.skillName)"))
        XCTAssertTrue(fields.contains { $0.hasPrefix("description: ") && $0.contains("did not join") })
    }
}

/// The live file system on a real temporary home.
final class LiveAgentSkillFileSystemTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testAddWritesTheSkillAndRemoveDeletesItsDirectory() throws {
        let skill = Data("---\nname: localvoxtral-doctor\n---\n".utf8)
        let service = AgentSkillInstallService(
            agent: .codex, bundledSkill: { skill }, fileSystem: LiveDictationNoteFileSystem(homeDirectoryURL: home)
        )
        let directory = home.appendingPathComponent(".codex/skills/localvoxtral-doctor")

        try service.add()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("SKILL.md")), skill)

        try service.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/skills").path))
    }
}
