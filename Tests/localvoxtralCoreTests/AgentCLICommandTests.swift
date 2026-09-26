import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
@testable import LocalvoxtralCLICore
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The `localvoxtral` command's arguments (#721).
final class AgentCLIArgumentsTests: XCTestCase {
    /// 2026-09-21 14:13:20 UTC, a Monday afternoon in Paris.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func arguments(environment: [String: String] = ["HOME": "/Users/me"]) -> AgentCLIArguments {
        AgentCLIArguments(now: now, timeZone: paris, workingDirectory: "/work/quillmark/Sources", environment: environment)
    }

    private func run(_ line: [String], environment: [String: String] = ["HOME": "/Users/me"]) -> AgentCLIInvocation? {
        if case .run(let invocation) = arguments(environment: environment).parse(line) { return invocation }
        return nil
    }

    func testHistorySearchTakesItsTextAndFilters() throws {
        let invocation = try XCTUnwrap(run(["history", "search", "mac", "queue", "--project", "..", "--since=yesterday", "--limit", "5", "--json"]))
        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.request.knownCommand, .historySearch)
        XCTAssertEqual(invocation.request.text, "mac queue")
        XCTAssertEqual(invocation.request.project, "/work/quillmark")
        XCTAssertEqual(invocation.request.limit, 5)
        // Midnight, Sunday 2026-09-20, in Paris.
        XCTAssertEqual(invocation.request.since, ISO8601DateFormatter().date(from: "2026-09-19T22:00:00Z"))
    }

    func testSinceReadsDaysDurationsAndDates() {
        let parser = arguments()
        XCTAssertEqual(parser.since("today"), ISO8601DateFormatter().date(from: "2026-09-20T22:00:00Z"))
        XCTAssertEqual(parser.since("12h"), now.addingTimeInterval(-12 * 3_600))
        XCTAssertEqual(parser.since("3d"), now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(parser.since("30m"), now.addingTimeInterval(-1_800))
        XCTAssertEqual(parser.since("2w"), now.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(parser.since("2026-09-18"), ISO8601DateFormatter().date(from: "2026-09-17T22:00:00Z"))
        XCTAssertEqual(parser.since("2026-09-18T08:00:00Z"), ISO8601DateFormatter().date(from: "2026-09-18T08:00:00Z"))
        XCTAssertNil(parser.since("last tuesday"))
    }

    func testAProjectIsADirectoryWhenItLooksLikeOneAndANameOtherwise() {
        let parser = arguments()
        XCTAssertEqual(parser.project("."), "/work/quillmark/Sources")
        XCTAssertEqual(parser.project("~/code/app"), "/Users/me/code/app")
        XCTAssertEqual(parser.project("sub/dir"), "/work/quillmark/Sources/sub/dir")
        XCTAssertEqual(parser.project("/abs/path/"), "/abs/path")
        XCTAssertEqual(parser.project("quillmark"), "quillmark")
    }

    func testProposeDefaultsToTheWorkingDirectoryAndTheDetectedAgent() throws {
        var invocation = try XCTUnwrap(
            run(["terms", "propose", "Inkwell", "QuillDoc"], environment: ["CLAUDECODE": "1"])
        )
        XCTAssertEqual(invocation.request.terms, ["Inkwell", "QuillDoc"])
        XCTAssertEqual(invocation.request.project, "/work/quillmark/Sources")
        XCTAssertEqual(invocation.request.caller, .claude)

        invocation = try XCTUnwrap(run(["terms", "propose", "Inkwell", "--agent", "Vibe", "--project", "quillmark"]))
        XCTAssertEqual(invocation.request.caller, .vibe)
        XCTAssertEqual(invocation.request.project, "quillmark")
        XCTAssertEqual(try XCTUnwrap(run(["terms", "propose", "x"])).request.caller, .unknown)
    }

    func testTheCallerIsReadFromTheAgentsOwnEnvironment() {
        XCTAssertEqual(AgentCLICaller.detect(environment: ["CLAUDECODE": "1"]), .claude)
        XCTAssertEqual(AgentCLICaller.detect(environment: ["OPENCODE": "1"]), .opencode)
        XCTAssertEqual(AgentCLICaller.detect(environment: ["CODEX_THREAD_ID": "t"]), .codex)
        XCTAssertEqual(AgentCLICaller.detect(environment: ["MISTRAL_API_KEY": "k"]), .unknown)
    }

    func testMistakesAreUsageErrors() {
        let parser = arguments()
        for line in [
            ["history"], ["history", "delete"], ["terms", "propose"], ["frobnicate"],
            ["status", "--limit", "3"], ["history", "last", "--project", "."],
            ["history", "search", "x", "--limit", "900"], ["history", "search", "x", "--since", "soon"],
            ["terms", "propose", "x", "--agent", "gpt"], ["status", "extra"], ["history", "search", "--limit"],
            ["status", "--verbose"],
        ] {
            guard case .usageError = parser.parse(line) else {
                XCTFail("\(line) should be a usage error")
                continue
            }
        }
        XCTAssertEqual(parser.parse([]), .help)
        XCTAssertEqual(parser.parse(["help"]), .help)
        XCTAssertEqual(parser.parse(["status", "--help"]), .help)
        // Only the first word asks for help: this searches for it.
        XCTAssertEqual(run(["history", "search", "help", "me"])?.request.text, "help me")
    }
}

/// The command against the production broker over a real AF_UNIX socket
/// (#721): a request is answered from the fixture store, and hook records on
/// the same socket still reach the registry.
final class AgentCLIBrokerTests: XCTestCase {
    private var directory: URL!
    private var broker: ClaudeContextBroker?
    private var socketPath: String { directory.appendingPathComponent("ctx.sock").path }
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func start(
        source: FixtureAgentCLIDataSource?,
        registry: ClaudeSessionRegistry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) }, isProcessAlive: { _ in true })
    ) throws {
        var answer: (@Sendable (AgentCLIRequest) async -> AgentCLIResponse)?
        if let source {
            let service = AgentCLIService(source: source, resolveLocalProject: { _ in nil })
            answer = { await service.respond(to: $0) }
        }
        let broker = ClaudeContextBroker(socketPath: socketPath, registry: registry, agentCLI: answer)
        try broker.start()
        self.broker = broker
    }

    private func command(_ line: [String]) throws -> AgentCLIRunner.Outcome {
        let parser = AgentCLIArguments(
            now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: utc, workingDirectory: "/tmp", environment: [:])
        guard case .run(let invocation) = parser.parse(line) else {
            XCTFail("\(line) did not parse")
            throw CancellationError()
        }
        return AgentCLIRunner(transport: AgentCLIRunner.socketTransport(socketPath: socketPath), timeZone: utc)
            .run(invocation)
    }

    private func fixture() -> FixtureAgentCLIDataSource {
        var state = FixtureAgentCLIDataSource.State()
        state.dictations = [
            AgentCLIDictation(
                id: "a",
                startedAt: Date(timeIntervalSince1970: 1_789_996_400),
                finishedAt: Date(timeIntervalSince1970: 1_789_996_405),
                project: AgentCLIProject(key: "/work/quillmark", name: "quillmark"),
                agent: "claude",
                targetApp: "com.mitchellh.ghostty",
                rawText: "the mac queue is stuck",
                finalText: "The Mac queue is stuck.",
                inserted: true,
                status: "completed"
            ),
        ]
        return FixtureAgentCLIDataSource(state)
    }

    func testTheCommandReadsHistoryThroughTheBroker() throws {
        try start(source: fixture())
        let outcome = try command(["history", "search", "queue", "--json"])
        XCTAssertEqual(outcome.exitCode, .answered)
        let response = try XCTUnwrap(AgentCLIWire.decodeResponse(Data(outcome.stdout.utf8)))
        XCTAssertEqual(response.history?.dictations.map(\.finalText), ["The Mac queue is stuck."])

        let text = try command(["history", "search", "queue"])
        XCTAssertEqual(
            text.stdout,
            "2026-09-21 13:13  quillmark  claude  com.mitchellh.ghostty\n  The Mac queue is stuck.\n  heard: the mac queue is stuck\n"
        )
    }

    func testAHistoryAnswerLargerThanAHookReceiptArrivesWhole() throws {
        let source = fixture()
        let long = String(repeating: "word ", count: 4_000)
        source.state.withLock { state in
            state.dictations = (0..<AgentCLIWire.maxHistoryLimit).map { index in
                AgentCLIDictation(
                    id: "\(index)", startedAt: Date(timeIntervalSince1970: Double(1_789_000_000 + index)),
                    finishedAt: Date(timeIntervalSince1970: Double(1_789_000_000 + index)),
                    project: nil, agent: nil, targetApp: nil, rawText: long, finalText: long,
                    inserted: true, status: "completed")
            }
        }
        try start(source: source)
        let outcome = try command(["history", "search", "--limit", "200", "--json"])
        XCTAssertEqual(outcome.exitCode, .answered, outcome.stderr)
        XCTAssertEqual(AgentCLIWire.decodeResponse(Data(outcome.stdout.utf8))?.history?.dictations.count, 200)
    }

    func testHookRecordsStillReachTheRegistryOnTheSameSocket() throws {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) }, isProcessAlive: { _ in true })
        try start(source: fixture(), registry: registry)
        let ingested = expectation(description: "hook record ingested")
        broker?.debugConfigureIngestHook { _ in ingested.fulfill() }
        let record = ClaudeHookRecord(event: .sessionStart, sessionID: "s-1", timestamp: 1, rawCwd: "/repo")
        XCTAssertNil(
            UnixSocketPublisher(timeout: 2).publish(
                line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)), to: socketPath))
        wait(for: [ingested], timeout: 5)
        XCTAssertNotNil(registry.snapshot(sessionID: "s-1"))
        XCTAssertEqual(try command(["status", "--json"]).exitCode, .answered)
    }

    func testABrokerWithoutAnAnswererRefusesInsteadOfDropping() throws {
        try start(source: nil)
        let outcome = try command(["status", "--json"])
        XCTAssertEqual(outcome.exitCode, .refused)
        XCTAssertEqual(AgentCLIWire.decodeResponse(Data(outcome.stdout.utf8))?.error?.code, .busy)
    }

    func testWithTheAppNotRunningStatusSaysSoAndOtherCommandsExitThree() throws {
        let status = try command(["status", "--json"])
        XCTAssertEqual(status.exitCode, .answered)
        XCTAssertEqual(status.stdout, #"{"cli":1,"ok":true,"status":{"dictating":false,"historyKept":false,"running":false}}"# + "\n")
        XCTAssertEqual(try command(["status"]).stdout, "localvoxtral is not running.\n")

        let history = try command(["history", "last"])
        XCTAssertEqual(history.exitCode, .notRunning)
        XCTAssertEqual(history.stderr, "localvoxtral: localvoxtral is not running\n")
    }
}
