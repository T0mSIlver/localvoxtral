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
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.map(\.text), ["Add a dark mode"])
        await task.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.projectName, "reach")
        XCTAssertEqual(item.repository, "o/reach")
        XCTAssertEqual(item.title, "Dark mode")
        XCTAssertEqual(statuses, ["Sent to reach inbox"])
        XCTAssertEqual(routed, ["reach"])
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "nothing is filed without File")
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.title, "Dark mode")
    }

    /// A try-pr build beside the installed app (#990): both opened the
    /// Inbox before either captured, and neither loses the other's capture.
    func testTwoRunningCopiesKeepEachOthersCaptures() async throws {
        let installed = model(answer: ["reach": 0.9])
        let tryBuild = model(answer: ["reach": 0.9])

        await installed.capture(text: "Add a dark mode", historyRecordID: nil).value
        await tryBuild.capture(text: "Fix the login", historyRecordID: nil).value
        let first = try XCTUnwrap(installed.items.first { $0.text == "Add a dark mode" })
        installed.setTitle("Dark mode, finally", for: first.id)

        let onDisk = try XCTUnwrap(QuickCaptureInboxFile.load(from: fileURL).value)
        XCTAssertEqual(Set(onDisk.items.map(\.text)), ["Add a dark mode", "Fix the login"])
        XCTAssertEqual(onDisk.items.first { $0.id == first.id }?.title, "Dark mode, finally")
        XCTAssertEqual(Set(installed.items.map(\.text)), ["Add a dark mode", "Fix the login"])
    }

    /// Another running copy took a capture after this one loaded: the Inbox
    /// shows it when it appears, not only after this copy's next write
    /// (#1126).
    func testAppearingShowsACaptureAnotherCopyTookSinceThisOneLoaded() async throws {
        let installed = model(answer: ["reach": 0.9])
        let tryBuild = model(answer: ["reach": 0.9])
        await tryBuild.capture(text: "Fix the login", historyRecordID: nil).value

        installed.reloadIfChanged()

        XCTAssertEqual(installed.items.map(\.text), ["Fix the login"])
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

    /// Two running copies both show the draft ready (#990): once one filed
    /// it, File in the other, which has not read the file since, files
    /// nothing.
    func testACopyThatHasNotSeenAFilingDoesNotFileAgain() async throws {
        let installed = model(answer: ["reach": 0.9])
        await installed.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(installed.items.first?.id)
        let tryBuild = model(answer: ["reach": 0.9])
        await installed.file(id)?.value

        await tryBuild.file(id)?.value

        XCTAssertEqual(github.created.withLock { $0.count }, 1)
        XCTAssertEqual(tryBuild.items.first?.state, .filed)
        XCTAssertEqual(tryBuild.items.first?.filedURL, "https://github.com/o/reach/issues/9")
    }

    /// #923: a coding agent filed it with its own gh; the app only records it.
    func testAnAgentMarksACaptureFiledInItsOwnRepositoryOnly() async throws {
        let model = model(answer: ["reach": 0.9])
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)

        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/other/issues/3"), .failure(.otherRepository("o/reach")))
        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/reach/pull/3"), .failure(.notAnIssue))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.state, .ready)

        let filed = try model.markFiled(id, url: "https://github.com/O/Reach/issues/12").get()
        XCTAssertEqual(filed.state, .filed)
        XCTAssertEqual(filed.filedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.filedURL, "https://github.com/O/Reach/issues/12")
        XCTAssertEqual(routed.last, "Filed in o/reach")
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "the app files nothing itself")
        XCTAssertEqual(model.markFiled(id, url: "https://github.com/o/reach/issues/13"), .failure(.notReady(.filed)))
    }

    /// Another running copy moved the capture to another repository after
    /// this one loaded it (#990 review): marking it filed in the old one is
    /// refused against the file, and History is not told it was filed.
    func testMarkingFiledChecksWhatAnotherCopyChanged() async throws {
        let model = model(answer: ["reach": 0.9])
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)
        var onDisk = try XCTUnwrap(QuickCaptureInboxFile.load(from: fileURL).value)
        onDisk.update(id) { $0.repository = "o/website" }
        try PrivateFile.write(QuickCaptureInboxFile.encode(onDisk), to: fileURL)
        routed = []

        XCTAssertEqual(
            model.markFiled(id, url: "https://github.com/o/reach/issues/12"), .failure(.otherRepository("o/website")))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.state, .ready)
        XCTAssertEqual(routed, [])
    }

    /// #938: an unsure capture waits unplaced with the router's guess; no
    /// agent runs until one click moves it there.
    func testAnUnsureCaptureWaitsWithASuggestionAndDraftsOnlyOnceAccepted() async throws {
        let model = model(answer: ["reach": 0.85])
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)
        var item = try XCTUnwrap(model.items.first)
        XCTAssertNil(item.projectKey)
        XCTAssertEqual(item.suggestion, .init(projectKey: "/w/reach", projectName: "reach"))
        XCTAssertEqual(item.note, "Not routed to a project. Move it to one.")
        XCTAssertEqual(statuses, ["Sent to inbox"])
        XCTAssertEqual(routed, ["Inbox"])
        XCTAssertEqual(runner.runs.withLock { $0 }, 0, "no agent spend on a guess")
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.suggestion?.projectKey, "/w/reach")

        await model.acceptSuggestion(id)?.value
        item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.projectName, "reach")
        XCTAssertNil(item.suggestion)
        XCTAssertEqual(item.title, "Dark mode")
        XCTAssertEqual(runner.runs.withLock { $0 }, 1)
        XCTAssertTrue(item.canFile)
    }

    /// A drafted capture moved to a checkout whose `origin` is still being
    /// read, then to No project: the late answer is the project it left,
    /// so it is not attached and File stays off.
    func testALateRepositoryLookupIsDroppedOnceTheCaptureMovedOn() async throws {
        let model = model(answer: ["reach": 0.9])
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        await model.move(id, toProjectKey: "remote:website")?.value
        XCTAssertNil(model.items.first?.repository)

        let lookup = ManualSleeper()
        github.repositoryGate = lookup
        let moveBack = try XCTUnwrap(model.move(id, toProjectKey: "/w/reach"))
        await lookup.waitForSleepers(1)
        XCTAssertNil(model.move(id, toProjectKey: nil))
        lookup.wakeAll()
        await moveBack.value

        let item = try XCTUnwrap(model.items.first)
        XCTAssertNil(item.projectKey)
        XCTAssertNil(item.repository)
        XCTAssertFalse(item.canFile)
    }

    func testMovingElsewhereDropsTheSuggestion() async throws {
        let model = model(answer: ["reach": 0.5])
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        await model.move(id, toProjectKey: "remote:website")?.value
        XCTAssertNil(model.items.first?.suggestion)
        XCTAssertNil(model.acceptSuggestion(id))
    }

    func testASuggestionWhoseProjectIsGoneSaysSoInsteadOfMoving() async throws {
        var listed = projects
        let model = QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: [FixedQuickCaptureClassifier(["reach": 0.5])]) },
            projects: { listed },
            agents: { [.claude] },
            drafter: { QuickCaptureDrafter(runner: self.runner, openIssues: { _, _ in [] }, trackedFiles: { _ in [] }) },
            github: github
        )
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        listed.removeAll { $0.name == "reach" }
        XCTAssertNil(model.acceptSuggestion(id))
        XCTAssertNil(model.items.first?.projectKey)
        XCTAssertNil(model.items.first?.suggestion)
        XCTAssertEqual(model.items.first?.note, "reach is no longer a project. Move it to one.")
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

    /// #988: a discard or filing the Inbox file never recorded leaves the
    /// capture's audio, since a relaunch brings the capture back.
    func testACaptureIsNotDoneWhileItsInboxFileCannotBeWritten() async throws {
        let model = model(answer: ["reach": 0.9])
        var done: [UUID] = []
        model.onDone = { done.append($0) }
        let filed = UUID(), discarded = UUID()
        await model.capture(text: "Add a dark mode", historyRecordID: nil, id: filed).value
        await model.capture(text: "Add a light mode", historyRecordID: nil, id: discarded).value
        // A file where the Inbox's folder goes: every save fails, even as
        // root. A folder at the file's own path would read as unreadable,
        // which refuses the Inbox instead (#990).
        let inboxFolder = fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: inboxFolder)
        try Data().write(to: inboxFolder)

        github.createResult = .success("https://github.com/o/reach/issues/9")
        await model.file(filed)?.value
        XCTAssertTrue(model.hasUnsavedChanges, "the save failed rather than the Inbox being refused")
        model.discard(discarded)
        XCTAssertEqual(done, [])
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

    /// "File issues here" changed while captures wait: File goes where the
    /// project files now, and the issue a draft extended in the fork is
    /// dropped. A repository typed for one capture stays.
    func testChangingWhereAForkFilesMovesItsWaitingCaptures() async throws {
        let facts = GitHubRepositoryFacts(description: nil, topics: [], parent: "them/tool")
        let fork = QuickCaptureProject(
            key: "/w/tool", name: "tool", summary: nil, terms: [], userLine: nil, repository: "me/tool", github: facts)
        let upstream = QuickCaptureProject(
            key: "/w/tool", name: "tool", summary: nil, terms: [], userLine: nil,
            repository: "me/tool", issueRepository: "them/tool", github: facts)
        let list = ProjectListBox([fork])
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Verbose flag", body: "b", relation: .extends, issue: 7), usage: nil),
        ])
        let model = QuickCaptureFixture.model(
            fileURL: fileURL, answer: ["tool": 0.95], github: github, runner: runner, currentProjects: { list.value })
        await model.capture(text: "Add a verbose flag", historyRecordID: nil).value
        await model.capture(text: "Add a quiet flag", historyRecordID: nil).value
        let typed = try XCTUnwrap(model.items.first?.id)
        let id = try XCTUnwrap(model.items.last?.id)
        model.setRepository("me/other", for: typed)
        XCTAssertEqual(model.items.last?.repository, "me/tool")

        list.value = [upstream]
        model.adoptProjects()

        let item = try XCTUnwrap(model.items.last)
        XCTAssertEqual(item.repository, "them/tool")
        XCTAssertNil(item.relatedIssue, "#7 is the fork's issue")
        XCTAssertFalse(item.canComment)
        XCTAssertEqual(model.items.first?.repository, "me/other", "a typed repository is the user's")
        await model.file(id)?.value
        XCTAssertEqual(github.created.withLock { $0.map(\.first) }, ["them/tool"])
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
            QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.note, "Interrupted before a draft.",
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

    // MARK: An inbox file this build cannot load (#989)

    private func writeInboxFile(_ contents: String) throws -> Data {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(contents.utf8)
        try data.write(to: fileURL)
        return data
    }

    /// A capture into a refused Inbox is not taken: the file keeps its
    /// bytes, the popover says so, and the words stay in History.
    private func assertRefusesACapture(
        _ contents: Data, problem: StoredFileProblem, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let model = model(answer: ["reach": 0.9])
        XCTAssertEqual(model.storeProblem, problem, file: file, line: line)
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value

        XCTAssertEqual(try Data(contentsOf: fileURL), contents, "the file keeps its bytes", file: file, line: line)
        XCTAssertTrue(model.items.isEmpty, file: file, line: line)
        XCTAssertEqual(statuses, [QuickCaptureInboxModel.refusedStatus], file: file, line: line)
    }

    func testANewerInboxFileKeepsItsBytesAfterACapture() async throws {
        let data = try writeInboxFile(#"{"version":\#(QuickCaptureInbox.currentVersion + 1),"items":[{"future":true}]}"#)
        try await assertRefusesACapture(data, problem: .newerVersion(QuickCaptureInbox.currentVersion + 1))
    }

    func testACorruptInboxFileKeepsItsBytesAfterACapture() async throws {
        let data = try writeInboxFile(#"{"version":1,"items":[{"text":"half"#)
        try await assertRefusesACapture(data, problem: .unreadable)
    }

    /// Before #989 the load renamed a bad file to one fixed `.unreadable`
    /// name and went on empty when that name was taken.
    func testAnEarlierUnreadableFileIsLeftAloneToo() async throws {
        let data = try writeInboxFile(#"{"version":1,"items":[{"text":"half"#)
        let earlier = fileURL.appendingPathExtension("unreadable")
        try Data("earlier".utf8).write(to: earlier)
        try await assertRefusesACapture(data, problem: .unreadable)
        XCTAssertEqual(try Data(contentsOf: earlier), Data("earlier".utf8))
    }

    /// A voice memo's capture into a refused Inbox throws, so the intake
    /// leaves the memo in its folder (#988).
    func testAVoiceMemoCaptureIntoARefusedInboxThrows() async throws {
        let data = try writeInboxFile("{ not json")
        let model = model(answer: ["reach": 0.9])

        XCTAssertThrowsError(
            try model.captureVoiceMemo(text: "Add a dark mode", historyRecordID: nil, id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_000_000))
        ) { XCTAssertTrue($0 is QuickCaptureInboxModel.StoreRefused) }
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        XCTAssertTrue(model.items.isEmpty)
    }

    /// Start Over moves the file beside itself under a new name, and the
    /// Inbox saves again.
    func testStartOverMovesTheInboxFileAsideAndSavesAgain() async throws {
        let data = try writeInboxFile("{ not json")
        let model = model(answer: ["reach": 0.9])
        let aside = try model.moveAsideAndStartOver()

        XCTAssertEqual(try Data(contentsOf: aside), data)
        XCTAssertNil(model.storeProblem)
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.map(\.text), ["Add a dark mode"])
    }

    func testACaptureInterruptedByAQuitWaitsWithItsWords() throws {
        var inbox = QuickCaptureInbox()
        inbox.add(QuickCaptureItem(capturedAt: Date(), text: "Half done"))
        try QuickCaptureInboxFile.save(inbox, to: fileURL)
        let loaded = try XCTUnwrap(QuickCaptureInboxFile.load(from: fileURL).value)
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

/// The project list as the Projects pane has it now.
@MainActor
private final class ProjectListBox {
    var value: [QuickCaptureProject]
    init(_ value: [QuickCaptureProject]) { self.value = value }
}
