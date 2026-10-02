import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #965: a follow-up joins its idea instead of becoming a second capture,
/// Split takes it back out, and Comment on #N posts on an issue the draft
/// extends.
@MainActor
final class QuickCaptureFollowUpTests: XCTestCase {
    private var fileURL: URL!
    private let github = FakeQuickCaptureGitHub()
    private var statuses: [String] = []
    private var routed: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-followup-\(UUID().uuidString)")
            .appendingPathComponent("quick-captures.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func model(
        classifier: ScriptedQuickCaptureClassifier, runner: any QuickCaptureDraftRunning,
        projects: (@MainActor () -> [QuickCaptureProject])? = nil
    ) -> QuickCaptureInboxModel {
        let model = QuickCaptureFixture.model(
            fileURL: fileURL, answer: [:], github: github, runner: runner, currentProjects: projects,
            classifier: classifier, now: { [unowned self] in self.clock }
        )
        model.onStatus = { [weak self] in self?.statuses.append($0) }
        model.onRouted = { [weak self] _, destination in self?.routed.append(destination) }
        return model
    }

    private func prompts(_ runner: FakeQuickCaptureDraftRunner) -> [String] {
        runner.arguments.withLock { $0.map { $0.joined(separator: " ") } }
    }

    // MARK: Joining

    /// "Also …" joins the latest open capture without asking the router, and
    /// the redraft starts from the draft as the user left it.
    func testACaptureThatBeginsAlsoJoinsTheLatestCaptureAndRedraftsFromTheEditedDraft() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        runner.nextTitles.withLock { $0 = ["Dark mode", "Dark mode, settings too"] }
        let model = model(classifier: classifier, runner: runner)
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)
        model.setTitle("Dark theme", for: id)

        clock += 600
        let followUp = UUID()
        await model.capture(text: "Also, the settings window", historyRecordID: UUID(), id: followUp).value

        XCTAssertEqual(model.items.count, 1, "no second item")
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.followUps?.map(\.id), [followUp])
        XCTAssertEqual(item.words, "Add a dark mode\n\nAlso, the settings window")
        XCTAssertEqual(item.title, "Dark mode, settings too")
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(classifier.calls.withLock { $0.count }, 1, "the words alone decided the join")
        let redraft = try XCTUnwrap(prompts(runner).last)
        XCTAssertTrue(redraft.contains("Title: Dark theme"), "the user's edit is the base")
        XCTAssertTrue(redraft.contains("Add what the user said next: Also, the settings window"))
        XCTAssertEqual(statuses.last, "Added to an earlier capture")
        XCTAssertEqual(routed, ["reach", "Added to a reach capture"])
        XCTAssertTrue(item.bodyToFile.hasSuffix("> Add a dark mode\n> \n> Also, the settings window"))
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.followUps?.first?.text, "Also, the settings window")
    }

    /// The router's pick of an open capture joins it only past the bars; an
    /// unsure pick drafts nothing and suggests that capture's project.
    func testTheRouterJoinsAnOpenCaptureOnlyPastItsBars() async throws {
        let classifier = ScriptedQuickCaptureClassifier([
            ["reach": 0.95], ["capture-1": 0.95, "reach": 0.05], ["capture-1": 0.7, "reach": 0.3],
        ])
        let runner = FakeQuickCaptureDraftRunner()
        let model = model(classifier: classifier, runner: runner)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let first = try XCTUnwrap(model.items.first?.id)

        clock += 60
        await model.capture(text: "It should follow the system setting", historyRecordID: nil).value
        XCTAssertEqual(model.items.map(\.id), [first])
        XCTAssertEqual(model.items.first?.followUps?.map(\.text), ["It should follow the system setting"])
        let offered = try XCTUnwrap(classifier.calls.withLock { $0.last })
        XCTAssertEqual(offered.map(\.id), ["reach", "website", "capture-1", "inbox"])
        XCTAssertEqual(offered[2].description, "An earlier note, not filed yet (reach): \"Dark mode\"")
        XCTAssertEqual(offered[2].captureID, first)
        XCTAssertEqual(runner.runs.withLock { $0 }, 2)

        clock += 60
        await model.capture(text: "Maybe a high contrast mode", historyRecordID: nil).value
        XCTAssertEqual(model.items.count, 2)
        let unsure = try XCTUnwrap(model.items.first)
        XCTAssertNil(unsure.projectKey)
        XCTAssertEqual(unsure.suggestion?.projectKey, "/w/reach")
        XCTAssertEqual(model.items.last?.followUps?.count, 1)
        XCTAssertEqual(runner.runs.withLock { $0 }, 2, "nothing drafted on an unsure pick")
    }

    /// A capture with no project takes the follow-up's words and drafts
    /// nothing; the join is reported once, as a join.
    func testTheRouterJoinsAnUnplacedCaptureWithoutDrafting() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["inbox": 0.9], ["capture-1": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        let model = model(classifier: classifier, runner: runner)
        await model.capture(text: "Renew the passport", historyRecordID: UUID()).value
        await model.capture(text: "Before December", historyRecordID: UUID()).value
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.words, "Renew the passport\n\nBefore December")
        XCTAssertEqual(statuses, ["Sent to inbox", "Added to an earlier capture"])
        XCTAssertEqual(routed, ["Inbox", "Added to an Inbox capture"])
        XCTAssertEqual(runner.runs.withLock { $0 }, 0)
    }

    func testOnlyUnfiledCapturesFromTheLastHourAreOffered() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let model = model(classifier: classifier, runner: FakeQuickCaptureDraftRunner())
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        await model.capture(
            text: "Add a light mode", historyRecordID: nil, capturedAt: clock.addingTimeInterval(-7200)
        ).value
        await model.file(try XCTUnwrap(model.items.first { $0.text == "Add a dark mode" }?.id))?.value

        clock += 60
        await model.capture(text: "Also a keyboard shortcut", historyRecordID: nil).value
        XCTAssertEqual(model.items.count, 3, "the filed one and the two-hour-old one take no follow-up")
        XCTAssertEqual(classifier.calls.withLock { $0.last?.compactMap(\.captureID) }, [])
    }

    func testTheFollowUpWords() {
        for text in [
            "Also the popover", "also, the popover", "  ALSO: the popover", "For that idea, add a toggle",
            "And also, the popover", "Oh, and for that idea: a toggle",
        ] {
            XCTAssertTrue(QuickCaptureInbox.saysFollowUp(text), text)
        }
        for text in ["Add also a toggle", "Although it works", "For that ideal case", "", "for that", "And then also"] {
            XCTAssertFalse(QuickCaptureInbox.saysFollowUp(text), text)
        }
    }

    /// A draft still running when a follow-up joins must not land after the
    /// redraft that includes the follow-up.
    func testADraftRunningWhenAFollowUpJoinsIsDropped() async throws {
        let runner = TwoGateRunner()
        let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
        let capturing = model.capture(text: "Add a dark mode", historyRecordID: nil)
        await runner.first.waitForSleepers(1)
        XCTAssertEqual(model.items.first?.state, .drafting)

        let joining = model.capture(text: "Also the settings window", historyRecordID: nil)
        await runner.second.waitForSleepers(1)
        runner.second.wakeAll()
        await joining.value
        XCTAssertEqual(model.items.first?.title, "With settings")

        runner.first.wakeAll()
        await capturing.value
        XCTAssertEqual(model.items.first?.title, "With settings", "the stale draft is dropped")
        XCTAssertEqual(model.items.first?.state, .ready)
    }

    /// #988: after a relaunch a follow-up still counts as in the Inbox, and
    /// its recording is kept with its item's until the item is done.
    func testAFollowUpKeepsItsRecordingAcrossARelaunchUntilItsItemIsDiscarded() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["inbox": 0.9]])
        let first = model(classifier: classifier, runner: FakeQuickCaptureDraftRunner())
        let parent = UUID()
        let followUp = UUID()
        await first.capture(text: "Renew the passport", historyRecordID: nil, id: parent).value
        await first.capture(text: "Also book the photo", historyRecordID: nil, id: followUp).value
        XCTAssertEqual(first.items.map(\.id), [parent])

        let relaunched = model(classifier: classifier, runner: FakeQuickCaptureDraftRunner())
        XCTAssertTrue(relaunched.holds(followUp))
        XCTAssertEqual(relaunched.recordingIDsToKeep, [parent, followUp])

        var done: [UUID] = []
        relaunched.onDone = { done.append($0) }
        relaunched.discard(parent)
        XCTAssertEqual(done, [parent, followUp])
        XCTAssertFalse(relaunched.holds(followUp))
        XCTAssertEqual(relaunched.recordingIDsToKeep, [])
    }

    // MARK: Split

    func testSplitGivesTheDraftBackAndRoutesTheFollowUpOnItsOwn() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95], ["inbox": 0.9]])
        let runner = FakeQuickCaptureDraftRunner()
        runner.nextTitles.withLock { $0 = ["Dark mode", "Dark mode and a new logo"] }
        let model = model(classifier: classifier, runner: runner)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        let followUp = UUID()
        await model.capture(text: "Also a new logo", historyRecordID: nil, id: followUp).value
        XCTAssertEqual(model.items.first?.title, "Dark mode and a new logo")

        await model.split(followUp, from: id)?.value

        XCTAssertEqual(model.items.map(\.id), [followUp, id])
        let item = try XCTUnwrap(model.items.last)
        XCTAssertEqual(item.title, "Dark mode", "the draft from before the join")
        XCTAssertNil(item.followUps)
        XCTAssertEqual(item.state, .ready)
        let split = try XCTUnwrap(model.items.first)
        XCTAssertEqual(split.text, "Also a new logo")
        XCTAssertNil(split.projectKey)
        XCTAssertEqual(runner.runs.withLock { $0 }, 2, "restoring costs no draft")
        XCTAssertEqual(
            classifier.calls.withLock { $0.last?.compactMap(\.captureID) }, [], "a split capture is never joined back"
        )
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.map(\.id), [followUp, id])
    }

    /// Split after "File issues here" changed: the draft it gives back
    /// links no issue of the repository the capture no longer files in.
    func testSplitAfterAFilingChangeGivesBackNoIssueOfTheOldRepository() async throws {
        let facts = GitHubRepositoryFacts(description: nil, topics: [], parent: "them/reach")
        func reach(filingIn issueRepository: String) -> [QuickCaptureProject] {
            [QuickCaptureProject(
                key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil,
                repository: "me/reach", issueRepository: issueRepository, github: facts)]
        }
        let list = Mutex(reach(filingIn: "me/reach"))
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Dark mode", body: "b", relation: .extends, issue: 7), usage: nil),
        ])
        let model = model(
            classifier: ScriptedQuickCaptureClassifier([["reach": 0.95], ["inbox": 0.9]]), runner: runner,
            projects: { list.withLock { $0 } })
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        let followUp = UUID()
        await model.capture(text: "Also a new logo", historyRecordID: nil, id: followUp).value

        list.withLock { $0 = reach(filingIn: "them/reach") }
        model.adoptProjects()
        await model.split(followUp, from: id)?.value

        let item = try XCTUnwrap(model.items.first { $0.id == id })
        XCTAssertEqual(item.title, "Dark mode", "the draft from before the join")
        XCTAssertEqual(item.repository, "them/reach")
        XCTAssertNil(item.relatedIssue)
        XCTAssertFalse(item.canComment)
    }

    /// Split after a move: the draft it gives back links no issue of the
    /// project the capture left.
    func testSplitAfterAMoveGivesBackNoIssueOfTheOldProject() async throws {
        let projects = QuickCaptureFixture.projects + [
            QuickCaptureProject(
                key: "/w/tool", name: "tool", summary: nil, terms: [], userLine: nil, repository: "me/tool"),
        ]
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Dark mode", body: "b", relation: .extends, issue: 7), usage: nil),
        ])
        let model = model(
            classifier: ScriptedQuickCaptureClassifier([["reach": 0.95], ["inbox": 0.9]]), runner: runner,
            projects: { projects })
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        let followUp = UUID()
        await model.capture(text: "Also a new logo", historyRecordID: nil, id: followUp).value

        await model.move(id, toProjectKey: "/w/tool")?.value
        await model.split(followUp, from: id)?.value

        let item = try XCTUnwrap(model.items.first { $0.id == id })
        XCTAssertEqual(item.title, "Dark mode", "the draft from before the join")
        XCTAssertEqual(item.repository, "me/tool")
        XCTAssertNil(item.relatedIssue)
        XCTAssertFalse(item.canComment)
    }

    func testSplittingAnEarlierFollowUpRedraftsFromTheRemainingWords() async throws {
        let runner = FakeQuickCaptureDraftRunner()
        let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95], ["inbox": 0.9]]), runner: runner)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        let logo = UUID()
        await model.capture(text: "Also a new logo", historyRecordID: nil, id: logo).value
        await model.capture(text: "Also for the popover", historyRecordID: nil).value

        await model.split(logo, from: id)?.value

        XCTAssertEqual(model.items.first { $0.id == id }?.words, "Add a dark mode\n\nAlso for the popover")
        let redraft = try XCTUnwrap(prompts(runner).last)
        XCTAssertTrue(redraft.contains("Also for the popover"))
        XCTAssertFalse(redraft.contains("new logo"))
    }

    // MARK: Filed by a coding agent

    /// #1177: a capture a coding agent filed is done like one filed on a
    /// click: the audio of the capture and its follow-up goes once the
    /// Inbox saved it, and both History records say where it went. A
    /// failed save keeps the audio, and a refused Inbox changes nothing.
    func testAnAgentFilingACaptureWithAFollowUpReleasesBothAndRoutesBothRecords() async throws {
        for outcome in ["saved", "save failed", "refused"] {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            let runner = FakeQuickCaptureDraftRunner()
            runner.nextTitles.withLock { $0 = ["Dark mode", "Dark mode, settings too"] }
            let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
            var done: [UUID] = []
            var routedRecords: [UUID: String] = [:]
            model.onDone = { done.append($0) }
            let id = UUID(), followUp = UUID(), record = UUID(), followUpRecord = UUID()
            await model.capture(text: "Add a dark mode", historyRecordID: record, id: id).value
            await model.capture(text: "Also, the settings window", historyRecordID: followUpRecord, id: followUp).value
            XCTAssertEqual(model.items.first?.followUps?.map(\.id), [followUp], outcome)
            model.onRouted = { routedRecords[$0] = $1 }

            switch outcome {
            case "save failed":
                // A file where the Inbox's folder goes: the Inbox reads as
                // absent and every save fails, even as root (as in
                // VoiceMemoIntakeTests; a folder at the file's path would
                // refuse the Inbox instead).
                let folder = fileURL.deletingLastPathComponent()
                try FileManager.default.removeItem(at: folder)
                try Data().write(to: folder)
            case "refused":
                try Data(#"{"version":1,"items":[{"text":"half"#.utf8).write(to: fileURL)
            default:
                break
            }
            let result = model.markFiled(id, url: "https://github.com/o/reach/issues/12")

            switch outcome {
            case "saved":
                XCTAssertEqual(try result.get().state, .filed)
                XCTAssertEqual(done, [id, followUp])
                XCTAssertEqual(routedRecords, [record: "Filed in o/reach", followUpRecord: "Filed in o/reach"])
            case "save failed":
                XCTAssertEqual(try result.get().state, .filed)
                XCTAssertTrue(model.hasUnsavedChanges)
                XCTAssertEqual(done, [], "a relaunch brings the capture back, so its audio stays")
                XCTAssertEqual(routedRecords, [record: "Filed in o/reach", followUpRecord: "Filed in o/reach"])
            default:
                XCTAssertEqual(result, .failure(.notFound))
                XCTAssertEqual(done, [])
                XCTAssertEqual(routedRecords, [:])
            }
        }
    }

    // MARK: Comment on #N

    func testCommentOnTheIssueADraftExtendsPostsOnceOnClick() async throws {
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Dark mode", body: "## Scope\nAll pages.", relation: .extends, issue: 7), usage: nil),
        ])
        let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
        var done: [UUID] = []
        model.onDone = { done.append($0) }
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value
        let id = try XCTUnwrap(model.items.first?.id)
        let followUp = UUID()
        await model.capture(text: "Also the popover", historyRecordID: UUID(), id: followUp).value
        XCTAssertTrue(try XCTUnwrap(model.items.first).canComment)
        XCTAssertTrue(github.comments.withLock { $0.isEmpty }, "nothing posted before the click")

        await model.comment(id)?.value

        XCTAssertEqual(github.comments.withLock { $0 }, [[
            "o/reach", "7",
            "**Dark mode**\n\n## Scope\nAll pages.\n\nDictated:\n\n> Add a dark mode\n> \n> Also the popover",
        ]])
        XCTAssertTrue(github.created.withLock { $0.isEmpty })
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .filed)
        XCTAssertEqual(item.commentedOn, 7)
        XCTAssertEqual(item.filedURL, "https://github.com/o/reach/issues/7#issuecomment-1")
        XCTAssertEqual(done, [id, followUp])
        XCTAssertEqual(Array(routed.suffix(2)), ["Commented on o/reach#7", "Commented on o/reach#7"])
        XCTAssertNil(model.comment(id), "never twice")
    }

    /// Two running copies both show the draft (#990): once one commented,
    /// Comment in the other, which has not read the file since, posts
    /// nothing.
    func testACopyThatHasNotSeenACommentDoesNotPostAgain() async throws {
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Dark mode", body: "b", relation: .extends, issue: 7), usage: nil),
        ])
        let installed = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
        await installed.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(installed.items.first?.id)
        let tryBuild = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
        await installed.comment(id)?.value

        await tryBuild.comment(id)?.value

        XCTAssertEqual(github.comments.withLock { $0.count }, 1)
        XCTAssertEqual(tryBuild.items.first?.state, .filed)
    }

    func testCommentNeedsAnExtendsRelationAndAFailureKeepsTheCapture() async throws {
        for relation in [QuickCaptureDraft.Draft.Relation.none, .duplicate] {
            let runner = FakeQuickCaptureCheckRunner([
                .draft(.init(title: "Dark mode", body: "b", relation: relation, issue: relation == .none ? nil : 7), usage: nil),
            ])
            let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
            await model.capture(text: "Add a dark mode", historyRecordID: nil).value
            XCTAssertNil(model.comment(try XCTUnwrap(model.items.first?.id)), relation.rawValue)
        }
        XCTAssertTrue(github.comments.withLock { $0.isEmpty })

        try FileManager.default.removeItem(at: fileURL)
        github.commentResult = .failure(.failed(exitCode: 1))
        let runner = FakeQuickCaptureCheckRunner([
            .draft(.init(title: "Dark mode", body: "b", relation: .extends, issue: 7), usage: nil),
        ])
        let model = model(classifier: ScriptedQuickCaptureClassifier([["reach": 0.95]]), runner: runner)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        await model.comment(id)?.value
        XCTAssertEqual(model.items.first?.state, .ready)
        XCTAssertEqual(model.items.first?.note, "The comment failed. Check that gh is logged in.")
        XCTAssertTrue(try XCTUnwrap(model.items.first).canComment)
    }

    // MARK: Classifier requests

    /// With no open capture the requests are what they were before #965
    /// (`JevClassifierTests` pins those); with one, both classifiers are
    /// told what an earlier note means.
    func testOpenCapturesChangeTheRequestsOnlyWhenThereAreSome() throws {
        let projects = QuickCaptureFixture.projects
        let plain = QuickCaptureRouting.options(for: projects)
        XCTAssertEqual(QuickCaptureRouting.options(for: projects, openCaptures: []), plain)
        XCTAssertEqual(QuickCaptureChatRouting.systemPrompt(for: plain), QuickCaptureChatRouting.systemPrompt)
        XCTAssertFalse(QuickCaptureChatRouting.userMessage(capture: "c", options: plain).contains("Earlier notes"))

        let open = QuickCaptureOpenCapture(id: UUID(), projectKey: nil, summary: "Add a dark mode")
        let options = QuickCaptureRouting.options(for: projects, openCaptures: [open])
        XCTAssertEqual(options.map(\.id), ["reach", "website", "capture-1", "inbox"])
        XCTAssertEqual(options[2].description, "An earlier note, not filed yet: \"Add a dark mode\"")
        XCTAssertTrue(
            QuickCaptureChatRouting.systemPrompt(for: options).hasSuffix(QuickCaptureChatRouting.followUpInstruction)
        )
        XCTAssertEqual(
            QuickCaptureChatRouting.userMessage(capture: "c", options: options),
            "Projects:\n- reach: \(options[0].description)\n- website: \(options[1].description)\n- inbox: \(options[3].description)"
                + "\n\nEarlier notes:\n- capture-1: \(options[2].description)\n\nNote:\nc"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Jev.requestBody(model: "m", capture: "c", options: options)) as? [String: Any])
        let question = try XCTUnwrap((body["questions"] as? [String: Any])?["project"] as? [String: Any])
        XCTAssertEqual(question["instructions"] as? String, Jev.followUpInstructions)
        XCTAssertEqual((question["criteria"] as? [String: String])?["capture-1"], options[2].description)
    }

    func testTheCommentURLIsTheLastOneGhPrints() {
        let output = Data("https://github.com/o/reach/issues/7#issuecomment-123\n".utf8)
        XCTAssertEqual(QuickCaptureFiling.commentURL(inOutput: output), "https://github.com/o/reach/issues/7#issuecomment-123")
        XCTAssertNil(QuickCaptureFiling.commentURL(inOutput: Data("https://github.com/o/reach/issues/7\n".utf8)))
        XCTAssertEqual(
            QuickCaptureFiling.commentArguments(repository: "o/r", issue: 7, body: "--help"),
            ["issue", "comment", "7", "--repo", "o/r", "--body", "--help"]
        )
    }
}

/// The agent: its first run waits on `first`, its second on `second`, and a
/// prompt that mentions the settings window drafts "With settings".
private final class TwoGateRunner: QuickCaptureDraftRunning, @unchecked Sendable {
    let first = ManualSleeper()
    let second = ManualSleeper()
    private let calls = Mutex(0)

    func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
        let call = calls.withLock { $0 += 1; return $0 }
        await (call == 1 ? first : second).sleep(0)
        let title = invocation.arguments.joined(separator: " ").contains("settings window") ? "With settings" : "Dark mode"
        return .draft(.init(title: title, body: "b", relation: .none, issue: nil), usage: nil)
    }
}
