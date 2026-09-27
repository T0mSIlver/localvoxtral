import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

@MainActor
final class QuickCaptureInboxTests: XCTestCase {
    private let projects = QuickCaptureFixture.projects
    private var fileURL: URL!
    private let github = FakeQuickCaptureGitHub()
    private let runner = FakeQuickCaptureDraftRunner()
    private var statuses: [String] = []
    private var routed: [String] = []

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-inbox-\(UUID().uuidString)")
            .appendingPathComponent("quick-captures.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func model(
        answer: [String: Double],
        github: (any QuickCaptureGitHub)? = nil,
        projects: [QuickCaptureProject]? = nil,
        remote: QuickCaptureDrafter.Remote? = nil
    ) -> QuickCaptureInboxModel {
        let model = QuickCaptureFixture.model(
            fileURL: fileURL, answer: answer, github: github ?? self.github, runner: runner,
            projects: projects ?? self.projects, remote: remote
        )
        model.onStatus = { [weak self] in self?.statuses.append($0) }
        model.onRouted = { [weak self] _, destination in self?.routed.append(destination) }
        return model
    }

    func testACaptureIsOnDiskBeforeRoutingAndDraftedInItsProject() async throws {
        let model = model(answer: ["reach": 0.9])
        let task = model.capture(text: "Add a dark mode", historyRecordID: UUID())
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.map(\.text), ["Add a dark mode"])
        await task.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.projectName, "reach")
        XCTAssertEqual(item.repository, "o/reach")
        XCTAssertEqual(item.title, "Dark mode")
        XCTAssertEqual(statuses, ["Sent to reach inbox"])
        XCTAssertEqual(routed, ["reach"])
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "nothing is filed without File")
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.title, "Dark mode")
    }

    func testTheCatchAllRunsNoAgentAndMovingItDraftsIt() async throws {
        let model = model(answer: ["inbox": 0.9])
        await model.capture(text: "An idea", historyRecordID: nil).value
        var item = try XCTUnwrap(model.items.first)
        XCTAssertNil(item.projectKey)
        XCTAssertEqual(item.note, "Not routed to a project. Move it to one.")
        XCTAssertEqual(statuses, ["Sent to inbox"])
        XCTAssertEqual(runner.runs.withLock { $0 }, 0)

        await model.move(item.id, toProjectKey: "/w/reach")?.value
        item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.projectName, "reach")
        XCTAssertEqual(item.title, "Dark mode")
        XCTAssertNil(item.note)
        XCTAssertEqual(runner.runs.withLock { $0 }, 1)
    }

    func testFileSendsTheEditedDraftWithTheDictatedWordsOnce() async throws {
        let model = model(answer: ["reach": 0.9])
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)
        model.setTitle("Dark theme", for: id)
        await model.file(id)?.value
        XCTAssertEqual(github.created.withLock { $0 }, [[
            "o/reach", "Dark theme", "## Scope\nAll pages.\n\nDictated:\n\n> Add a dark mode",
        ]])
        XCTAssertEqual(model.items.first?.state, .filed)
        XCTAssertEqual(model.items.first?.filedURL, "https://github.com/o/reach/issues/9")
        XCTAssertEqual(model.items.first?.filedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(routed.last, "Filed in o/reach")
        XCTAssertNil(model.file(id), "a filed capture is not filed again")
    }

    /// #923: a coding agent filed it with its own gh; the app only records it.
    func testAnAgentMarksACaptureFiledInItsOwnRepositoryOnly() async throws {
        let model = model(answer: ["reach": 0.9])
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)

        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/other/issues/3"), .failure(.otherRepository("o/reach")))
        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/reach/pull/3"), .failure(.notAnIssue))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.state, .ready)

        let filed = try model.markFiled(id, url: "https://github.com/O/Reach/issues/12").get()
        XCTAssertEqual(filed.state, .filed)
        XCTAssertEqual(filed.filedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.filedURL, "https://github.com/O/Reach/issues/12")
        XCTAssertEqual(routed.last, "Filed in o/reach")
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "the app files nothing itself")
        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/reach/issues/13"), .failure(.notReady(.filed)))
    }

    func testAFailedFilingKeepsTheCaptureAndARemoteProjectNeedsARepository() async throws {
        github.createResult = .failure(.failed(exitCode: 1))
        let model = model(answer: ["website": 0.9])
        await model.capture(text: "Update the about page", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(model.items.first?.note, "No draft for a project on another machine.")
        model.setTitle("About page", for: id)
        XCTAssertNil(model.file(id), "no repository yet")
        model.setRepository("o/website", for: id)
        await model.file(id)?.value
        XCTAssertEqual(model.items.first?.state, .ready)
        XCTAssertEqual(model.items.first?.note, "Filing failed. Check that gh is logged in.")
        XCTAssertEqual(github.created.withLock { $0.first?.last }, "Dictated:\n\n> Update the about page")
    }

    /// A voice memo's audio is kept under its item's id until the capture is
    /// filed or discarded (#925); a failed filing keeps it.
    func testACaptureIsDoneWhenFiledOrDiscardedNotWhenFilingFails() async throws {
        let model = model(answer: ["reach": 0.9])
        var done: [UUID] = []
        model.onDone = { done.append($0) }
        let memo = UUID(), other = UUID()
        let recordedAt = Date(timeIntervalSince1970: 999_000)
        await model.capture(text: "Add a dark mode", historyRecordID: nil, id: memo, capturedAt: recordedAt).value
        await model.capture(text: "Add a light mode", historyRecordID: nil, id: other).value
        XCTAssertEqual(model.items.first { $0.id == memo }?.capturedAt, recordedAt)

        github.createResult = .failure(.failed(exitCode: 1))
        await model.file(memo)?.value
        XCTAssertEqual(done, [])
        github.createResult = .success("https://github.com/o/reach/issues/9")
        await model.file(memo)?.value
        XCTAssertEqual(done, [memo])
        model.discard(other)
        XCTAssertEqual(done, [memo, other])
    }

    /// #926: the project's repository files and lists issues without
    /// asking gh, a fork set to file upstream does both upstream, and an
    /// `owner/name` typed for a project with none is kept on it.
    func testTheProjectsRepositoryIsUsedAndATypedOneIsKept() async throws {
        let projects = [
            QuickCaptureProject(
                key: "/w/tool", name: "tool", summary: nil, terms: [], userLine: nil,
                repository: "me/tool", issueRepository: "them/tool"),
            QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: [], userLine: nil),
        ]
        let model = model(answer: ["tool": 0.95], projects: projects)
        var answered: [[String]] = []
        model.onRepositoryAnswered = { answered.append([$0, $1]) }
        await model.capture(text: "Add a verbose flag", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(model.items.first?.repository, "them/tool")
        XCTAssertEqual(github.issuesListed.withLock { $0 }, ["them/tool"])

        model.setRepository("me/other", for: id)
        XCTAssertEqual(answered, [], "the project has a repository: the edit stays on this capture")

        await model.move(id, toProjectKey: "remote:website")?.value
        XCTAssertNil(model.items.first?.repository)
        model.setRepository("me/website", for: id)
        XCTAssertEqual(answered, [["remote:website", "me/website"]])
    }

    func testARemoteDraftSaysItWaitsForASessionUntilTheHostAnswers() async throws {
        let sleeper = ManualSleeper()
        let model = model(answer: ["website": 0.9]) { _, _, _, _ in
            await sleeper.sleep(0)
            return .notRun(.noHostSession)
        }
        let task = model.capture(text: "Update the about page", historyRecordID: nil)
        await sleeper.waitForSleepers(1)
        XCTAssertEqual(model.items.first?.state, .drafting)
        XCTAssertEqual(model.items.first?.note, QuickCaptureInbox.waitingForHostNote)
        XCTAssertEqual(
            QuickCaptureInboxFile.load(from: fileURL).items.first?.note, "Interrupted before a draft.",
            "a quit while it waits does not leave it claiming to wait"
        )
        sleeper.wakeAll()
        await task.value
        XCTAssertEqual(model.items.first?.note, "No session of this project answered on its host.")
    }

    /// A checkout at `tool` with these remotes, and a `gh` on the returned
    /// PATH that answers `upstream/tool` as its pick, the way gh picks with an
    /// `upstream` remote (#919), and logs its arguments to `gh-argv`.
    private func checkout(remotes: [(String, String)]) async throws -> (path: String, ghPATH: String, log: String) {
        let root = fileURL.deletingLastPathComponent()
        let checkout = root.appendingPathComponent("tool").path
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for arguments in [["init", "-q"]] + remotes.map({ ["remote", "add", $0.0, $0.1] }) {
            let output = await RepoGitRunner.run(arguments: arguments, root: checkout, timeoutSeconds: 60)
            XCTAssertEqual(output?.exitCode, 0, arguments.joined(separator: " "))
        }
        let log = root.appendingPathComponent("gh-argv").path
        let gh = bin.appendingPathComponent("gh")
        try """
        #!/bin/sh
        echo "$*" >>'\(log)'
        case "$1" in repo) echo upstream/tool ;; issue) echo '[]' ;; esac
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        return (checkout, bin.path, log)
    }

    /// A fork: the repository comes from `origin`, for filing and for the
    /// duplicate check alike.
    func testAForkCheckoutFilesInTheForkNotItsUpstream() async throws {
        let fork = try await checkout(remotes: [
            ("origin", "git@github.com:me/tool.git"), ("upstream", "https://github.com/upstream/tool.git"),
        ])
        let project = QuickCaptureProject(key: fork.path, name: "tool", summary: nil, terms: [], userLine: nil)

        let model = model(
            answer: ["tool": 0.9], github: QuickCaptureGHClient(environment: ["PATH": fork.ghPATH]), projects: [project]
        )
        await model.capture(text: "Add a verbose flag", historyRecordID: nil).value

        XCTAssertEqual(model.items.first?.repository, "me/tool")
        let calls = try String(contentsOfFile: fork.log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0.hasPrefix("issue list") }.map { $0.contains("--repo me/tool ") }, [true])
    }

    func testACheckoutWithNoOriginTakesGhsPick() async throws {
        let clone = try await checkout(remotes: [("upstream", "https://github.com/upstream/tool.git")])
        let client = QuickCaptureGHClient(environment: ["PATH": clone.ghPATH])
        let repository = await client.repository(ofCheckout: clone.path)
        XCTAssertEqual(repository, "upstream/tool")
    }

    func testARemoteURLNamesItsGitHubRepository() {
        for url in [
            "https://github.com/me/tool", "https://github.com/me/tool.git", "https://github.com/me/tool/\n",
            "git@github.com:me/tool.git", "git@github.com:me/tool", "ssh://git@github.com/me/tool.git",
            "ssh://git@GitHub.com:22/me/tool.git", "https://user@github.com/me/tool.git",
        ] {
            XCTAssertEqual(QuickCaptureFiling.repository(fromRemoteURL: url), "me/tool", url)
        }
        for url in [
            "https://gitlab.com/me/tool.git", "git@gitlab.com:me/tool.git", "https://github.com.evil.io/me/tool",
            "https://github.com/me", "https://github.com/me/tool/tree/main", "/srv/git/tool.git",
            "file:///srv/git/tool.git", "github.com-work:me/tool.git", "",
        ] {
            XCTAssertNil(QuickCaptureFiling.repository(fromRemoteURL: url), url)
        }
    }

    func testACaptureInterruptedByAQuitWaitsWithItsWords() throws {
        var inbox = QuickCaptureInbox()
        inbox.add(QuickCaptureItem(capturedAt: Date(), text: "Half done"))
        try QuickCaptureInboxFile.save(inbox, to: fileURL)
        let loaded = QuickCaptureInboxFile.load(from: fileURL)
        XCTAssertEqual(loaded.items.first?.state, .ready)
        XCTAssertEqual(loaded.items.first?.note, "Interrupted before a draft.")
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAFiledCaptureStaysAWeekFromItsFilingNotItsCapture() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var old = QuickCaptureItem(capturedAt: now.addingTimeInterval(-30 * 86_400), text: "old")
        old.state = .filed
        old.filedAt = now.addingTimeInterval(-86_400)
        var gone = QuickCaptureItem(capturedAt: now.addingTimeInterval(-30 * 86_400), text: "gone")
        gone.state = .filed
        gone.filedAt = now.addingTimeInterval(-8 * 86_400)
        var inbox = QuickCaptureInbox(items: [old, gone])
        inbox.prune(now: now)
        XCTAssertEqual(inbox.items.map(\.text), ["old"])
    }

    func testTheIssueURLIsTheLastURLGhPrints() {
        let output = Data("Creating issue in o/reach\n\nhttps://github.com/o/reach/issues/12\n".utf8)
        XCTAssertEqual(QuickCaptureFiling.issueURL(inOutput: output), "https://github.com/o/reach/issues/12")
        XCTAssertEqual(
            QuickCaptureFiling.createArguments(repository: "o/r", title: "T", body: "--help"),
            ["issue", "create", "--repo", "o/r", "--title", "T", "--body", "--help"]
        )
    }
}
