import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

/// What a remote host's hooks tell the Mac about its projects (#819, #1027),
/// over a real loopback socket, and what the listener answers a shim of an
/// older release that still calls a removed route.
final class RemoteProjectReportsTests: XCTestCase {
    private final class FakeStore: RemoteProjectReportStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        let now: @Sendable () -> Date
        init(now: @escaping @Sendable () -> Date) { self.now = now }
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        let reports = Mutex<[String]>([])
        func recordRemoteReport(
            project: LearnedTermProjectIdentity, asRepository: Bool, repository: String?, hostID: String?
        ) {
            let moment = now()
            reports.withLock { $0.append(project.key) }
            memory.withLock {
                _ = $0.recordRemoteReport(project: project, asRepository: asRepository, repository: repository, hostID: hostID, now: moment)
            }
        }
        func recordAgentActivity(_ repositories: [AgentWorkedRepository], hostID: String?) {
            let moment = now()
            memory.withLock { memory in
                for repository in repositories {
                    memory.recordAgentActivity(
                        project: repository.project, remote: repository.remote, hostID: hostID,
                        at: repository.lastActive, now: moment
                    )
                }
            }
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
    private var hosts: ClaudeRemoteHostRegistry!
    private var sessions: ClaudeSessionRegistry!
    private var store: FakeStore!
    private var listener: ClaudeRemoteContextListener!
    private var port: UInt16 = 0
    private var token = ""
    private var hostID = ""
    private var otherToken = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let clock = clock
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-remote-reports-hosts.json"),
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
        let reports = RemoteProjectReports(store: store, now: { clock.now() })
        port = try unusedLoopbackPort()
        listener = ClaudeRemoteContextListener(
            registry: sessions,
            hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port),
            now: { clock.now() },
            projectReports: reports
        )
        try listener.start()
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    @discardableResult
    private func hook(
        _ event: String = "UserPromptSubmit",
        session: String,
        version: String? = nil,
        project: String = "quill",
        sendsProject: Bool = true,
        repository: String? = nil,
        cwd: String? = nil,
        agentProjects: String? = nil,
        token: String? = nil
    ) throws -> RemoteListenerResponse {
        var headers = ["Authorization": "Bearer \(token ?? self.token)", "Content-Type": "application/json"]
        headers["X-Lvx-Plugin-Version"] = version ?? "1.45.0"
        if sendsProject { headers["X-Lvx-Env-Project"] = project }
        if let repository { headers["X-Lvx-Env-Repository"] = repository }
        if let agentProjects { headers[AgentProjectsCodec.headerName] = agentProjects }
        let body = #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"\#(cwd ?? "/srv/work/\(project)-fix")","prompt":"hello"}"#
        return try postToRemoteListener(port: port, path: "/v1/hook/\(event)", headers: headers, body: Data(body.utf8))
    }

    // MARK: Which projects the hooks name (#819)

    func testAHookThatNamesARepositoryAddsIt() throws {
        try hook("SessionStart", session: "s1", project: "inkwell")
        let inkwell = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:inkwell" })
        XCTAssertEqual(inkwell.reportedAt, clock.now())
        XCTAssertEqual(inkwell.reportedAsRepository, true)
        XCTAssertEqual(
            ListedProjects.projects(from: store.snapshot(), now: clock.now()).map(\.key),
            ["remote:inkwell"],
            "quill was only ever learned into, and no hook has named it"
        )
    }

    /// #926: the host's origin rides beside the repository's name, and
    /// a later origin replaces it within the report interval.
    func testAHookKeepsItsRepositorysOriginOnTheProject() throws {
        try hook("SessionStart", session: "s1", project: "inkwell", repository: "me/inkwell")
        XCTAssertEqual(store.snapshot().projects.first { $0.key == "remote:inkwell" }?.repository, "me/inkwell")
        try hook(session: "s1", project: "inkwell", repository: "me/inkwell2")
        XCTAssertEqual(store.snapshot().projects.first { $0.key == "remote:inkwell" }?.repository, "me/inkwell2")
        XCTAssertEqual(
            ListedProjects.projects(from: store.snapshot(), now: clock.now()).first { $0.key == "remote:inkwell" }?.repository,
            "me/inkwell2"
        )
    }

    func testAnOldShimsWorktreeLabelAddsNoProject() throws {
        // Before 1.13.0 a session in `/srv/work/quill-fix` names only its cwd.
        try hook("SessionStart", session: "s1", version: "1.12.0", sendsProject: false)
        XCTAssertEqual(store.snapshot().projects.map(\.key), ["remote:quill"])
        XCTAssertNil(store.snapshot().projects.first?.reportedAt)
    }

    /// A Claude Desktop session started before the host's plugin update
    /// keeps its old shim, which names only its worktree. Claude Code's
    /// worktree layout names the repository, so that is the project listed.
    func testAnOldShimInAClaudeCodeWorktreeListsItsRepository() throws {
        try hook(
            "SessionStart", session: "s1", version: "1.11.0", sendsProject: false,
            cwd: "/home/dev/work/localvoxtral/.claude/worktrees/ci-speed-optimizations-7ffef0"
        )
        let project = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:localvoxtral" })
        XCTAssertEqual(project.reportedAsRepository, true)
        XCTAssertFalse(store.snapshot().projects.contains { $0.key == "remote:ci-speed-optimizations-7ffef0" })
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
        clock.advance(RemoteProjectReports.reportInterval)
        try hook(session: "s1", project: "inkwell")
        XCTAssertEqual(store.reports.withLock { $0 }, ["remote:inkwell", "remote:inkwell"])
    }

    /// #939: the Projects pane names each host a repository is checked out
    /// on, so a second host's hook is recorded within the first's interval.
    func testEachHostThatNamesAProjectIsKeptOnIt() throws {
        try hook("SessionStart", session: "s1", project: "inkwell")
        try hook("SessionStart", session: "s2", project: "inkwell", token: otherToken)
        try hook(session: "s2", project: "inkwell", token: otherToken)
        XCTAssertEqual(store.reports.withLock { $0 }, ["remote:inkwell", "remote:inkwell"])
        let hostIDs = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:inkwell" }?.hostIDs)
        XCTAssertEqual(hostIDs.count, 2)
        XCTAssertEqual(hostIDs.first, hostID)
    }

    /// #1027: a repository the host's agents worked in is listed before a
    /// dictation joins a session in it, under the key its hooks name it by,
    /// linked to its origin.
    func testTheReposAHostsAgentsWorkedInAreListed() throws {
        let hourAgo = Int(clock.now().timeIntervalSince1970) - 3600
        let monthsAgo = Int(clock.now().timeIntervalSince1970) - 40 * 86_400
        try hook(
            "SessionStart", session: "s-1",
            agentProjects: "\(hourAgo):vidtheque:T0mSIlver/vidtheque,\(monthsAgo):oldrepo:T0mSIlver/oldrepo,bad entry"
        )
        let learned = store.snapshot()
        let vidtheque = try XCTUnwrap(learned.projects.first { $0.key == "remote:vidtheque" })
        XCTAssertEqual(vidtheque.remote, "github.com/T0mSIlver/vidtheque")
        XCTAssertEqual(vidtheque.hostIDs, [hostID])
        XCTAssertTrue(learned.listedCheckouts(now: clock.now()).contains { $0.key == "remote:vidtheque" })
        XCTAssertFalse(learned.projects.contains { $0.key == "remote:oldrepo" }, "work older than 30 days lists nothing")
        XCTAssertTrue(PolishProjectNames.names(from: learned, now: clock.now()).contains("vidtheque"))
    }

    /// A shim of a release that still asked for a README or a draft, or whose
    /// mod opens the Inbox, calls a route this listener no longer has. The
    /// shims ignore the status, or print "could not list the Inbox"; none
    /// reads a 404 as anything but an app that predates the route, so the
    /// answer is 410 (`scripts/ci/test-remote-shim-removed-routes.sh`).
    func testARouteRemovedWithQuickCaptureAnswers410() throws {
        for path in ClaudeRemoteContextListener.removedPaths.sorted() {
            let response = try postToRemoteListener(
                port: port, path: path,
                headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/octet-stream"],
                body: Data("readme".utf8)
            )
            XCTAssertEqual(response.status, 410, path)
        }
    }

    func testARemovedRouteStillNeedsTheHostsToken() throws {
        let response = try postToRemoteListener(
            port: port, path: "/v1/readme", headers: ["Content-Type": "application/octet-stream"], body: Data()
        )
        XCTAssertEqual(response.status, 401)
    }

    func testAHookReplyNoLongerAsksForAReadmeOrADraft() throws {
        let reply = try hook("SessionStart", session: "s1", project: "inkwell")
        XCTAssertNil(reply.headers["x-lvx-readme"])
        XCTAssertNil(reply.headers["x-lvx-draft"])
    }
}
