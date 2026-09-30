import Foundation
import XCTest

@testable import localvoxtralCore

/// #1024: the skill names every polish carries.
final class AgentSkillStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent("home/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testTheMacsFoldersNameSkillsAndCommands() throws {
        try touch(".claude/skills/unslop/SKILL.md")
        try touch(".claude/skills/README.md")
        try touch(".claude/skills/synced/notes.txt")
        try touch(".codex/skills/unslop/SKILL.md")
        try touch(".config/opencode/skills/test-audit/SKILL.md")
        try touch(".claude/plugins/cache/official/frontend-design/1.0.0/skills/frontend-design/SKILL.md")
        try touch(".claude/commands/ship.md")
        try touch(".claude/commands/README.md")
        XCTAssertEqual(
            AgentSkillDirectories.names(home: root.appendingPathComponent("home")),
            ["unslop", "test-audit", "frontend-design", "ship"],
            "a folder without SKILL.md and a README are not skills; one name once"
        )
    }

    func testEveryFreshHostAndTheMacSortedAndAStaleHostDropsOut() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day: TimeInterval = 86_400
        let names = AgentSkillNames(hosts: [
            "box": .init(names: ["unslop", "gh-stack"], reportedAt: now.addingTimeInterval(-day)),
            "old": .init(names: ["forgotten"], reportedAt: now.addingTimeInterval(-31 * day)),
        ])
        XCTAssertEqual(names.names(local: ["Ship", "unslop"], now: now), ["gh-stack", "Ship", "unslop"])
    }

    /// The spelling of a name two hosts write differently must not follow
    /// which one reported last: the prompt would change with it.
    func testASpellingDoesNotDependOnWhichHostReportedLast() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func names(newer: String) -> [String] {
            AgentSkillNames(hosts: [
                "a": .init(names: ["Unslop"], reportedAt: now.addingTimeInterval(newer == "a" ? 0 : -60)),
                "b": .init(names: ["unslop"], reportedAt: now.addingTimeInterval(newer == "b" ? 0 : -60)),
            ]).names(local: [], now: now)
        }
        XCTAssertEqual(names(newer: "a"), ["Unslop"])
        XCTAssertEqual(names(newer: "b"), ["Unslop"])
    }

    func testTheMacsFoldersAreReadAgainOnlyOnceTheLastReadIsOld() throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 10_000_000) }
        let clock = Clock()
        let home = root.appendingPathComponent("home")
        let store = AgentSkillStore(fileURL: nil, home: home, now: { clock.now })
        store.waitForPendingWork()
        try touch(".claude/skills/unslop/SKILL.md")

        store.refreshLocalIfStale()
        store.waitForPendingWork()
        XCTAssertEqual(store.names(), [])

        clock.now += AgentSkillStore.localRefreshInterval
        store.refreshLocalIfStale()
        store.waitForPendingWork()
        XCTAssertEqual(store.names(), ["unslop"])
    }

    func testAReportIsKeptOnDiskAndAnUnchangedOneIsNotRewrittenTheSameDay() throws {
        let file = root.appendingPathComponent("agent-skills.json")
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 10_000_000) }
        let clock = Clock()
        let store = AgentSkillStore(fileURL: file, home: root.appendingPathComponent("home"), now: { clock.now })
        store.waitForPendingWork()

        store.record(hostID: "box", names: ["unslop", "bad name", "gh-stack"])
        store.waitForPendingWork()
        XCTAssertEqual(store.names(), ["gh-stack", "unslop"])
        let written = try Data(contentsOf: file)

        try FileManager.default.removeItem(at: file)
        clock.now += 3_600
        store.record(hostID: "box", names: ["unslop", "gh-stack"])
        store.waitForPendingWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "same list within a day: no write")

        try written.write(to: file)
        let reloaded = AgentSkillStore(fileURL: file, home: root.appendingPathComponent("home"), now: { clock.now })
        reloaded.waitForPendingWork()
        XCTAssertEqual(reloaded.names(), ["gh-stack", "unslop"])
    }

    /// A hook can arrive at launch before the file is read: its report is
    /// kept, and the file keeps the other hosts.
    func testAReportBeforeTheLoadKeepsBothItAndTheFile() throws {
        let file = root.appendingPathComponent("agent-skills.json")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AgentSkillNames(hosts: ["old": .init(names: ["unslop"], reportedAt: now)])).write(to: file)

        let store = AgentSkillStore(fileURL: file, home: root.appendingPathComponent("home"), now: { now })
        store.record(hostID: "box", names: ["gh-stack"])
        store.waitForPendingWork()

        XCTAssertEqual(store.names(), ["gh-stack", "unslop"])
        let reloaded = AgentSkillStore(fileURL: file, home: root.appendingPathComponent("home"), now: { now })
        reloaded.waitForPendingWork()
        XCTAssertEqual(reloaded.names(), ["gh-stack", "unslop"])
    }

    func testAnUnreadableFileIsNeverOverwritten() throws {
        let file = root.appendingPathComponent("agent-skills.json")
        try Data("{not json".utf8).write(to: file)
        let store = AgentSkillStore(fileURL: file, home: root.appendingPathComponent("home"))
        store.waitForPendingWork()
        store.record(hostID: "box", names: ["unslop"])
        store.waitForPendingWork()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{not json")
        XCTAssertEqual(store.names(), ["unslop"], "the report still counts for this launch")
    }

    func testTheSkillLineFollowsTheProjectsAndSkipsNamesAlreadyListed() {
        let templates = LLMPromptTemplates(systemContent: "SYSTEM", userContent: "{{input_text}}")
        XCTAssertEqual(
            templates.withSpeakerProfile(
                "", terms: ["/unslop"], projects: ["herdr"], skills: ["herdr", "unslop", "gh-stack"]
            ).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "Names and terms they use: /unslop\n"
                + "Their projects (repository names): herdr\n"
                + "Skills they invoke in their coding agents: gh-stack\n"
        )
    }
}
