import ClaudeContextWire
import Foundation
@testable import LocalvoxtralCLICore
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// `localvoxtral capture list | show | filed` (#923): an agent told "look at
/// the capture about X" finds it by title, files the issue with its own gh,
/// then records the URL.
final class AgentCLICaptureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let herdrID = UUID(uuidString: "3F9C2A1B-0000-4000-8000-000000000001")!
    private let progressID = UUID(uuidString: "81D04E77-0000-4000-8000-000000000002")!
    private let undraftedID = UUID(uuidString: "3F9C2A1B-0000-4000-8000-000000000003")!

    private func item(
        _ id: UUID, hoursAgo: Double, text: String, title: String = "", project: (String, String)?,
        repository: String? = nil, state: QuickCaptureItem.State = .ready, kind: QuickCaptureKind? = nil
    ) -> QuickCaptureItem {
        var item = QuickCaptureItem(id: id, capturedAt: now.addingTimeInterval(-hoursAgo * 3_600), text: text)
        item.state = state
        item.kind = kind
        item.projectKey = project?.0
        item.projectName = project?.1
        item.repository = repository
        item.title = title
        item.body = title.isEmpty ? "" : "## Scope\n\(title)."
        return item
    }

    private func fixture() -> FixtureAgentCLIDataSource {
        var state = FixtureAgentCLIDataSource.State()
        state.now = now
        state.inbox = QuickCaptureInbox(items: [
            item(herdrID, hoursAgo: 2, text: "when the herdr pane is busy queue my dictation",
                 title: "Queue dictation into a busy herdr pane", project: ("/work/reach", "reach"), repository: "o/reach"),
            item(progressID, hoursAgo: 30, text: "show drafting progress",
                 title: "Show drafting progress in the Inbox", project: ("remote:website", "website")),
            item(undraftedID, hoursAgo: 0.5,
                 text: "check the vLLM numbers against the Mac tomorrow before the release goes out please",
                 project: nil),
        ])
        return FixtureAgentCLIDataSource(state)
    }

    private func service(_ source: FixtureAgentCLIDataSource) -> AgentCLIService {
        AgentCLIService(source: source) { path in
            path.hasPrefix("/work/reach") ? LearnedTermProjectIdentity(key: "/work/reach", name: "reach") : nil
        }
    }

    private func respond(
        _ command: AgentCLICommand, capture: String? = nil, url: String? = nil, project: String? = nil,
        since: Date? = nil, source: FixtureAgentCLIDataSource
    ) async -> AgentCLIResponse {
        await service(source).respond(
            to: AgentCLIRequest(command: command, project: project, since: since, capture: capture, url: url)
        )
    }

    // MARK: Arguments

    private func parse(_ line: [String]) -> AgentCLIParseResult {
        AgentCLIArguments(now: now, timeZone: TimeZone(identifier: "UTC")!, workingDirectory: "/work/reach/Sources", environment: ["CODEX_THREAD_ID": "t"])
            .parse(line)
    }

    func testCaptureArguments() throws {
        guard case .run(let list) = parse(["capture", "list", "--project", ".", "--since", "3d", "--json"]) else {
            return XCTFail("capture list")
        }
        XCTAssertEqual(list.request.knownCommand, .captureList)
        XCTAssertEqual(list.request.project, "/work/reach/Sources")
        XCTAssertEqual(list.request.since, now.addingTimeInterval(-3 * 86_400))
        XCTAssertTrue(list.json)

        guard case .run(let show) = parse(["capture", "show", "Queue", "dictation"]) else { return XCTFail("show") }
        XCTAssertEqual(show.request.capture, "Queue dictation", "unquoted words are one title")

        guard case .run(let filed) = parse(["capture", "filed", "busy", "herdr", "https://github.com/o/reach/issues/7"])
        else { return XCTFail("filed") }
        XCTAssertEqual(filed.request.capture, "busy herdr")
        XCTAssertEqual(filed.request.url, "https://github.com/o/reach/issues/7")
        XCTAssertEqual(filed.request.caller, .codex)

        XCTAssertEqual(parse(["capture", "show"]), .usageError("capture show needs a capture: its title or id"))
        XCTAssertEqual(
            parse(["capture", "filed", "https://github.com/o/reach/issues/7"]),
            .usageError("capture filed needs a capture and the issue's URL")
        )
        XCTAssertEqual(
            parse(["capture", "filed", "busy", "herdr"]),
            .usageError("capture filed takes the issue's URL last, as gh issue create prints it")
        )
        XCTAssertEqual(parse(["capture", "list", "--limit", "3"]), .usageError("--limit does not apply to capture list"))
        XCTAssertEqual(parse(["capture", "file", "x"]), .usageError("unknown command: capture file"))
    }

    // MARK: List

    func testListIsNewestFirstAndFiltersByProjectAndAge() async throws {
        let source = fixture()
        var captures = await respond(.captureList, source: source).captures?.captures ?? []
        XCTAssertEqual(captures.map(\.id), [undraftedID, herdrID, progressID].map { $0.uuidString.lowercased() })
        XCTAssertEqual(captures.map(\.kind), [nil, "issue", "issue"])
        XCTAssertEqual(captures[0].title, "check the vLLM numbers against the Mac tomorrow before the…",
                       "no draft yet: the first words, cut at a word")
        XCTAssertNil(captures[1].text, "the list carries no dictated words")

        captures = await respond(.captureList, project: "/work/reach/Sources", source: source).captures?.captures ?? []
        XCTAssertEqual(captures.map(\.title), ["Queue dictation into a busy herdr pane"])
        captures = await respond(.captureList, project: "website", source: source).captures?.captures ?? []
        XCTAssertEqual(captures.map(\.title), ["Show drafting progress in the Inbox"])
        captures = await respond(.captureList, since: now.addingTimeInterval(-86_400), source: source).captures?.captures ?? []
        XCTAssertEqual(captures.count, 2)

        source.state.withLock { $0.inbox = nil }
        let noInbox = await respond(.captureList, source: source).captures
        XCTAssertEqual(noInbox, AgentCLICaptures(inboxAvailable: false, captures: []))
    }

    // MARK: Show

    func testShowFindsACaptureByTitleIdOrAUniquePartOfEither() async throws {
        let source = fixture()
        func shown(_ reference: String) async -> String? {
            await respond(.captureShow, capture: reference, source: source).capture?.id
        }
        let cases: [(String, UUID)] = [
            ("queue dictation into a busy HERDR pane", herdrID),
            ("Queue dictation", herdrID),
            ("busy herdr", herdrID),
            (herdrID.uuidString, herdrID),
            ("81d04e77", progressID),
            // A derived title finds it too.
            ("vLLM numbers", undraftedID),
        ]
        for (reference, id) in cases {
            let found = await shown(reference)
            XCTAssertEqual(found, id.uuidString.lowercased(), reference)
        }

        let ambiguous = await respond(.captureShow, capture: "3f9c2a1b", source: source)
        XCTAssertEqual(ambiguous.error?.code, .ambiguousCapture)
        XCTAssertTrue(ambiguous.error?.message.contains("3f9c2a1b Queue dictation into a busy herdr pane") ?? false)
        let unknown = await respond(.captureShow, capture: "dark mode", source: source)
        XCTAssertEqual(unknown.error?.code, .unknownCapture)
    }

    /// What an agent reads before it runs gh issue create.
    func testShowCarriesTheWordsTheDraftAndTheBodyToFile() async throws {
        let response = await respond(.captureShow, capture: "busy herdr", source: fixture())
        let line = try XCTUnwrap(AgentCLIWire.encodeLine(response).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(line, #"""
            {"capture":{"body":"## Scope\nQueue dictation into a busy herdr pane.","capturedAt":"2026-09-21T12:13:20Z","id":"3f9c2a1b-0000-4000-8000-000000000001","issueBody":"## Scope\nQueue dictation into a busy herdr pane.\n\nDictated:\n\n> when the herdr pane is busy queue my dictation","kind":"issue","project":{"key":"\/work\/reach","name":"reach"},"repository":"o\/reach","state":"ready","text":"when the herdr pane is busy queue my dictation","title":"Queue dictation into a busy herdr pane"},"cli":1,"ok":true}

            """#)

        let text = AgentCLIText(timeZone: TimeZone(identifier: "UTC")!, now: now).render(response)
        XCTAssertEqual(text, """
            Queue dictation into a busy herdr pane
            id 3f9c2a1b-0000-4000-8000-000000000001  captured 2026-09-21 12:13  project reach  kind issue  ready
            Repository: o/reach

            ## Scope
            Queue dictation into a busy herdr pane.

            Dictated:

            > when the herdr pane is busy queue my dictation

            """)
    }

    func testListTextIsAnAlignedTable() async {
        let response = await respond(.captureList, source: fixture())
        XCTAssertEqual(AgentCLIText(timeZone: TimeZone(identifier: "UTC")!, now: now).render(response), """
            ID        PROJECT  KIND   AGE  STATE  TITLE
            3f9c2a1b  -        -      30m  ready  check the vLLM numbers against the Mac tomorrow before the…
            3f9c2a1b  reach    issue  2h   ready  Queue dictation into a busy herdr pane
            81d04e77  website  issue  1d   ready  Show drafting progress in the Inbox

            """)
    }

    // MARK: Filed

    func testFiledRecordsTheURLAndRefusesWhatIsNotItsIssue() async throws {
        let source = fixture()
        var response = await respond(.captureFiled, capture: "busy herdr", url: "https://github.com/o/other/issues/4", source: source)
        XCTAssertEqual(response.error, AgentCLIError(.notFileable, "this capture files in o/reach"))

        response = await respond(.captureFiled, capture: "busy herdr", url: "https://github.com/o/reach/issues/4", source: source)
        XCTAssertEqual(response.capture?.state, .filed)
        XCTAssertEqual(response.capture?.filedURL, "https://github.com/o/reach/issues/4")

        response = await respond(.captureFiled, capture: "busy herdr", url: "https://github.com/o/reach/issues/5", source: source)
        XCTAssertEqual(response.error, AgentCLIError(.notFileable, "already filed: https://github.com/o/reach/issues/4"))

        // No repository known: the URL's becomes the capture's.
        response = await respond(.captureFiled, capture: "drafting progress", url: "https://github.com/o/website/issues/2", source: source)
        XCTAssertEqual(response.capture?.repository, "o/website")
    }

    func testAQuestionTaskOrNoteReportsItsKindAndIsNeverMarkedFiled() async throws {
        var state = FixtureAgentCLIDataSource.State()
        state.now = now
        state.inbox = QuickCaptureInbox(items: [
            item(herdrID, hoursAgo: 2, text: "check the vLLM numbers tomorrow", title: "Check the vLLM numbers",
                 project: ("/work/reach", "reach"), repository: "o/reach", kind: .task),
        ])
        let source = FixtureAgentCLIDataSource(state)
        var response = await respond(.captureShow, capture: "vLLM", source: source)
        XCTAssertEqual(response.capture?.kind, "task")
        response = await respond(.captureFiled, capture: "vLLM", url: "https://github.com/o/reach/issues/4", source: source)
        XCTAssertEqual(response.error, AgentCLIError(.notFileable, "a task is never filed"))
    }
}
