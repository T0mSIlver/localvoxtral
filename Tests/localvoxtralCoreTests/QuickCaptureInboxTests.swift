import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

@MainActor
final class QuickCaptureInboxTests: XCTestCase {
    private final class GitHub: QuickCaptureGitHub, @unchecked Sendable {
        let created = Mutex<[[String]]>([])
        var createResult: Result<String, QuickCaptureFiling.Failure> = .success("https://github.com/o/reach/issues/9")
        func repository(ofCheckout path: String) async -> String? { path == "/w/reach" ? "o/reach" : nil }
        func openIssues(ofCheckout path: String) async -> [QuickCaptureDraft.OpenIssue]? { [] }
        func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
            created.withLock { $0.append([repository, title, body]) }
            return createResult
        }
    }

    private final class Classifier: QuickCaptureClassifying, @unchecked Sendable {
        let answer: [String: Double]
        init(_ answer: [String: Double]) { self.answer = answer }
        var kind: QuickCaptureRoute.Classifier { .jev }
        func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] { answer }
    }

    private final class Runner: QuickCaptureDraftRunning, @unchecked Sendable {
        let runs = Mutex(0)
        func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
            runs.withLock { $0 += 1 }
            return .draft(.init(title: "Dark mode", body: "## Scope\nAll pages.", relation: .none, issue: nil), usage: nil)
        }
    }

    private let projects = [
        QuickCaptureProject(key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil),
        QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: [], userLine: nil),
    ]
    private var fileURL: URL!
    private let github = GitHub()
    private let runner = Runner()
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

    private func model(answer: [String: Double]) -> QuickCaptureInboxModel {
        let github = github, runner = runner, projects = projects
        let model = QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: [Classifier(answer)]) },
            projects: { projects },
            agents: { [.claude] },
            drafter: {
                QuickCaptureDrafter(
                    runner: runner,
                    openIssues: { await github.openIssues(ofCheckout: $0) },
                    trackedFiles: { _ in [] },
                    directoryExists: { $0.hasPrefix("/w/") }
                )
            },
            github: github,
            now: { Date(timeIntervalSince1970: 1_000_000) }
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

    func testTheIssueURLIsTheLastURLGhPrints() {
        let output = Data("Creating issue in o/reach\n\nhttps://github.com/o/reach/issues/12\n".utf8)
        XCTAssertEqual(QuickCaptureFiling.issueURL(inOutput: output), "https://github.com/o/reach/issues/12")
        XCTAssertEqual(
            QuickCaptureFiling.createArguments(repository: "o/r", title: "T", body: "--help"),
            ["issue", "create", "--repo", "o/r", "--title", "T", "--body", "--help"]
        )
    }
}
