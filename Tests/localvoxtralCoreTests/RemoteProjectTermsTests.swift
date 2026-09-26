import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Mac's half of #641 over a real loopback socket: which hook reply
/// carries `X-Lvx-Terms: wanted`, and which `POST /v1/terms` lands in the
/// learned terms. The host half is `scripts/ci/test-remote-shim-terms.sh`.
final class RemoteProjectTermsTests: XCTestCase {
    private final class MemoryHostStore: ClaudeRemoteHostStoreIO, @unchecked Sendable {
        private let contents = Mutex<Data?>(nil)
        func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
        func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
    }

    private final class FakeStore: ProjectTermProposalStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        let now: @Sendable () -> Date
        init(now: @escaping @Sendable () -> Date) { self.now = now }
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordProposal(
            _ terms: [String],
            agent: ProjectTermProposal.Agent,
            project: LearnedTermProjectIdentity,
            excluding: [String]
        ) {
            let moment = now()
            memory.withLock { $0.recordProposal(terms, agent: agent, project: project, excluding: excluding, now: moment) }
        }
        func recordProposalFailure(project: LearnedTermProjectIdentity) {
            let moment = now()
            memory.withLock { $0.recordProposalFailure(project: project, now: moment) }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 3_000_000))
        func now() -> Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private struct Response {
        var status: Int
        var headers: [String: String]
    }

    private let clock = Clock()
    private var hosts: ClaudeRemoteHostRegistry!
    private var sessions: ClaudeSessionRegistry!
    private var store: FakeStore!
    private var requests: RemoteProjectTermRequests!
    private var listener: ClaudeRemoteContextListener!
    private var port: UInt16 = 0
    private var token = ""
    private var hostID = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let clock = clock
        hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-remote-terms-hosts.json"),
            io: MemoryHostStore(),
            now: { clock.now() }
        )
        let enrollment = try hosts.enroll(label: "buildhost")
        token = enrollment.token
        hostID = enrollment.host.id
        sessions = ClaudeSessionRegistry(now: { clock.now() }, isProcessAlive: { _ in true })
        store = FakeStore(now: { clock.now() })
        requests = RemoteProjectTermRequests(store: store, hosts: hosts, now: { clock.now() })
        port = try unusedLoopbackPort()
        listener = ClaudeRemoteContextListener(
            registry: sessions,
            hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: port),
            now: { clock.now() },
            projectTerms: requests
        )
        try listener.start()
    }

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    // MARK: Client

    private func send(path: String, headers: [String: String], body: Data, contentLength: Int? = nil) throws -> Response {
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(contentLength ?? body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let request = Data(head.utf8) + body

        let fd = socket(AF_INET, POSIXSocket.stream, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        POSIXSocket.setLength(of: &address)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
            return offset
        }
        shutdown(fd, Int32(SHUT_WR))
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
        }
        let text = String(decoding: received, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Response(status: status, headers: parsed)
    }

    /// A hook as the host shim sends it: Claude Code's event JSON, the token,
    /// the shim's version and, for Vibe, the agent header.
    @discardableResult
    private func hook(
        _ event: String,
        session: String,
        agent: ProjectTermProposal.Agent = .claude,
        version: String? = nil,
        project: String? = nil,
        token: String? = nil
    ) throws -> Response {
        var headers = ["Authorization": "Bearer \(token ?? self.token)", "Content-Type": "application/json"]
        switch agent {
        case .claude:
            headers["X-Lvx-Plugin-Version"] = version ?? RemoteProjectTermRequests.minimumPluginVersion
        case .vibe:
            headers["X-Lvx-Agent"] = "vibe"
            headers["X-Lvx-Vibe-Hooks-Version"] = version ?? RemoteProjectTermRequests.minimumVibeHooksVersion
        }
        if let project { headers["X-Lvx-Env-Project"] = project }
        let body = #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/srv/work/quill-fix","prompt":"hello"}"#
        return try send(path: "/v1/hook/\(event)", headers: headers, body: Data(body.utf8))
    }

    private func answer(
        session: String,
        agent: ProjectTermProposal.Agent = .claude,
        body: String = #"{"terms":["Quillmark","GlyphAtlasCache","https://example.com"]}"#,
        token: String? = nil,
        contentLength: Int? = nil
    ) throws -> Response {
        var headers = ["Authorization": "Bearer \(token ?? self.token)", "X-Lvx-Terms-Session": session]
        if agent == .vibe { headers["X-Lvx-Agent"] = "vibe" }
        return try send(path: "/v1/terms", headers: headers, body: Data(body.utf8), contentLength: contentLength)
    }

    private func key(_ session: String, agent: ProjectTermProposal.Agent = .claude) -> String {
        (agent == .vibe ? "vibe:" : "") + "remote:\(hostID):\(session)"
    }

    /// The commit path: the dictation joined this session.
    @discardableResult
    private func dictate(into session: String, agent: ProjectTermProposal.Agent = .claude) throws -> Bool {
        let snapshot = try XCTUnwrap(sessions.snapshot(sessionID: key(session, agent: agent)))
        return requests.request(for: snapshot, excluding: ["inkwell"])
    }

    private var wanted: String { ClaudeRemoteHTTPCodec.termsHeaderValue }
    private var termsHeader: String { ClaudeRemoteHTTPCodec.termsHeaderName.lowercased() }

    // MARK: The ask

    func testTheNextHookOfAJoinedSessionIsAskedExactlyOnce() throws {
        try hook("SessionStart", session: "s1")
        XCTAssertNil(try hook("Stop", session: "s1").headers[termsHeader], "nothing asks before a dictation")

        XCTAssertTrue(try dictate(into: "s1"))
        let asked = try hook("UserPromptSubmit", session: "s1")
        XCTAssertEqual(asked.status, 200)
        XCTAssertEqual(asked.headers[termsHeader], wanted)
        XCTAssertEqual(asked.headers["x-lvx-session"], "joined")
        XCTAssertNil(try hook("Stop", session: "s1").headers[termsHeader], "the header goes out once")
        XCTAssertFalse(try dictate(into: "s1"), "the project is stamped: a second dictation asks nothing")
    }

    func testOnlyTheMarkedSessionIsAsked() throws {
        try hook("SessionStart", session: "s1")
        try hook("SessionStart", session: "s2")
        try dictate(into: "s1")
        XCTAssertNil(try hook("UserPromptSubmit", session: "s2").headers[termsHeader])
        XCTAssertEqual(try hook("UserPromptSubmit", session: "s1").headers[termsHeader], wanted)
    }

    func testAHostOnAnOldShimIsNeverAsked() throws {
        try hook("SessionStart", session: "s1", version: "1.14.0")
        XCTAssertFalse(try dictate(into: "s1"))
        XCTAssertNil(try hook("UserPromptSubmit", session: "s1", version: "1.14.0").headers[termsHeader])
        XCTAssertTrue(store.snapshot().needsProposal(projectKey: "remote:quill-fix", now: clock.now()))

        try hook("SessionStart", session: "v1", agent: .vibe, version: "1.1.0")
        XCTAssertFalse(try dictate(into: "v1", agent: .vibe))
    }

    func testAnOldSessionOnAnUpdatedHostKeepsItsMarkUnsent() throws {
        try hook("SessionStart", session: "new")
        try hook("SessionStart", session: "old", version: "1.14.0")
        XCTAssertTrue(try dictate(into: "old"), "the host reported a new shim")
        XCTAssertNil(try hook("Stop", session: "old", version: "1.14.0").headers[termsHeader])
        XCTAssertEqual(try answer(session: "old").status, 409, "an ask that never went out takes no answer")
    }

    func testAMarkExpiresWhenTheSessionStaysQuiet() throws {
        try hook("SessionStart", session: "s1")
        try dictate(into: "s1")
        clock.advance(RemoteProjectTermRequests.markLifetime + 1)
        XCTAssertNil(try hook("UserPromptSubmit", session: "s1").headers[termsHeader])
    }

    func testARevokedHostOrALocalJoinIsNotAsked() throws {
        try hook("SessionStart", session: "s1")
        let snapshot = try XCTUnwrap(sessions.snapshot(sessionID: key("s1")))
        try hosts.revoke(hostID: hostID)
        XCTAssertFalse(requests.request(for: snapshot, excluding: []))
    }

    // MARK: The answer

    func testAnAnswerLandsAsUnconfirmedProposalsUnderTheSessionsProject() throws {
        try hook("SessionStart", session: "s1", project: "quillmark")
        try dictate(into: "s1")
        try hook("UserPromptSubmit", session: "s1", project: "quillmark")

        XCTAssertEqual(try answer(session: "s1").status, 200)
        let memory = store.snapshot()
        let project = try XCTUnwrap(memory.projects.first { $0.key == "remote:quillmark" })
        XCTAssertNotNil(project.proposedAt)
        XCTAssertEqual(project.terms.map(\.term), ["Quillmark", "GlyphAtlasCache"], "a URL is not term-shaped")
        XCTAssertEqual(project.terms.map(\.sources), [["agent:claude"], ["agent:claude"]])
        XCTAssertTrue(project.terms.allSatisfy(\.isUnconfirmedProposal))
        XCTAssertEqual(try answer(session: "s1").status, 409, "one answer per ask")
    }

    func testAVibeSessionsAnswerIsFiledAsVibes() throws {
        try hook("UserPromptSubmit", session: "v1", agent: .vibe)
        XCTAssertTrue(try dictate(into: "v1", agent: .vibe))
        XCTAssertEqual(try hook("Stop", session: "v1", agent: .vibe).headers[termsHeader], wanted)
        XCTAssertEqual(try answer(session: "v1", agent: .claude).status, 409, "the agent must match")
        XCTAssertEqual(try answer(session: "v1", agent: .vibe, body: "```json\n{\"terms\":[\"inkwell\",\"qmk\"]}\n```").status, 200)
        let project = try XCTUnwrap(store.snapshot().projects.first { $0.key == "remote:quill-fix" })
        XCTAssertEqual(project.terms.map(\.term), ["qmk"], "a term the user refused is dropped")
        XCTAssertEqual(project.terms.first?.sources, ["agent:vibe"])
    }

    func testAnswersTheMacDidNotAskForAreRefused() throws {
        try hook("SessionStart", session: "s1")
        try hook("SessionStart", session: "idle")
        try dictate(into: "s1")
        try hook("UserPromptSubmit", session: "s1")

        XCTAssertEqual(try answer(session: "s1", token: String(repeating: "A", count: 43)).status, 401)
        XCTAssertEqual(try answer(session: "idle").status, 409, "a session that was not asked")
        XCTAssertEqual(try answer(session: "nobody").status, 409, "a session the Mac never saw")

        let other = try hosts.enroll(label: "otherhost")
        XCTAssertEqual(try answer(session: "s1", token: other.token).status, 409, "another host's session")

        XCTAssertEqual(
            try answer(session: "s1", body: "", contentLength: RemoteProjectTermRequests.maxAnswerBytes + 1).status, 413
        )
        XCTAssertEqual(try answer(session: "s1", body: "Here are the terms: Quillmark").status, 400)
        XCTAssertTrue(store.snapshot().projects.allSatisfy { $0.terms.isEmpty }, "nothing refused was stored")
    }

    func testAnAnswerWithoutAValidSessionHeaderIsRefused() throws {
        let response = try send(
            path: "/v1/terms",
            headers: ["Authorization": "Bearer \(token)", "X-Lvx-Terms-Session": "../etc"],
            body: Data(#"{"terms":["x"]}"#.utf8)
        )
        XCTAssertEqual(response.status, 400)
    }

    func testAnAskThatWasNeverAnsweredExpires() throws {
        try hook("SessionStart", session: "s1")
        try dictate(into: "s1")
        try hook("UserPromptSubmit", session: "s1")
        clock.advance(RemoteProjectTermRequests.answerLifetime + 1)
        XCTAssertEqual(try answer(session: "s1").status, 409)
    }

    // MARK: Trigger

    func testTheProposerHandsARemoteJoinOverOnlyWithTheSettingOn() throws {
        try hook("SessionStart", session: "s1")
        let snapshot = try XCTUnwrap(sessions.snapshot(sessionID: key("s1")))
        let proposer = ProjectTermProposer(
            store: store,
            runner: RefusingRunner(),
            now: { [clock] in clock.now() }
        )
        proposer.attachRemote(requests)

        XCTAssertNil(proposer.dictationCommitted(join: snapshot, enabled: false, excluding: []))
        XCTAssertNil(try hook("Stop", session: "s1").headers[termsHeader], "the setting is off")
        XCTAssertNil(proposer.dictationCommitted(join: snapshot, enabled: true, excluding: []), "no local run")
        XCTAssertEqual(try hook("Stop", session: "s1").headers[termsHeader], wanted)
    }

    private struct RefusingRunner: ProjectTermProposalRunning {
        func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
            XCTFail("a remote join must never run an agent on this machine")
            return .failed(.launchFailed)
        }
    }

    // MARK: Contract with the shipped files

    func testTheShimsReadTheHeaderAndTheRunnerMatchesTheLocalRun() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let claudeShim = try text("integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh")
        let vibeShim = try text("integrations/vibe/remote/post.sh")
        let runner = try text("integrations/claude-code/plugins/localvoxtral-remote/hooks/terms.sh")

        XCTAssertTrue(claudeShim.contains("X-Lvx-Plugin-Version: \(RemoteProjectTermRequests.minimumPluginVersion)"))
        XCTAssertTrue(vibeShim.contains("X-Lvx-Vibe-Hooks-Version: \(RemoteProjectTermRequests.minimumVibeHooksVersion)"))
        for shim in [claudeShim, vibeShim] {
            XCTAssertTrue(shim.contains("[Xx]-[Ll][Vv][Xx]-[Tt][Ee][Rr][Mm][Ss]: \(wanted)$"))
        }
        XCTAssertTrue(runner.contains("\(RemoteProjectTermRequests.answerSessionHeaderName): $SESSION_ID"))
        XCTAssertTrue(runner.contains(RemoteProjectTermRequests.answerPath))
        XCTAssertTrue(runner.contains("head -c \(RemoteProjectTermRequests.maxAnswerBytes)"))

        // The same run as the app's local one (ProjectTermProposal), but for
        // the output mode.
        XCTAssertTrue(runner.contains("\n" + ProjectTermProposal.prompt + "\n"))
        let quoted = ProjectTermProposal.claudeSystemPrompt.replacingOccurrences(of: "'", with: "'\"'\"'")
        XCTAssertTrue(runner.contains("'\(quoted)'"))
        XCTAssertTrue(runner.contains("'\(ProjectTermProposal.claudeJSONSchema)'"))
        let claude = ProjectTermProposal.claudeArguments()
        for (flag, value) in zip(claude, claude.dropFirst()) where flag.hasPrefix("--") && !value.hasPrefix("-") {
            switch flag {
            case "--system-prompt", "--json-schema": continue
            case "--output-format": XCTAssertTrue(runner.contains("--output-format text"))
            default: XCTAssertTrue(runner.contains("\(flag) \(value)") || runner.contains("\(flag) '\(value)'"), flag)
            }
        }
        let vibe = ProjectTermProposal.vibeArguments(trackedFiles: [])
        for (flag, value) in zip(vibe, vibe.dropFirst()) where flag.hasPrefix("--") && !value.hasPrefix("-") && flag != "-p" {
            switch flag {
            case "--output": XCTAssertTrue(runner.contains("--output text"))
            default: XCTAssertTrue(runner.contains("\(flag) \(value)") || runner.contains("\(flag) '\(value)'"), flag)
            }
        }
        for flag in ["--experimental-harness", "--auto-approve", "--strict-mcp-config", "--no-session-persistence"] {
            XCTAssertTrue(runner.contains(flag), flag)
        }
        XCTAssertTrue(runner.contains(#"Tracked files (read_file takes these paths):"#))
        XCTAssertTrue(runner.contains("head -n \(ProjectTermProposal.maxListedFiles)"))
    }
}
