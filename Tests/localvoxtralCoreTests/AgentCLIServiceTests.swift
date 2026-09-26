import ClaudeContextWire
import Foundation
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// Each `localvoxtral` command's answer against a fixture store (#721). The
/// JSON is what agents read, so each command pins it whole once.
final class AgentCLIServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let quill = AgentCLIProject(key: "/work/quillmark", name: "quillmark")
    private let other = AgentCLIProject(key: "/work/other", name: "other")

    private func dictation(
        _ id: String,
        minutesAgo: Double,
        raw: String,
        final: String? = nil,
        project: AgentCLIProject?,
        inserted: Bool = true
    ) -> AgentCLIDictation {
        AgentCLIDictation(
            id: id,
            startedAt: now.addingTimeInterval(-minutesAgo * 60),
            finishedAt: now.addingTimeInterval(-minutesAgo * 60 + 5),
            project: project,
            agent: project == nil ? nil : "claude",
            targetApp: "com.mitchellh.ghostty",
            rawText: raw,
            finalText: final ?? raw,
            inserted: inserted,
            status: inserted ? "completed" : "stt_completed"
        )
    }

    private func fixture() -> FixtureAgentCLIDataSource {
        var state = FixtureAgentCLIDataSource.State()
        state.now = now
        state.dictations = [
            dictation("a", minutesAgo: 60 * 30, raw: "the mac queue is stuck again", project: quill),
            dictation("b", minutesAgo: 60, raw: "move the Mac Queue doc", final: "Move the Mac queue doc.", project: other),
            dictation("c", minutesAgo: 5, raw: "rename the queue struct", project: quill),
            dictation("d", minutesAgo: 1, raw: "hello there", project: nil),
        ]
        state.last = dictation("e", minutesAgo: 0, raw: "never reached the app", project: quill, inserted: false)
        state.userTerms = ["Voxtral"]
        state.refusedTerms = ["Quilt"]
        return FixtureAgentCLIDataSource(state)
    }

    /// Paths resolve by table, not on disk; the on-disk resolver has its own
    /// test below.
    private func service(_ source: FixtureAgentCLIDataSource) -> AgentCLIService {
        AgentCLIService(source: source) { path in
            switch path {
            case "/work/quillmark", "/work/quillmark/Sources", "/work/quillmark/.claude/worktrees/x":
                LearnedTermProjectIdentity(key: "/work/quillmark", name: "quillmark")
            case "/work/other": LearnedTermProjectIdentity(key: "/work/other", name: "other")
            default: nil
            }
        }
    }

    private func json(_ response: AgentCLIResponse) throws -> String {
        let line = try XCTUnwrap(AgentCLIWire.encodeLine(response))
        return try XCTUnwrap(String(data: line, encoding: .utf8)).trimmingCharacters(in: .newlines)
    }

    // MARK: history search

    func testHistorySearchAnswersNewestFirstIgnoringCase() async throws {
        let response = await service(fixture()).respond(to: AgentCLIRequest(command: .historySearch, text: "mac queue"))
        XCTAssertEqual(response.history?.dictations.map(\.id), ["b", "a"])
        XCTAssertEqual(
            try json(AgentCLIResponse(history: AgentCLIHistory(
                historyKept: true, dictations: Array(response.history!.dictations.prefix(1))))),
            #"{"cli":1,"history":{"dictations":[{"agent":"claude","finalText":"Move the Mac queue doc.","finishedAt":"2026-09-21T13:13:25Z","id":"b","inserted":true,"project":{"key":"\/work\/other","name":"other"},"rawText":"move the Mac Queue doc","startedAt":"2026-09-21T13:13:20Z","status":"completed","targetApp":"com.mitchellh.ghostty"}],"historyKept":true},"ok":true}"#
        )
    }

    func testHistorySearchFiltersByProjectPathSinceAndLimit() async throws {
        let service = service(fixture())
        // A worktree of the repository is the same project.
        var request = AgentCLIRequest(command: .historySearch, text: "", project: "/work/quillmark/.claude/worktrees/x")
        var response = await service.respond(to: request)
        XCTAssertEqual(response.history?.dictations.map(\.id), ["c", "a"])

        request.since = now.addingTimeInterval(-3_600 * 24)
        response = await service.respond(to: request)
        XCTAssertEqual(response.history?.dictations.map(\.id), ["c"])

        request = AgentCLIRequest(command: .historySearch, text: "", limit: 2)
        response = await service.respond(to: request)
        XCTAssertEqual(response.history?.dictations.map(\.id), ["d", "c"])
    }

    func testHistorySearchFiltersByProjectName() async {
        let response = await service(fixture()).respond(
            to: AgentCLIRequest(command: .historySearch, text: "queue", project: "QuillMark"))
        XCTAssertEqual(response.history?.dictations.map(\.id), ["c", "a"])
    }

    func testHistorySearchRefusesAMissingDirectoryAndABadLimit() async {
        let service = service(fixture())
        var response = await service.respond(
            to: AgentCLIRequest(command: .historySearch, text: "x", project: "/nowhere"))
        XCTAssertEqual(response.error?.code, .unknownProject)
        XCTAssertFalse(response.ok)
        response = await service.respond(to: AgentCLIRequest(command: .historySearch, text: "x", limit: 0))
        XCTAssertEqual(response.error?.code, .badRequest)
    }

    // MARK: history last

    func testHistoryLastIncludesADictationThatWasNeverInserted() async throws {
        let response = await service(fixture()).respond(to: AgentCLIRequest(command: .historyLast))
        XCTAssertEqual(
            try json(response),
            #"{"cli":1,"history":{"dictations":[{"agent":"claude","finalText":"never reached the app","finishedAt":"2026-09-21T14:13:25Z","id":"e","inserted":false,"project":{"key":"\/work\/quillmark","name":"quillmark"},"rawText":"never reached the app","startedAt":"2026-09-21T14:13:20Z","status":"stt_completed","targetApp":"com.mitchellh.ghostty"}],"historyKept":true},"ok":true}"#
        )
    }

    // MARK: Don't keep

    func testUnderDontKeepHistoryAnswersNothingAndIsNotAnError() async throws {
        let source = fixture()
        source.state.withLock { $0.historyKept = false }
        let service = service(source)
        for request in [
            AgentCLIRequest(command: .historySearch, text: "queue"),
            AgentCLIRequest(command: .historySearch, text: "queue", project: "/nowhere"),
            AgentCLIRequest(command: .historyLast),
        ] {
            let response = await service.respond(to: request)
            XCTAssertEqual(try json(response), #"{"cli":1,"history":{"dictations":[],"historyKept":false},"ok":true}"#)
        }
    }

    // MARK: terms list

    private func learned() -> LearnedTerms {
        var memory = LearnedTerms()
        let quill = LearnedTermProjectIdentity(key: "/work/quillmark", name: "quillmark")
        memory.record(
            [LearnedTermObservation(term: "Inkwell", source: .terminal)], project: quill, now: now)
        for _ in 0..<3 {
            memory.record([LearnedTermObservation(term: "QuillDoc", source: .terminal)], project: quill, now: now)
        }
        memory.recordCorrection("Pinnacle", project: quill, now: now)
        memory.setPinned(true, term: "Pinnacle", projectKey: quill.key)
        memory.recordCommandProposal(["qmk"], proposer: "codex", project: quill, now: now)
        memory.record(
            [LearnedTermObservation(term: "Elsewhere", source: .terminal)],
            project: LearnedTermProjectIdentity(key: "/work/other", name: "other"),
            now: now.addingTimeInterval(-60))
        return memory
    }

    func testTermsListNamesEachTermsState() async throws {
        let source = fixture()
        source.state.withLock { $0.learned = learned() }
        let response = await service(source).respond(
            to: AgentCLIRequest(command: .termsList, project: "/work/quillmark/Sources"))
        XCTAssertEqual(
            try json(response),
            #"{"cli":1,"ok":true,"terms":{"projects":[{"project":{"key":"\/work\/quillmark","name":"quillmark"},"terms":[{"dictations":1,"lastSeen":"2026-09-21T14:13:20Z","state":"pinned","term":"Pinnacle"},{"dictations":3,"lastSeen":"2026-09-21T14:13:20Z","state":"confirmed","term":"QuillDoc"},{"dictations":1,"lastSeen":"2026-09-21T14:13:20Z","state":"learning","term":"Inkwell"},{"dictations":0,"lastSeen":"2026-09-21T14:13:20Z","proposedBy":"codex","state":"proposed","term":"qmk"}]}],"userTerms":["Voxtral"]}}"#
        )
    }

    func testTermsListWithoutAProjectListsEveryProjectMostRecentFirst() async {
        let source = fixture()
        source.state.withLock { $0.learned = learned() }
        let response = await service(source).respond(to: AgentCLIRequest(command: .termsList))
        XCTAssertEqual(response.terms?.projects.map(\.project.name), ["quillmark", "other"])
    }

    // MARK: terms propose

    func testProposedTermsLandUnconfirmedUnderTheCallerAndSayWhatWasSkipped() async throws {
        let source = fixture()
        source.state.withLock { $0.learned = learned() }
        let response = await service(source).respond(to: AgentCLIRequest(
            command: .termsPropose,
            project: "/work/quillmark/.claude/worktrees/x",
            terms: ["Featherline", "QuillDoc", "voxtral", "quilt", "a whole sentence that is far too long to be a term at all", "featherline"],
            caller: .claude
        ))
        XCTAssertEqual(
            try json(response),
            #"{"cli":1,"ok":true,"proposal":{"added":["Featherline"],"project":{"key":"\/work\/quillmark","name":"quillmark"},"skipped":[{"reason":"known","term":"QuillDoc"},{"reason":"userList","term":"voxtral"},{"reason":"userList","term":"quilt"},{"reason":"notTermShaped","term":"a whole sentence that is far too long to be a term at all"},{"reason":"known","term":"featherline"}]}}"#
        )
        let memory = source.state.withLock { $0.learned }
        let project = try XCTUnwrap(memory.projects.first { $0.key == "/work/quillmark" })
        let featherline = try XCTUnwrap(project.terms.first { $0.term == "Featherline" })
        XCTAssertEqual(featherline.sources, ["agent:claude"])
        XCTAssertEqual(featherline.dictations, 0)
        XCTAssertTrue(featherline.isUnconfirmedProposal)
        XCTAssertEqual(featherline.proposerDisplayName, "Claude Code")
        // A command proposal is not the project's answer: the headless run
        // still asks once.
        XCTAssertTrue(memory.needsProposal(projectKey: "/work/quillmark", now: now))
    }

    func testAProposalTakesAKnownProjectByNameAndRefusesAnUnknownOne() async {
        let source = fixture()
        source.state.withLock { $0.learned = learned() }
        let service = service(source)
        var response = await service.respond(
            to: AgentCLIRequest(command: .termsPropose, project: "Other", terms: ["Lantern"], caller: .opencode))
        XCTAssertEqual(response.proposal?.added, ["Lantern"])
        XCTAssertEqual(response.proposal?.project.key, "/work/other")

        response = await service.respond(
            to: AgentCLIRequest(command: .termsPropose, project: "unheard-of", terms: ["Lantern"]))
        XCTAssertEqual(response.error?.code, .unknownProject)
        response = await service.respond(
            to: AgentCLIRequest(command: .termsPropose, project: "/nowhere", terms: ["Lantern"]))
        XCTAssertEqual(response.error?.code, .unknownProject)
        response = await service.respond(to: AgentCLIRequest(command: .termsPropose, project: "/work/other"))
        XCTAssertEqual(response.error?.code, .badRequest)
    }

    func testAProposalPastTheCapSkipsTheRest() async {
        let terms = (0..<(AgentCLIWire.maxProposedTerms + 2)).map { "Term\($0)" }
        let response = await service(fixture()).respond(
            to: AgentCLIRequest(command: .termsPropose, project: "/work/other", terms: terms, caller: .vibe))
        XCTAssertEqual(response.proposal?.added.count, AgentCLIWire.maxProposedTerms)
        XCTAssertEqual(response.proposal?.skipped.map(\.reason), [.overLimit, .overLimit])
    }

    // MARK: status

    func testStatusReportsEnginesAndTheLastJoin() async throws {
        let source = fixture()
        source.state.withLock {
            $0.status = AgentCLIStatus(
                running: true,
                version: "1.4.0",
                dictating: false,
                historyKept: true,
                dictation: AgentCLIEngine(backend: "managed_local", model: "voxtral-mini", enabled: true),
                polish: AgentCLIEngine(backend: "mistral_api", model: "mistral-small", enabled: true),
                lastJoin: AgentCLIJoin(agent: "claude", project: quill, mechanism: "tty", remote: false)
            )
        }
        let response = await service(source).respond(to: AgentCLIRequest(command: .status))
        XCTAssertEqual(
            try json(response),
            #"{"cli":1,"ok":true,"status":{"dictating":false,"dictation":{"backend":"managed_local","enabled":true,"model":"voxtral-mini"},"historyKept":true,"lastJoin":{"agent":"claude","mechanism":"tty","project":{"key":"\/work\/quillmark","name":"quillmark"},"remote":false},"polish":{"backend":"mistral_api","enabled":true,"model":"mistral-small"},"running":true,"version":"1.4.0"}}"#
        )
    }

    // MARK: Requests

    func testAnUnknownCommandIsAnAnswerNotADroppedLine() async throws {
        var request = AgentCLIRequest(command: .status)
        request.command = "history.delete"
        let response = await service(fixture()).respond(to: request)
        XCTAssertEqual(response.error?.code, .unknownCommand)
    }

    func testTheWireTellsARequestFromAHookRecord() throws {
        let request = try XCTUnwrap(AgentCLIWire.encodeLine(AgentCLIRequest(command: .status)))
        XCTAssertTrue(AgentCLIWire.isRequest(request))
        XCTAssertFalse(AgentCLIWire.isRequest(Data(#"{"v":2,"event":"SessionStart"}"#.utf8)))
        XCTAssertFalse(AgentCLIWire.isRequest(Data("not json".utf8)))
        XCTAssertThrowsError(try AgentCLIWire.decodeRequest(Data(#"{"cli":99,"command":"status"}"#.utf8))) {
            XCTAssertEqual(($0 as? AgentCLIError)?.code, .unsupportedVersion)
        }
    }

    // MARK: On disk

    /// A worktree's `.git` file points into the main checkout's git
    /// directory, whose `commondir` names the shared one: both resolve to the
    /// main checkout, so `--project` in either reaches one project.
    func testAWorktreeAndItsMainCheckoutResolveToOneProjectOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-cli-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("quillmark")
        let worktreeGit = main.appendingPathComponent(".git/worktrees/x")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: worktreeGit.appendingPathComponent("commondir"))
        let worktree = root.appendingPathComponent("elsewhere/x")
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("gitdir: \(worktreeGit.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))

        let fromWorktree = AgentCLIService.resolveOnDisk(worktree.appendingPathComponent("Sources").path)
        XCTAssertEqual(fromWorktree?.key, main.path)
        XCTAssertEqual(fromWorktree?.name, "quillmark")
        XCTAssertEqual(AgentCLIService.resolveOnDisk(main.path)?.key, main.path)
        XCTAssertNil(AgentCLIService.resolveOnDisk(root.appendingPathComponent("missing").path))
    }
}
