import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// Ready drafts in the needs-you cue and their spoken review (#927).
@MainActor
final class QuickCaptureDraftReviewTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 3_000_000)

    // MARK: - The cue

    func testADraftShowsOnlyAtTheNextBreakOldestFirst() async {
        var cue = QuickCaptureDraftCue()
        let (a, b) = (UUID(), UUID())
        cue.draftReady(.init(id: b, projectName: "api", readyAt: Self.epoch.addingTimeInterval(10)))
        cue.draftReady(.init(id: a, projectName: "reach", readyAt: Self.epoch))
        XCTAssertTrue(cue.shown.isEmpty, "held until the user reaches a break")

        XCTAssertTrue(cue.atBreak())
        XCTAssertEqual(cue.shownOldestFirst.map(\.id), [a, b])
        XCTAssertFalse(cue.atBreak(), "nothing held, nothing changes")

        // A redraft is a new draft: back to held until the next break.
        cue.draftReady(.init(id: a, projectName: "reach", readyAt: Self.epoch.addingTimeInterval(20)))
        XCTAssertEqual(cue.shown.map(\.id), [b])
        XCTAssertEqual(cue.held.map(\.id), [a])

        cue.retain { $0.id != b }
        XCTAssertTrue(cue.shown.isEmpty)
        XCTAssertEqual(cue.held.map(\.id), [a])
    }

    func testThePopoverLineNamesADraftOnlyWhenNoAgentIsQueued() async {
        let long = QuickCaptureDraftCue.Entry(id: UUID(), projectName: "a-very-long-project-name", readyAt: Self.epoch)
        let short = QuickCaptureDraftCue.Entry(id: UUID(), projectName: "reach", readyAt: Self.epoch)
        var queue = AgentAttentionQueue()
        XCTAssertEqual(AgentAttentionText.popoverLine(queue, drafts: [short]), "Draft ready: Inbox for reach")
        let line = AgentAttentionText.popoverLine(queue, drafts: [long])
        XCTAssertEqual(line, "Draft ready: Inbox for a-very-long-project-…")
        XCTAssertLessThanOrEqual(line?.count ?? 99, 44)

        queue.wait(sessionID: "a", name: "payments", agent: .claude, at: Self.epoch)
        XCTAssertEqual(
            AgentAttentionText.popoverLine(queue, drafts: [short, long]), "payments needs you (+2)",
            "an agent that needs you comes first; drafts add to the count"
        )
    }

    // MARK: - What was said

    func testOnlyTheWholePhraseFilesOrDropsAndASendPhraseIsNeverPartOfAChange() async {
        let phrases = SendNowCommandParser.defaultTriggerPhrases
        XCTAssertEqual(QuickCaptureSpokenReview.parse("File it.", sendPhrases: phrases), .file)
        XCTAssertEqual(QuickCaptureSpokenReview.parse(" drop it ", sendPhrases: phrases), .drop)
        XCTAssertEqual(QuickCaptureSpokenReview.parse("File it, send it.", sendPhrases: phrases), .file)
        XCTAssertEqual(
            QuickCaptureSpokenReview.parse("file it under polish", sendPhrases: phrases),
            .change("file it under polish")
        )
        XCTAssertEqual(
            QuickCaptureSpokenReview.parse("Make it only the popover part, send it.", sendPhrases: phrases),
            .change("Make it only the popover part")
        )
        XCTAssertEqual(QuickCaptureSpokenReview.parse("send it", sendPhrases: phrases), .nothing)
        XCTAssertEqual(QuickCaptureSpokenReview.parse("  ", sendPhrases: phrases), .nothing)
        XCTAssertTrue(QuickCaptureSpokenReview.isCommand("Drop it!"))
        XCTAssertFalse(QuickCaptureSpokenReview.isCommand("drop it and redo"))
    }

    func testTheExcerptIsCutAtAWord() async {
        let body = String(repeating: "word ", count: 80)
        let excerpt = QuickCaptureDraftSnapshot(id: UUID(), projectName: "p", title: "t", body: body).bodyExcerpt
        XCTAssertLessThanOrEqual(excerpt.count, QuickCaptureDraftSnapshot.maxExcerptCharacters + 1)
        XCTAssertTrue(excerpt.hasSuffix("word…"))
        XCTAssertEqual(
            QuickCaptureDraftSnapshot(
                id: UUID(), projectName: "p", title: "t", body: "## Scope\nAll pages.\n\n## Proof\n- A test\n* Another"
            ).bodyExcerpt,
            "All pages. A test Another"
        )
    }

    // MARK: - The Inbox

    private let github = FakeQuickCaptureGitHub()
    private let runner = FakeQuickCaptureDraftRunner()

    private func draftedModel() async throws -> (QuickCaptureInboxModel, UUID, [UUID]) {
        let model = QuickCaptureFixture.model(fileURL: nil, answer: ["reach": 0.9], github: github, runner: runner)
        var ready: [UUID] = []
        model.onDraftReady = { ready.append($0.id) }
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        return (model, id, ready)
    }

    func testAFinishedDraftIsReportedOnceAndAnEditIsNotADraftFinishing() async throws {
        let model = QuickCaptureFixture.model(fileURL: nil, answer: ["reach": 0.9], github: github, runner: runner)
        var ready: [UUID] = []
        model.onDraftReady = { ready.append($0.id) }
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(ready, [id])
        model.setTitle("Dark theme", for: id)
        XCTAssertEqual(ready, [id])


        let catchAll = QuickCaptureFixture.model(fileURL: nil, answer: ["inbox": 0.9], github: github, runner: runner)
        catchAll.onDraftReady = { ready.append($0.id) }
        await catchAll.capture(text: "An idea", historyRecordID: nil).value
        XCTAssertEqual(ready, [id], "the catch-all has no draft")
    }

    func testFileItFilesTheDraftAsShownAndOnlyThat() async throws {
        let (model, id, _) = try await draftedModel()
        var statuses: [String] = []
        model.onStatus = { statuses.append($0) }
        let shown = try XCTUnwrap(model.reviewSnapshot(id))

        model.setBody("Edited in the Inbox window", for: id)
        let refused = model.applySpokenReview(.file, to: shown)
        XCTAssertEqual(refused.status, QuickCaptureReviewStatus.changedSinceShown)
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "never files what the overlay did not show")

        let current = try XCTUnwrap(model.reviewSnapshot(id))
        let outcome = model.applySpokenReview(.file, to: current)
        XCTAssertEqual(outcome.status, QuickCaptureReviewStatus.filing)
        await outcome.task?.value
        XCTAssertEqual(github.created.withLock { $0.map(\.[1]) }, ["Dark mode"])
        XCTAssertEqual(model.items.first?.state, .filed)
        XCTAssertEqual(statuses.last, QuickCaptureReviewStatus.filed)
        XCTAssertEqual(model.applySpokenReview(.drop, to: current).status, QuickCaptureReviewStatus.gone)
    }

    /// A move keeps the title and body but changes where File sends them:
    /// "file it" files only into the repository the overlay showed.
    func testFileItRefusesADraftMovedToAnotherRepositorySinceItWasShown() async throws {
        let projects = QuickCaptureFixture.projects + [
            QuickCaptureProject(key: "/w/other", name: "other", summary: nil, terms: [], userLine: nil, issueRepository: "o/other"),
        ]
        let model = QuickCaptureFixture.model(
            fileURL: nil, answer: ["reach": 0.9], github: github, runner: runner, projects: projects)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        let id = try XCTUnwrap(model.items.first?.id)
        let shown = try XCTUnwrap(model.reviewSnapshot(id))

        await model.move(id, toProjectKey: "/w/other")?.value
        let moved = try XCTUnwrap(model.items.first)
        XCTAssertEqual(moved.repository, "o/other")
        XCTAssertEqual(moved.title, shown.title)
        XCTAssertEqual(moved.body, shown.body)

        let outcome = model.applySpokenReview(.file, to: shown)
        await outcome.task?.value
        XCTAssertEqual(outcome.status, QuickCaptureReviewStatus.changedSinceShown)
        XCTAssertTrue(github.created.withLock { $0.isEmpty }, "never files where the overlay did not show")
        XCTAssertEqual(model.items.first?.state, .ready)
    }

    func testDropItDiscards() async throws {
        let (model, id, _) = try await draftedModel()
        let outcome = model.applySpokenReview(.drop, to: try XCTUnwrap(model.reviewSnapshot(id)))
        XCTAssertEqual(outcome.status, QuickCaptureReviewStatus.dropped)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testAChangeRedraftsWithTheWordsTheDraftAndEveryChange() async throws {
        let (model, id, _) = try await draftedModel()
        var ready: [UUID] = []
        model.onDraftReady = { ready.append($0.id) }
        runner.nextTitles.withLock { $0 = ["Popover dark mode", "Popover dark mode, menu too"] }

        let first = model.applySpokenReview(.change("only the popover"), to: try XCTUnwrap(model.reviewSnapshot(id)))
        XCTAssertEqual(first.status, QuickCaptureReviewStatus.redrafting)
        XCTAssertEqual(model.items.first?.state, .drafting)
        await first.task?.value
        XCTAssertEqual(model.items.first?.title, "Popover dark mode")
        XCTAssertEqual(model.items.first?.text, "Add a dark mode", "the dictated words stay as said")
        XCTAssertEqual(ready, [id], "a redraft finishing is a draft ready again")
        let firstPrompt = runner.arguments.withLock { $0.last?.joined(separator: " ") ?? "" }
        XCTAssertTrue(firstPrompt.contains("Add a dark mode"))
        XCTAssertTrue(firstPrompt.contains("Title: Dark mode"))
        XCTAssertTrue(firstPrompt.contains("only the popover"))

        await model.applySpokenReview(.change("and the menu"), to: try XCTUnwrap(model.reviewSnapshot(id))).task?.value
        XCTAssertEqual(model.items.first?.changes, ["only the popover", "and the menu"])
        let secondPrompt = runner.arguments.withLock { $0.last?.joined(separator: " ") ?? "" }
        XCTAssertTrue(secondPrompt.contains("- only the popover\n- and the menu"))
    }

    func testNothingSaidKeepsTheDraft() async throws {
        let (model, id, _) = try await draftedModel()
        let outcome = model.applySpokenReview(.nothing, to: try XCTUnwrap(model.reviewSnapshot(id)))
        XCTAssertEqual(outcome.status, QuickCaptureReviewStatus.kept)
        XCTAssertEqual(model.items.first?.state, .ready)
        XCTAssertEqual(runner.runs.withLock { $0 }, 1)
    }

    func testTheReviewSentencesFitThePopoverLine() async {
        for sentence in [
            QuickCaptureReviewStatus.filing, QuickCaptureReviewStatus.filed, QuickCaptureReviewStatus.filingFailed,
            QuickCaptureReviewStatus.dropped, QuickCaptureReviewStatus.redrafting, QuickCaptureReviewStatus.kept,
            QuickCaptureReviewStatus.gone, QuickCaptureReviewStatus.changedSinceShown, QuickCaptureReviewStatus.cannotFile,
        ] {
            XCTAssertLessThanOrEqual(sentence.count, 44, sentence)
        }
    }
}
