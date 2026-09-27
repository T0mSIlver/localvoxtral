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
        remote: (@Sendable (String, QuickCaptureProject) async -> QuickCaptureDraft.Outcome)? = nil
    ) -> QuickCaptureInboxModel {
        let model = QuickCaptureFixture.model(fileURL: fileURL, answer: answer, github: github, runner: runner, remote: remote)
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

    func testARemoteDraftSaysItWaitsForASessionUntilTheHostAnswers() async throws {
        let sleeper = ManualSleeper()
        let model = model(answer: ["website": 0.9]) { _, _ in
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
