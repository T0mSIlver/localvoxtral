import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtralCore

/// #1027: a repository the user's coding agents worked in is listed, and its
/// name reaches every polish, before a dictation joins a session in it.
final class AgentProjectActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var home: URL!
    private var projectsRoot: URL { home.appendingPathComponent(".claude/projects") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-agent-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// A main checkout with `origin` set, or none.
    @discardableResult
    private func repository(_ name: String, origin: String?) throws -> URL {
        let root = home.appendingPathComponent("work/\(name)", isDirectory: true)
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        var config = "[core]\n\trepositoryformatversion = 0\n"
        if let origin {
            config += "[remote \"origin\"]\n\turl = \(origin)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        }
        try Data(config.utf8).write(to: git.appendingPathComponent("config"))
        return root
    }

    /// A linked worktree of `main`, as git lays one out.
    private func worktree(of main: URL, named name: String) throws -> URL {
        let gitDirectory = main.appendingPathComponent(".git/worktrees/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: gitDirectory.appendingPathComponent("commondir"))
        let root = home.appendingPathComponent("worktrees/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: root.appendingPathComponent(".git"))
        return root
    }

    /// A Claude Code project folder holding one transcript that records
    /// `cwd`, modified `age` seconds before `now`. Its first line is a
    /// queued prompt quoting a `"cwd"` key, which is text, not the key.
    private func transcript(cwd: URL, age: TimeInterval, session: String = "session") throws {
        let folder = projectsRoot.appendingPathComponent(
            cwd.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let quoted = String(repeating: "x", count: 70_000)
        let lines = [
            #"{"type":"queue-operation","content":"paste: {\"cwd\":\"/evil\"} \#(quoted)"}"#,
            #"{"parentUuid":null,"cwd":"\#(cwd.path)","sessionId":"\#(session)","message":{"role":"user","content":"secret prompt"}}"#,
        ]
        let file = folder.appendingPathComponent("\(session).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path
        )
    }

    private func scan(into learned: inout LearnedTerms) throws {
        let directories = try XCTUnwrap(
            AgentTranscripts.recentWorkingDirectories(projectsRoot: projectsRoot, now: now)
        )
        for repository in AgentWorkedRepositories.resolve(directories) {
            learned.recordAgentActivity(
                project: repository.project, remote: repository.remote, at: repository.lastActive, now: now
            )
        }
    }

    // MARK: The scan

    /// The issue's proof: recent work lists the repository and puts its
    /// name in the polish prompt; work older than 30 days, a folder a tool
    /// named and a repository with no origin do not.
    func testRecentAgentWorkListsTheRepositoryAndItsNameReachesPolish() throws {
        let vidtheque = try repository("vidtheque", origin: "git@github.com:T0mSIlver/vidtheque.git")
        try transcript(cwd: vidtheque.appendingPathComponent("src"), age: 2 * 86_400)
        try transcript(cwd: try repository("finished", origin: "https://github.com/T0mSIlver/finished"), age: 31 * 86_400)
        try transcript(
            cwd: try repository("ci-speed-optimizations-7ffef0", origin: "https://github.com/T0mSIlver/ci"), age: 3600
        )
        try transcript(cwd: try repository("scratch", origin: nil), age: 3600)
        try transcript(cwd: home.appendingPathComponent("work/gone"), age: 3600)

        var learned = LearnedTerms()
        try scan(into: &learned)

        XCTAssertEqual(learned.listedCheckouts(now: now).map(\.key), [vidtheque.path])
        let checkout = try XCTUnwrap(learned.projects.first { $0.key == vidtheque.path })
        XCTAssertEqual(checkout.repository, "T0mSIlver/vidtheque")
        XCTAssertEqual(checkout.agentActiveAt, now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(PolishProjectNames.names(from: learned, now: now), ["vidtheque"])
    }

    func testAWorktreesWorkListsItsMainCheckoutAtTheNewestWork() throws {
        let main = try repository("herdr", origin: "https://github.com/T0mSIlver/herdr.git")
        try transcript(cwd: main, age: 5 * 86_400, session: "a")
        let tree = try worktree(of: main, named: "fix-wrap")
        try transcript(cwd: tree, age: 3600, session: "b")

        var learned = LearnedTerms()
        try scan(into: &learned)

        XCTAssertEqual(learned.listedCheckouts(now: now).map(\.key), [main.path])
        XCTAssertEqual(learned.projects.first { $0.key == main.path }?.agentActiveAt, now.addingTimeInterval(-3600))
    }

    func testOnlyTheCwdKeyIsRead() throws {
        let repo = try repository("reach", origin: "https://github.com/T0mSIlver/reach")
        try transcript(cwd: repo, age: 60)
        let file = try XCTUnwrap(
            FileManager.default.enumerator(at: projectsRoot, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" }
        )
        XCTAssertEqual(AgentTranscripts.workingDirectory(ofTranscript: file), repo.path)
    }

    func testAMissingTranscriptsFolderListsNothing() {
        XCTAssertNil(AgentTranscripts.recentWorkingDirectories(
            projectsRoot: home.appendingPathComponent("absent"), now: now
        ))
    }

    // MARK: How long it stays

    private let remote = ProjectRemote("github.com/T0mSIlver/toklen")!
    private let toklen = LearnedTermProjectIdentity(key: "/Users/tom/work/toklen", name: "toklen")

    func testWorkListsTheProjectFor30DaysThenItGoes() {
        var learned = LearnedTerms()
        XCTAssertTrue(learned.recordAgentActivity(project: toklen, remote: remote, at: now, now: now))
        XCTAssertEqual(learned.listedProjects(now: now).map(\.key), [remote.key])

        let later = now.addingTimeInterval(31 * 86_400)
        learned.prune(now: later)
        XCTAssertEqual(learned.projects, [], "the checkout and its repository's record both go")
    }

    func testADictationKeepsTheProjectPastItsAgentWork() {
        var learned = LearnedTerms()
        learned.recordAgentActivity(project: toklen, remote: remote, at: now, now: now)
        learned.record(
            [LearnedTermObservation(term: "tokenizer", source: .repository)], project: toklen, now: now.addingTimeInterval(2 * 86_400)
        )

        let later = now.addingTimeInterval(31 * 86_400)
        learned.prune(now: later)
        XCTAssertEqual(learned.listedProjects(now: later).map(\.key), [remote.key])
    }

    func testNewerWorkMovesTheProjectFirstWithoutRelinking() {
        var learned = LearnedTerms()
        let older = LearnedTermProjectIdentity(key: "/Users/tom/work/hither", name: "hither")
        learned.recordAgentActivity(
            project: older, remote: ProjectRemote("github.com/T0mSIlver/hither")!, at: now.addingTimeInterval(-60), now: now
        )
        learned.recordAgentActivity(project: toklen, remote: remote, at: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(learned.listedCheckouts(now: now).map(\.name), ["hither", "toklen"])

        learned.recordAgentActivity(project: toklen, remote: remote, at: now, now: now)
        XCTAssertEqual(learned.listedCheckouts(now: now).map(\.name), ["toklen", "hither"])
    }

    // MARK: The host's header

    func testTheHeaderKeepsWellFormedEntriesOnly() {
        let header = [
            "1999999000:vidtheque:T0mSIlver/vidtheque",
            "1999998000:-dash:T0mSIlver/x",
            "1999997000:herdr:gitlab.com/group/herdr",
            "12:no-repo:",
            "1999996000:spaced name:T0mSIlver/y",
            "1999995000:vidtheque:T0mSIlver/again",
        ].joined(separator: ",")
        let entries = AgentProjectsCodec.entries(in: [AgentProjectsCodec.lowercasedHeaderName: header])
        XCTAssertEqual(entries?.map(\.name), ["vidtheque", "herdr"])
        XCTAssertEqual(entries?.first?.lastActive, Date(timeIntervalSince1970: 1_999_999_000))
        XCTAssertNil(AgentProjectsCodec.entries(in: [:]))
    }
}
