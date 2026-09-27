import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

/// The Mac's half of #745 over a real loopback socket: which hook reply asks
/// for a README or a draft, and which answers land. The host half is
/// `scripts/ci/test-remote-shim-capture.sh`.
final class RemoteQuickCaptureTests: XCTestCase {
    private final class FakeStore: RemoteProjectSummaryStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        let now: @Sendable () -> Date
        init(now: @escaping @Sendable () -> Date) { self.now = now }
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordSummary(_ summary: String?, projectKey: String) {
            let moment = now()
            memory.withLock { _ = $0.recordSummary(summary, projectKey: projectKey, now: moment) }
        }
        let reports = Mutex<[String]>([])
        func recordRemoteReport(project: LearnedTermProjectIdentity, asRepository: Bool) {
            let moment = now()
            reports.withLock { $0.append(project.key) }
            memory.withLock { _ = $0.recordRemoteReport(project: project, asRepository: asRepository, now: moment) }
        }
        /// A project a dictation has shown the app.
        func learn(_ name: String) {
            let moment = now()
            memory.withLock {
                $0.recordProposalFailure(project: LearnedTermProjectIdentity(key: "remote:\(name)", name: name), now: moment)
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 3_000_000))
        func now() -> Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private let clock = Clock()
    private let sleeper = ManualSleeper()
    private var hosts: ClaudeRemoteHostRegistry!
    private var sessions: ClaudeSessionRegistry!
    private var store: FakeStore!
    private var requests: RemoteQuickCaptureRequests!
    private var usage: UsageLedger!
    private var listener: ClaudeRemoteContextListener!
    private var port: UInt16 = 0
    private var token = ""
    private var hostID = ""
    private var otherToken = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let clock = clock
        let sleeper = sleeper
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-remote-capture-hosts.json"),
            io: MemoryRemoteHostStoreIO(),
            now: { clock.now() }
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        token = enrollment.token
        hostID = enrollment.host.id
        otherToken = try hosts.enroll(label: "otherhost").token
        sessions = ClaudeSessionRegistry(now: { clock.now() }, isProcessAlive: { _ in true })
        store = FakeStore(now: { clock.now() })
        store.learn("quill")
        usage = UsageLedger(fileURL: nil)
        requests = RemoteQuickCaptureRequests(
            store: store,
            hosts: hosts,
            registry: sessions,
            now: { clock.now() },
            sleep: { await sleeper.sleep($0) },
            makeID: { "0123456789abcdef0123456789abcdef" },
            usageRecorder: usage
        )
        port = try unusedLoopbackPort()
        listener = ClaudeRemoteContextListener(
            registry: sessions,
            hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port),
            now: { clock.now() },
            quickCapture: requests
        )
        try listener.start()
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    // MARK: Host requests

    private let draftID = "0123456789abcdef0123456789abcdef"

    @discardableResult
    private func hook(
        _ event: String = "UserPromptSubmit",
        session: String,
        agent: ProjectTermProposal.Agent = .claude,
        version: String? = nil,
        project: String = "quill",
        sendsProject: Bool = true,
        token: String? = nil
    ) throws -> RemoteListenerResponse {
        var headers = ["Authorization": "Bearer \(token ?? self.token)", "Content-Type": "application/json"]
        switch agent {
        case .claude:
            headers["X-Lvx-Plugin-Version"] = version ?? RemoteQuickCaptureRequests.minimumPluginVersion
        case .vibe:
            headers["X-Lvx-Agent"] = "vibe"
            headers["X-Lvx-Vibe-Hooks-Version"] = version ?? RemoteQuickCaptureRequests.minimumVibeHooksVersion
        case .opencode:
            preconditionFailure("opencode has no remote shim")
        }
        if sendsProject { headers["X-Lvx-Env-Project"] = project }
        let body = #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/srv/work/\#(project)-fix","prompt":"hello"}"#
        return try postToRemoteListener(port: port, path: "/v1/hook/\(event)", headers: headers, body: Data(body.utf8))
    }

    private func answer(
        _ path: String,
        session: String,
        agent: ProjectTermProposal.Agent = .claude,
        draftID: String? = nil,
        exit: String? = nil,
        usage: String? = nil,
        body: String,
        token: String? = nil
    ) throws -> RemoteListenerResponse {
        var headers = ["Authorization": "Bearer \(token ?? self.token)", "X-Lvx-Capture-Session": session]
        if agent == .vibe { headers["X-Lvx-Agent"] = "vibe" }
        if let usage { headers["X-Lvx-Usage"] = usage }
        if let draftID { headers["X-Lvx-Draft-Id"] = draftID }
        if let exit { headers["X-Lvx-Draft-Exit"] = exit }
        return try postToRemoteListener(port: port, path: path, headers: headers, body: Data(body.utf8))
    }

    private var readmeHeader: String { ClaudeRemoteHTTPCodec.readmeHeaderName.lowercased() }
    private var draftHeader: String { ClaudeRemoteHTTPCodec.draftHeaderName.lowercased() }
    private var quill: QuickCaptureProject {
        QuickCaptureProject(key: "remote:quill", name: "quill", summary: nil, terms: [], userLine: nil)
    }

    private static let readme = """
        # Quill

        [![CI](https://example.com/badge.svg)](https://example.com)

        Quill typesets **Markdown** into print-ready PDFs.

        It runs on the [glyph cache](docs/glyphs.md) and one font directory.
        """

    private static let issues = #"[{"number":12,"title":"Kerning is off in italics","body":"Pairs like Te."},{"number":14,"title":"Page numbers","body":""}]"#

    private static let claudeAnswer = #"""
        {"type":"result","subtype":"success","is_error":false,"num_turns":6,"total_cost_usd":0.07,
         "usage":{"input_tokens":10,"output_tokens":200},
         "structured_output":{"title":"Italic kerning:\nfix Te pairs","body":"Scope: the italic pairs.\u0007","relation":"extends","issue":12}}
        """#

    /// Starts a draft of the idea and returns once it waits for its hook.
    private func startDraft(_ text: String = "for quill, italic kerning is still wrong") async -> Task<QuickCaptureDraft.Outcome, Never> {
        let requests = requests!
        let project = quill
        let task = Task { await requests.draft(capture: text, project: project) }
        await sleeper.waitForSleepers(1)
        return task
    }

    // MARK: README

    func testTheReadmeIsAskedOnceAndItsSummaryIsWhatTheRouterReads() async throws {
        let asked = try hook("SessionStart", session: "s1")
        XCTAssertEqual(asked.headers[readmeHeader], "wanted", "the first hook from the project")
        XCTAssertNil(try hook(session: "s1").headers[readmeHeader], "asked once")

        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.readmePath, session: "s1", body: Self.readme).status, 200)
        let summary = "Quill typesets Markdown into print-ready PDFs. It runs on the glyph cache and one font directory."
        XCTAssertEqual(store.snapshot().projects.first?.summary, summary)
        let projects = QuickCaptureProjects.projects(from: store.snapshot(), userLines: [:], now: clock.now(), readme: { _ in
            XCTFail("a remote project's README is never read on this machine")
            return nil
        })
        XCTAssertEqual(projects.first?.summary, summary)

        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.readmePath, session: "s1", body: "# Other\n\nSomething else.").status, 409,
            "one answer per ask"
        )
        clock.advance(Double(LearnedTerms.summaryRefreshDays) * 86_400)
        XCTAssertEqual(try hook(session: "s1").headers[readmeHeader], "wanted", "asked again after a week")
    }

    func testNoReadmeIsAskedOfAnOldShimOrForACwdLabel() throws {
        try hook("SessionStart", session: "old", version: "1.16.0")
        XCTAssertNil(try hook(session: "old", version: "1.16.0").headers[readmeHeader])
        try hook("SessionStart", session: "v1", agent: .vibe, version: "1.2.0")
        XCTAssertNil(try hook(session: "v1", agent: .vibe, version: "1.2.0").headers[readmeHeader])
        try hook("SessionStart", session: "s2", project: "unseen", sendsProject: false)
        XCTAssertNil(try hook(session: "s2", project: "unseen", sendsProject: false).headers[readmeHeader])
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.readmePath, session: "s2", body: Self.readme).status, 409)
        XCTAssertNil(store.snapshot().projects.first?.summaryAt)
    }

    // MARK: Which projects the hooks name (#819)

    func testAHookThatNamesARepositoryAddsItAndItsReadmeIsAsked() throws {
        let first = try hook("SessionStart", session: "s1", project: "inkwell")
        let inkwell = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:inkwell" })
        XCTAssertEqual(inkwell.reportedAt, clock.now())
        XCTAssertEqual(inkwell.reportedAsRepository, true)
        XCTAssertEqual(first.headers[readmeHeader], "wanted", "the router needs what the new project is about")
        XCTAssertEqual(
            QuickCaptureProjects.projects(from: store.snapshot(), userLines: [:], now: clock.now(), readme: { _ in nil })
                .map(\.key),
            ["remote:inkwell"],
            "quill was only ever learned into, and no hook has named it"
        )
    }

    func testAnOldShimsWorktreeLabelAddsNoProject() throws {
        // Before 1.13.0 a session in `/srv/work/quill-fix` names only its cwd.
        try hook("SessionStart", session: "s1", version: "1.12.0", sendsProject: false)
        XCTAssertEqual(store.snapshot().projects.map(\.key), ["remote:quill"])
        XCTAssertNil(store.snapshot().projects.first?.reportedAt)
    }

    /// #891: a cwd label's hook before the dictation that adds its project
    /// stamps nothing, so it must not use up the interval.
    func testTheFirstHookAfterADictationAddsTheProjectStampsIt() throws {
        // A session in `/srv/work/ink-fix` names only its cwd.
        try hook("SessionStart", session: "s1", version: "1.12.0", project: "ink", sendsProject: false)
        store.learn("ink-fix")
        try hook(session: "s1", version: "1.12.0", project: "ink", sendsProject: false)
        let project = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:ink-fix" })
        XCTAssertEqual(project.reportedAt, clock.now())
        XCTAssertNil(project.reportedAsRepository)
    }

    func testAProjectIsRecordedOncePerInterval() throws {
        try hook("SessionStart", session: "s1", project: "inkwell")
        try hook(session: "s1", project: "inkwell")
        XCTAssertEqual(store.reports.withLock { $0 }, ["remote:inkwell"])
        clock.advance(RemoteQuickCaptureRequests.reportInterval)
        try hook(session: "s1", project: "inkwell")
        XCTAssertEqual(store.reports.withLock { $0 }, ["remote:inkwell", "remote:inkwell"])
    }

    func testAnEmptyReadmeIsRecordedSoTheHostIsNotAskedAgainThisWeek() throws {
        XCTAssertEqual(try hook("SessionStart", session: "v1", agent: .vibe).headers[readmeHeader], "wanted")
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.readmePath, session: "v1", agent: .vibe, body: "").status, 200)
        XCTAssertNil(store.snapshot().projects.first?.summary)
        XCTAssertNotNil(store.snapshot().projects.first?.summaryAt)
        clock.advance(Double(RemoteQuickCaptureRequests.readmeAskInterval))
        XCTAssertNil(try hook(session: "v1", agent: .vibe).headers[readmeHeader])
    }

    // MARK: Draft

    func testADraftGoesToTheRoutedProjectsNextHookAndItsAnswerLands() async throws {
        try hook("SessionStart", session: "other", project: "inkwell")
        try hook("SessionStart", session: "s1")
        let task = await startDraft()

        XCTAssertNil(try hook(session: "other", project: "inkwell").headers[draftHeader], "another project")
        XCTAssertEqual(try hook(session: "s1").headers[draftHeader], draftID)
        XCTAssertNil(try hook(session: "s1").headers[draftHeader], "asked once")

        let prompt = try answer(
            RemoteQuickCaptureRequests.draftPromptPath, session: "s1", draftID: draftID, body: Self.issues
        )
        XCTAssertEqual(prompt.status, 200)
        XCTAssertEqual(
            String(decoding: prompt.body, as: UTF8.self),
            QuickCaptureDraft.prompt(
                capture: "for quill, italic kerning is still wrong",
                projectName: "quill",
                issues: [
                    .init(number: 12, title: "Kerning is off in italics", body: "Pairs like Te."),
                    .init(number: 14, title: "Page numbers", body: ""),
                ]
            )
        )

        let posted = try answer(
            RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: "0", body: Self.claudeAnswer
        )
        XCTAssertEqual(posted.status, 200)
        let outcome = await task.value
        guard case .draft(let draft, let usage) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(draft.title, "Italic kerning: fix Te pairs", "one line")
        XCTAssertEqual(draft.body, "Scope: the italic pairs.", "no control characters")
        XCTAssertEqual(draft.relation, .extends)
        XCTAssertEqual(draft.issue, 12)
        XCTAssertEqual(usage?.turns, 6)
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: "0", body: Self.claudeAnswer).status,
            409, "one answer per draft"
        )
        XCTAssertEqual(
            self.usage.entries(),
            [UsageEntry(
                date: clock.now(), feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet",
                promptTokens: 10, completionTokens: 200, agentCostUSD: 0.07)],
            "the host's run, counted once with what it reported"
        )
    }

    func testTheCaptureReachesOnlyTheSessionTheAskWentTo() async throws {
        try hook("SessionStart", session: "s1")
        try hook("SessionStart", session: "s2")
        try hook("SessionStart", session: "s1", token: otherToken)
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "s1").headers[draftHeader], draftID)

        func prompt(_ session: String, agent: ProjectTermProposal.Agent = .claude, id: String? = nil, token: String? = nil) throws -> Int {
            try answer(
                RemoteQuickCaptureRequests.draftPromptPath, session: session, agent: agent,
                draftID: id ?? draftID, body: "", token: token
            ).status
        }
        XCTAssertEqual(try prompt("s2"), 409, "another session of the project")
        XCTAssertEqual(try prompt("s1", token: otherToken), 409, "the same session id on another host")
        XCTAssertEqual(try prompt("s1", agent: .vibe), 409, "another agent")
        XCTAssertEqual(try prompt("s1", id: "ffffffffffffffffffffffffffffffff"), 409, "another draft")
        XCTAssertEqual(try prompt("s1", id: "not-an-id"), 400)
        XCTAssertEqual(try prompt("s1"), 200)
        XCTAssertEqual(try prompt("s1"), 409, "the prompt goes out once")
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s2", draftID: draftID, exit: "0", body: Self.claudeAnswer).status,
            409
        )

        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: "timeout", body: "").status, 200)
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed(.timedOut))
    }

    func testAnAnswerBeforeThePromptOrWithAnUnknownExitIsRefused() async throws {
        try hook("SessionStart", session: "s1")
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "s1").headers[draftHeader], draftID)
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: "0", body: Self.claudeAnswer).status,
            409, "no prompt was fetched"
        )
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.draftPromptPath, session: "s1", draftID: draftID, body: "not json").status, 200)
        for exit in [nil, "-1", "256", "1e3", "killed"] {
            XCTAssertEqual(
                try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: exit, body: Self.claudeAnswer).status,
                409, exit ?? "no exit"
            )
        }
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "s1", draftID: draftID, exit: "0", body: Self.claudeAnswer).status,
            200
        )
        guard case .draft(let draft, _) = await task.value else { return XCTFail() }
        XCTAssertEqual(draft.relation, .none, "the host's gh listed nothing, so no issue can be named")
        XCTAssertNil(draft.issue)
    }

    func testAVibeSessionsTextAnswerAndItsFailuresMapAsLocalOnesDo() async throws {
        try hook("SessionStart", session: "v1", agent: .vibe)
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "v1", agent: .vibe).headers[draftHeader], draftID)
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.draftPromptPath, session: "v1", agent: .vibe, draftID: draftID, body: Self.issues).status, 200)
        let text = #"Here it is: {"title":"Page numbers in the footer","body":"Scope: footer.","relation":"duplicate","issue":14}"#
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftAnswerPath, session: "v1", agent: .vibe, draftID: draftID, exit: "0", body: text).status,
            200
        )
        guard case .draft(let draft, let usage) = await task.value else { return XCTFail() }
        XCTAssertEqual(draft.relation, .duplicate)
        XCTAssertEqual(draft.issue, 14)
        XCTAssertNil(usage)

        XCTAssertEqual(RemoteQuickCaptureRequests.outcome(exit: "capped", output: Data(), agent: .vibe, openIssues: []), .failed(.outputTooLarge))
        XCTAssertEqual(RemoteQuickCaptureRequests.outcome(exit: "missing", output: Data(), agent: .claude, openIssues: []), .failed(.agentNotFound))
        XCTAssertEqual(RemoteQuickCaptureRequests.outcome(exit: "3", output: Data(), agent: .vibe, openIssues: []), .failed(.exit(3)))
        XCTAssertEqual(
            RemoteQuickCaptureRequests.outcome(
                exit: "1", output: Data(#"{"is_error":true,"subtype":"error_max_budget_usd"}"#.utf8), agent: .claude, openIssues: []
            ),
            .failed(.budgetExceeded)
        )
    }

    func testAVibeDraftRecordsTheCountsItsHostSent() async throws {
        try hook("SessionStart", session: "v1", agent: .vibe)
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "v1", agent: .vibe).headers[draftHeader], draftID)
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.draftPromptPath, session: "v1", agent: .vibe, draftID: draftID, body: Self.issues).status, 200)
        let text = #"{"title":"Page numbers in the footer","body":"Scope: footer.","relation":"none","issue":null}"#
        XCTAssertEqual(
            try answer(
                RemoteQuickCaptureRequests.draftAnswerPath, session: "v1", agent: .vibe, draftID: draftID, exit: "0",
                usage: "13626 10944 16", body: text
            ).status,
            200
        )
        guard case .draft(_, let usage) = await task.value else { return XCTFail() }
        XCTAssertEqual(usage, AgentUsageFixtures.vibeUsage)
        XCTAssertEqual(
            self.usage.entries(),
            [.agentRun(date: clock.now(), feature: .quickCaptureDrafting, agent: .vibe, usage: AgentUsageFixtures.vibeUsage)]
        )
    }

    /// The shipped runner drafts with a fake `vibe` against this listener
    /// and sends the counts the run left in its session log.
    func testTheShippedRunnerSendsAVibeDraftsCounts() async throws {
        let text = #"{"title":"Page numbers in the footer","body":"Scope: footer.","relation":"none","issue":null}"#
        let host = try AgentUsageFixtures.Host(agents: ["vibe": AgentUsageFixtures.fakeVibe(printing: text)], testCase: self)
        let lock = host.home.appendingPathComponent("state/capture/draft-running", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try hook("SessionStart", session: "v1", agent: .vibe)
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "v1", agent: .vibe).headers[draftHeader], draftID)

        let arguments = ["draft", "vibe", "\(port)", "v1", host.project.path, draftID, lock.path, host.userVibe.path]
        let token = token
        try await Task.detached { try host.run("capture.sh", arguments, token: token) }.value
        // The runner has exited, so its answer was either taken already or
        // never sent; end a draft still waiting rather than wait forever.
        if usage.entries().isEmpty {
            sleeper.wakeAll()
            await sleeper.waitForSleepers(1)
            sleeper.wakeAll()
            _ = await task.value
            return XCTFail("the runner posted no draft")
        }

        guard case .draft(let draft, let usage) = await task.value else { return XCTFail() }
        XCTAssertEqual(draft.title, "Page numbers in the footer")
        XCTAssertEqual(usage, AgentUsageFixtures.vibeUsage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), "the runner releases the draft lock")
    }

    // MARK: Nothing to ask, or nobody answers

    func testWithNoLiveSessionOrOnlyAnOldShimNothingWaits() async throws {
        let none = await requests.draft(capture: "idea", project: quill)
        XCTAssertEqual(none, .notRun(.noHostSession))

        try hook("SessionStart", session: "old", version: "1.16.0")
        let old = await requests.draft(capture: "idea", project: quill)
        XCTAssertEqual(old, .notRun(.hostNeedsUpdate))

        try hosts.revoke(hostID: hostID)
        let revoked = await requests.draft(capture: "idea", project: quill)
        XCTAssertEqual(revoked, .notRun(.noHostSession))
    }

    func testADraftNoHookPicksUpEndsAndOneThatIsNeverAnsweredTimesOut() async throws {
        try hook("SessionStart", session: "s1")
        let quiet = await startDraft()
        sleeper.wakeAll()
        let quietOutcome = await quiet.value
        XCTAssertEqual(quietOutcome, .notRun(.noHostSession))
        XCTAssertNil(try hook(session: "s1").headers[draftHeader], "an ended draft is never asked")

        let silent = await startDraft()
        XCTAssertEqual(try hook(session: "s1").headers[draftHeader], draftID)
        sleeper.wakeAll()
        await sleeper.waitForSleepers(1)
        sleeper.wakeAll()
        let silentOutcome = await silent.value
        XCTAssertEqual(silentOutcome, .failed(.timedOut))
        XCTAssertEqual(try answer(RemoteQuickCaptureRequests.draftPromptPath, session: "s1", draftID: draftID, body: "").status, 409)
        XCTAssertTrue(usage.entries().isEmpty, "no host fetched a prompt, so no agent ran")
    }

    func testAPromptedDraftThatNeverAnswersIsCountedAsARunWithoutUsage() async throws {
        try hook("SessionStart", session: "s1")
        let task = await startDraft()
        XCTAssertEqual(try hook(session: "s1").headers[draftHeader], draftID)
        XCTAssertEqual(
            try answer(RemoteQuickCaptureRequests.draftPromptPath, session: "s1", draftID: draftID, body: Self.issues).status,
            200
        )
        sleeper.wakeAll()
        await sleeper.waitForSleepers(1)
        sleeper.wakeAll()

        let outcome = await task.value
        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertEqual(
            usage.entries(),
            [UsageEntry(date: clock.now(), feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet")]
        )
    }

    func testTheDrafterHandsOnlyARemoteProjectToTheHost() async {
        let handed = Mutex<[String]>([])
        let drafter = QuickCaptureDrafter(
            runner: RefusingRunner(),
            openIssues: { _ in XCTFail("the Mac lists no issues for a remote project"); return nil },
            remote: { capture, project in
                handed.withLock { $0.append("\(project.key): \(capture)") }
                return .notRun(.noHostSession)
            }
        )
        let outcome = await drafter.draft(
            capture: "idea", route: .project("remote:quill"), projects: [quill], agents: [.claude, .vibe]
        )
        XCTAssertEqual(outcome, .notRun(.noHostSession))
        XCTAssertEqual(handed.withLock { $0 }, ["remote:quill: idea"])
        let catchAll = await drafter.draft(capture: "idea", route: .catchAll, projects: [quill], agents: [.claude])
        XCTAssertEqual(catchAll, .notRun(.catchAll))
        XCTAssertEqual(handed.withLock { $0 }.count, 1)
    }

    private struct RefusingRunner: QuickCaptureDraftRunning {
        func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
            XCTFail("a remote project's draft never runs an agent on this machine")
            return .failed(.launchFailed)
        }
    }

    // MARK: Contract with the shipped files

    func testTheShimsReadTheAsksAndTheRunnerMatchesTheLocalDraft() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let claudeShim = try text("integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh")
        let vibeShim = try text("integrations/vibe/remote/post.sh")
        let runner = try text("integrations/claude-code/plugins/localvoxtral-remote/hooks/capture.sh")

        XCTAssertFalse(ClaudeRemotePluginVersionCodec.isVersion(
            ClaudeRemoteEnrollmentService.remotePluginVersion, olderThan: RemoteQuickCaptureRequests.minimumPluginVersion
        ))
        XCTAssertTrue(claudeShim.contains("X-Lvx-Plugin-Version: \(ClaudeRemoteEnrollmentService.remotePluginVersion)"))
        let vibeVersion = try XCTUnwrap(VibeRemoteHooksFiles(
            postScript: vibeShim, compactScript: "", hooksBlock: "", termsScript: "", captureScript: ""
        ).version)
        XCTAssertFalse(ClaudeRemotePluginVersionCodec.isVersion(
            vibeVersion, olderThan: RemoteQuickCaptureRequests.minimumVibeHooksVersion
        ))
        for shim in [claudeShim, vibeShim] {
            XCTAssertTrue(shim.contains("/^[Xx]-[Ll][Vv][Xx]-[Rr][Ee][Aa][Dd][Mm][Ee]: \(ClaudeRemoteHTTPCodec.readmeHeaderValue)$/"))
            XCTAssertTrue(shim.contains(#"s/^[Xx]-[Ll][Vv][Xx]-[Dd][Rr][Aa][Ff][Tt]: \([0123456789abcdef]\{32\}\)$/draft \1/p"#))
            XCTAssertTrue(shim.contains("lvx_capture_start draft"))
        }

        for header in [
            RemoteQuickCaptureRequests.sessionHeaderName, RemoteQuickCaptureRequests.draftIDHeaderName,
            RemoteQuickCaptureRequests.draftExitHeaderName,
        ] {
            XCTAssertTrue(runner.contains("\(header): $"), header)
        }
        for path in [
            RemoteQuickCaptureRequests.readmePath, RemoteQuickCaptureRequests.draftPromptPath,
            RemoteQuickCaptureRequests.draftAnswerPath,
        ] {
            XCTAssertTrue(runner.contains("post \(path) "), path)
        }
        XCTAssertTrue(runner.contains("head -c \(RemoteQuickCaptureRequests.maxReadmeBytes) "))
        XCTAssertTrue(runner.contains("head -c \(RemoteQuickCaptureRequests.maxIssueListBytes) "))
        XCTAssertTrue(runner.contains("-le \(RemoteQuickCaptureRequests.maxDraftAnswerBytes) "))
        XCTAssertTrue(runner.contains("--limit \(QuickCaptureDraft.maxListedIssues) "))
        XCTAssertTrue(runner.contains("[0:\(QuickCaptureDraft.maxIssueExcerptCharacters)]"))
        XCTAssertTrue(runner.contains("watch \"$RUN\" \(Int(QuickCaptureDraft.timeoutSeconds))"))

        // The Mac's local run, flag for flag, but for Vibe's output mode.
        XCTAssertTrue(runner.contains("--system-prompt \"\(QuickCaptureDraft.claudeSystemPrompt)\""))
        XCTAssertTrue(runner.contains("--json-schema '\(QuickCaptureDraft.claudeJSONSchema)'"))
        let claude = QuickCaptureDraft.claudeArguments(prompt: "P")
        for (flag, value) in zip(claude, claude.dropFirst()) where flag.hasPrefix("--") && !value.hasPrefix("-") {
            switch flag {
            case "--system-prompt", "--json-schema": continue
            default: XCTAssertTrue(runner.contains("\(flag) \(value) ") || runner.contains("\(flag) '\(value)' "), flag)
            }
        }
        let flags = claude.filter { $0.hasPrefix("--") }
        XCTAssertEqual(
            flags,
            runner.components(separatedBy: "\n")
                .drop { !$0.contains("\"$BIN\" -p \"$(cat \"$WORK/prompt\")\"") }
                .prefix { !$0.contains("</dev/null") }
                .compactMap { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) }
                .filter { $0.hasPrefix("--") },
            "no flag added or dropped"
        )
        let vibe = QuickCaptureDraft.vibeArguments(prompt: "P", trackedFiles: [])
        for (flag, value) in zip(vibe, vibe.dropFirst()) where flag.hasPrefix("--") && !value.hasPrefix("-") {
            switch flag {
            case "--output": XCTAssertTrue(runner.contains("--output text"))
            default: XCTAssertTrue(runner.contains("\(flag) \(value) ") || runner.contains("\(flag) '\(value)' "), flag)
            }
        }
        for flag in vibe where flag.hasPrefix("--") {
            XCTAssertTrue(runner.contains(flag), flag)
        }
    }
}
