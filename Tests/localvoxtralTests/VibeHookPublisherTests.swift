import ClaudeContextWire
import Darwin
import Foundation
import XCTest
@testable import ClaudeHookPublisherCore
@testable import localvoxtral

// Payload shapes below were captured from Vibe 2.25.4 with a probe hook
// (`model_dump_json` of `PostToolInvocation` / `PostAgentInvocation`).

// MARK: - Parser

final class VibeHookInputParserTests: XCTestCase {
    private func payload(_ extra: String = "", event: String, parent: String = "null") -> Data {
        Data("""
        {"session_id":"7f4aefdf-5f36-0996-6dca-3b304bd8d70f",\
        "transcript_path":"/Users/t/.vibe/logs/session/session_1/messages.jsonl",\
        "cwd":"/Users/t/repo","parent_session_id":\(parent),"hook_event_name":"\(event)"\(extra)}
        """.utf8)
    }

    func testPostAgentParsesSessionCwdAndTranscriptPath() throws {
        let input = try XCTUnwrap(VibeHookInputParser.parse(data: payload(event: "post_agent")))
        XCTAssertEqual(input.kind, .postAgent)
        XCTAssertEqual(input.sessionID, "7f4aefdf-5f36-0996-6dca-3b304bd8d70f")
        XCTAssertEqual(input.cwd, "/Users/t/repo")
        XCTAssertEqual(input.transcriptPath, "/Users/t/.vibe/logs/session/session_1/messages.jsonl")
        XCTAssertEqual(input.files, [])
    }

    func testRelativeFilePathResolvesAgainstThePayloadCwd() throws {
        // Measured: Vibe hands hooks the model's raw argument, `note.txt`.
        let data = payload(
            #","tool_name":"read_file","tool_call_id":"C1","tool_input":{"file_path":"src/../note.txt","offset":null,"limit":2000},"tool_status":"success""#,
            event: "post_tool"
        )
        let input = try XCTUnwrap(VibeHookInputParser.parse(data: data))
        XCTAssertEqual(input.files, [ClaudeFileTouch(path: "/Users/t/repo/note.txt", kind: .read)])
    }

    func testWriteAndEditAreEditsAndKeepAbsolutePaths() throws {
        for tool in ["write_file", "edit"] {
            let data = payload(
                #","tool_name":"\#(tool)","tool_input":{"file_path":"/abs/a.swift","content":"SECRET"}"#,
                event: "post_tool"
            )
            let input = try XCTUnwrap(VibeHookInputParser.parse(data: data))
            XCTAssertEqual(input.files, [ClaudeFileTouch(path: "/abs/a.swift", kind: .edited)], tool)
        }
    }

    func testOtherToolsCarryNoFiles() throws {
        let data = payload(
            #","tool_name":"bash","tool_input":{"command":"cat /etc/passwd","file_path":"/etc/passwd"}"#,
            event: "post_tool"
        )
        XCTAssertEqual(try XCTUnwrap(VibeHookInputParser.parse(data: data)).files, [])
    }

    func testSubagentInvocationsAreDropped() {
        XCTAssertNil(VibeHookInputParser.parse(data: payload(event: "post_agent", parent: #""parent-1""#)))
    }

    func testAPayloadWithoutTheParentFieldIsNotProvablyTopLevel() {
        let data = Data(#"{"session_id":"s","cwd":"/r","hook_event_name":"post_agent"}"#.utf8)
        XCTAssertNil(VibeHookInputParser.parse(data: data))
    }

    func testPreToolAndUnknownEventsAreDropped() {
        XCTAssertNil(VibeHookInputParser.parse(data: payload(event: "pre_tool")))
        XCTAssertNil(VibeHookInputParser.parse(data: payload(event: "SessionStart")))
        XCTAssertNil(VibeHookInputParser.parse(data: Data("not json".utf8)))
    }

    func testAPayloadLargerThanTheWireLineLimitStillParses() throws {
        // A read_file result embeds the file. None of it is kept, so the
        // payload cap must not be the 64 KiB wire line limit.
        let big = String(repeating: "x", count: 200 * 1024)
        let data = payload(
            #","tool_name":"read_file","tool_input":{"file_path":"/abs/big.txt"},"tool_output_text":"\#(big)""#,
            event: "post_tool"
        )
        XCTAssertGreaterThan(data.count, ClaudeHookLimits.default.maxLineBytes)
        XCTAssertEqual(try XCTUnwrap(VibeHookInputParser.parse(data: data)).files.map(\.path), ["/abs/big.txt"])
    }

    func testRecordsPutThePromptFirstAndNeverCarryTheTranscriptPath() throws {
        let input = try XCTUnwrap(VibeHookInputParser.parse(data: payload(event: "post_agent")))
        let records = input.records(prompt: "fix the login bug", timestamp: 10)
        XCTAssertEqual(records.map(\.event), [.userPromptSubmit, .stop])
        XCTAssertEqual(records.map(\.agent), [.vibe, .vibe])
        XCTAssertEqual(records[0].prompt, "fix the login bug")
        for record in records {
            let line = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
            XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("messages.jsonl"))
        }
    }

    func testNoPromptMeansOnlyTheEventRecord() throws {
        let input = try XCTUnwrap(VibeHookInputParser.parse(data: payload(event: "post_agent")))
        XCTAssertEqual(input.records(prompt: nil, timestamp: 10).map(\.event), [.stop])
        XCTAssertEqual(input.records(prompt: "", timestamp: 10).map(\.event), [.stop])
    }
}

// MARK: - Session log read

final class VibeTranscriptPromptTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ lines: [String], name: String = VibeTranscriptPrompt.fileName) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url.path
    }

    func testReturnsTheLastUserMessageAndNothingElse() throws {
        let path = try write([
            #"{"role":"user","content":"first prompt","injected":false,"message_id":"a"}"#,
            #"{"role":"assistant","content":"ASSISTANT TEXT","injected":false}"#,
            #"{"role":"user","content":"  second prompt \n","injected":false,"message_id":"b"}"#,
            #"{"role":"assistant","reasoning_content":"REASONING","tool_calls":[]}"#,
            #"{"role":"tool","content":"TOOL OUTPUT","name":"read_file"}"#,
        ])
        XCTAssertEqual(VibeTranscriptPrompt.lastUserPrompt(atPath: path), "second prompt")
    }

    func testInjectedUserMessagesAreNotThePrompt() throws {
        let path = try write([
            #"{"role":"user","content":"what the user typed","injected":false}"#,
            #"{"role":"user","content":"hook retry reason","injected":true}"#,
        ])
        XCTAssertEqual(VibeTranscriptPrompt.lastUserPrompt(atPath: path), "what the user typed")
    }

    func testAUserLineWithoutTheInjectedFieldIsNotTrusted() throws {
        // Schema drift must cost the prompt, never send Vibe-written text.
        let path = try write([
            #"{"role":"user","content":"older, marked","injected":false}"#,
            #"{"role":"user","content":"newer, unmarked"}"#,
        ])
        XCTAssertEqual(VibeTranscriptPrompt.lastUserPrompt(atPath: path), "older, marked")
    }

    func testALineWithoutTheUserRoleMarkerIsNeverParsed() {
        // Valid JSON whose role is spelled in a way Vibe does not write: if it
        // were parsed it would qualify, so nil proves the prefilter ran first.
        let spaced = Data(#"{"role" : "user", "content": "x", "injected": false}"#.utf8)
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(inTail: spaced, limits: .default))
        // A tool line QUOTING the marker is parsed and then refused by its role.
        let quoting = Data(#"{"role": "tool", "content": "{\"role\": \"user\"}", "injected": false}"#.utf8)
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(inTail: quoting, limits: .default))
    }

    func testAReadThatNeverReturnsIsAbandonedAtTheDeadline() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let prompt = VibeTranscriptPrompt.lastUserPrompt(atPath: "/stalled/messages.jsonl", deadline: 0.05) { _, _ in
            release.wait()
            return "too late"
        }
        XCTAssertNil(prompt)
        XCTAssertEqual(
            VibeTranscriptPrompt.lastUserPrompt(atPath: "/fast/messages.jsonl", deadline: 30) { _, _ in "in time" },
            "in time"
        )
    }

    func testNonStringContentAndBrokenLinesAreSkipped() throws {
        let path = try write([
            #"{"role":"user","content":"kept","injected":false}"#,
            #"{"role":"user","content":[{"type":"text","text":"multimodal"}],"injected":false}"#,
            #"{"role":"user","content":"cut mid-rec"#,
        ])
        XCTAssertEqual(VibeTranscriptPrompt.lastUserPrompt(atPath: path), "kept")
    }

    func testThePromptIsTruncatedToTheWireLimit() throws {
        let long = String(repeating: "a", count: 20_000)
        let path = try write([#"{"role": "user", "content": "\#(long)", "injected": false}"#])
        let prompt = try XCTUnwrap(VibeTranscriptPrompt.lastUserPrompt(atPath: path))
        XCTAssertEqual(prompt.utf8.count, ClaudeHookLimits.default.maxPromptBytes)
    }

    func testOnlyTheTailWindowIsRead() throws {
        let filler = #"{"role":"tool","content":"\#(String(repeating: "z", count: 4096))"}"#
        let lines = [#"{"role":"user","content":"too far back","injected":false}"#]
            + Array(repeating: filler, count: VibeTranscriptPrompt.tailBytes / 4096 + 8)
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: try write(lines)))
    }

    func testRefusesAnyOtherFileNameASymlinkAndARelativePath() throws {
        let line = [#"{"role":"user","content":"prompt","injected":false}"#]
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: try write(line, name: "notes.jsonl")))

        let real = try write(line, name: "real.jsonl")
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let linkPath = link.appendingPathComponent(VibeTranscriptPrompt.fileName).path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: real)
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: linkPath), "O_NOFOLLOW")

        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: "messages.jsonl"))
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: nil))
        XCTAssertNil(VibeTranscriptPrompt.lastUserPrompt(atPath: directory.path + "/absent/messages.jsonl"))
    }
}

// MARK: - Ancestor walk

final class VibeAncestorPIDTests: XCTestCase {
    private typealias Facts = ClaudeHookPublisher.ProcessFacts

    private func walk(from start: Int32, ownSession: Int32 = 500, table: [Int32: Facts]) -> Int32 {
        ClaudeHookPublisher.vibeAncestorPID(startingAt: start, ownSession: ownSession) { table[$0] }
    }

    func testClimbsPastTheDetachedWrapperShellToVibe() {
        // dash: `sh -c` (500, the hook's session leader) did not exec the shim.
        let table: [Int32: Facts] = [
            500: Facts(parent: 300, session: 500, hasTTY: false),
            300: Facts(parent: 200, session: 200, hasTTY: true),
        ]
        XCTAssertEqual(walk(from: 500, table: table), 300)
    }

    func testStaysOnVibeWhenTheWrapperExecd() {
        // macOS sh: `sh -c` exec'd the shim, so the shim's $PPID is Vibe.
        let table: [Int32: Facts] = [
            300: Facts(parent: 200, session: 200, hasTTY: true),
            200: Facts(parent: 1, session: 200, hasTTY: true),
        ]
        XCTAssertEqual(walk(from: 300, table: table), 300)
    }

    func testHeadlessVibeIsFoundByItsSessionAlone() {
        let table: [Int32: Facts] = [
            500: Facts(parent: 300, session: 500, hasTTY: false),
            300: Facts(parent: 1, session: 300, hasTTY: false),
        ]
        XCTAssertEqual(walk(from: 500, table: table), 300)
    }

    func testAProcessWithATerminalStopsTheClimbEvenInOurSession() {
        // If Vibe ever stops detaching hooks, everything up to the login shell
        // shares one session. The walk must not climb past the start.
        let table: [Int32: Facts] = [
            400: Facts(parent: 300, session: 100, hasTTY: true),
            300: Facts(parent: 100, session: 100, hasTTY: true),
        ]
        XCTAssertEqual(walk(from: 400, ownSession: 100, table: table), 400)
    }

    func testTheClimbIsBoundedAndUnreadablePidsEndIt() {
        var table: [Int32: Facts] = [:]
        for pid in Int32(10)...30 { table[pid] = Facts(parent: pid - 1, session: 500, hasTTY: false) }
        XCTAssertEqual(walk(from: 30, table: table), 30 - Int32(ClaudeHookPublisher.vibeAncestorHops))
        XCTAssertEqual(walk(from: 77, table: [:]), 77)
    }
}

// MARK: - Publisher run

final class VibeHookPublisherRunTests: XCTestCase {
    private var directory: URL!
    private var broker: ClaudeContextBroker!
    private var registry: ClaudeSessionRegistry!

    private var socketPath: String { directory.appendingPathComponent("ctx.sock").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // /tmp: `sun_path` is 104 bytes on Darwin (see ClaudeContextBrokerTests).
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true },
            // Pid 300 is a fixture; its start time is whatever `vibe` reports.
            processStartMicros: { $0 == 300 ? 1_700_000_000_000_123 : nil }
        )
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry)
        try broker.start()
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func publisher(variables extra: [String: String] = [:]) -> ClaudeHookPublisher {
        var variables = [ClaudeHookSocketPath.environmentKey: socketPath]
        variables.merge(extra) { $1 }
        return ClaudeHookPublisher(
            environment: .init(
                now: { 1_700_000_000 },
                pid: { 4242 },
                ppid: { 500 },
                ttyName: { $0 == 300 ? "/dev/ttys042" : nil },
                variables: variables
            ),
            publisher: UnixSocketPublisher(timeout: 2.0)
        )
    }

    private var vibe: ClaudeHookPublisher.VibeEnvironment {
        .init(
            ownSession: { 500 },
            processFacts: { pid in
                pid == 500 ? .init(parent: 300, session: 500, hasTTY: false)
                    : .init(parent: 1, session: 300, hasTTY: true, startMicros: 1_700_000_000_000_123)
            },
            lastUserPrompt: { path, _ in path == "/t/messages.jsonl" ? "rename the wire enum" : nil }
        )
    }

    private func payload(event: String, extra: String = "") -> Data {
        Data("""
        {"session_id":"abc","transcript_path":"/t/messages.jsonl","cwd":"/tmp",\
        "parent_session_id":null,"hook_event_name":"\(event)"\(extra)}
        """.utf8)
    }

    func testATurnEndRegistersTheSessionWithItsPromptVibesPidAndTty() throws {
        let done = expectation(description: "prompt and stop ingested")
        done.expectedFulfillmentCount = 2
        broker.debugConfigureIngestHook { _ in done.fulfill() }

        XCTAssertEqual(publisher().runVibe(stdin: payload(event: "post_agent"), vibe: vibe), .published)
        wait(for: [done], timeout: 5)

        XCTAssertNil(registry.snapshot(sessionID: "abc"), "a Vibe id is never a bare Claude key")
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "vibe:abc"))
        XCTAssertEqual(snapshot.agent, .vibe)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "rename the wire enum")
        XCTAssertEqual(snapshot.activity, .idle, "Stop lands after the prompt record")
        XCTAssertEqual(snapshot.process?.claudePID, 300, "Vibe, not the wrapper shell that exits with the hook")
        XCTAssertEqual(snapshot.process?.tty, "/dev/ttys042")
        XCTAssertEqual(snapshot.process?.agentStartMicros, 1_700_000_000_000_123, "Vibe's, not the wrapper's")
    }

    func testAFileToolRecordsTheTouchAndKeepsTheTurnWorking() throws {
        let done = expectation(description: "prompt and tool ingested")
        done.expectedFulfillmentCount = 2
        broker.debugConfigureIngestHook { _ in done.fulfill() }

        let extra = #","tool_name":"edit","tool_input":{"file_path":"a.swift"},"tool_output_text":"FILE BODY""#
        XCTAssertEqual(
            publisher().runVibe(stdin: payload(event: "post_tool", extra: extra), vibe: vibe),
            .published
        )
        wait(for: [done], timeout: 5)

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "vibe:abc"))
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["/tmp/a.swift"])
        XCTAssertEqual(snapshot.recentFiles.map(\.kind), [.edited])
        XCTAssertEqual(snapshot.activity, .working)
    }

    func testClaudeSessionHandlesInheritedFromAParentClaudeSessionAreNotPublished() throws {
        let done = expectation(description: "ingested")
        done.expectedFulfillmentCount = 2
        broker.debugConfigureIngestHook { _ in done.fulfill() }

        let inherited = publisher(variables: [
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "session_inherited",
            "CLAUDE_CODE_HOST_SESSION_ID": "local_inherited",
            "HERDR_PANE_ID": "w1:p2",
        ])
        XCTAssertEqual(inherited.runVibe(stdin: payload(event: "post_agent"), vibe: vibe), .published)
        wait(for: [done], timeout: 5)

        let process = try XCTUnwrap(registry.snapshot(sessionID: "vibe:abc")?.process)
        XCTAssertNil(process.bridgeSessionID)
        XCTAssertNil(process.desktopSessionID)
        XCTAssertEqual(process.herdrPaneID, "w1:p2", "the pane handle is the terminal's, and is kept")
    }

    func testAnAbsentAppIsATransportFailureAfterOneDial() {
        broker.stop()
        XCTAssertEqual(
            publisher().runVibe(stdin: payload(event: "post_agent"), vibe: vibe),
            .droppedTransport(.notListening)
        )
    }

    func testUnparseableAndSubagentPayloadsPublishNothing() {
        XCTAssertEqual(publisher().runVibe(stdin: Data("{}".utf8), vibe: vibe), .droppedUnparseable)
    }
}

// MARK: - Namespacing

private final class StartTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64?

    init(_ value: Int64?) { stored = value }

    var value: Int64? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class VibeSessionScopeTests: XCTestCase {
    func testEveryNonClaudeAgentHasADistinctPrefix() {
        XCTAssertNil(ClaudeAgentSessionScope.prefix(for: .claude))
        let prefixes = ClaudeHookAgent.allCases.compactMap(ClaudeAgentSessionScope.prefix(for:))
        XCTAssertEqual(prefixes.count, ClaudeHookAgent.allCases.count - 1)
        XCTAssertEqual(Set(prefixes).count, prefixes.count)
        XCTAssertFalse(prefixes.contains(ClaudeRemoteSessionScope.prefix))
        XCTAssertEqual(ClaudeAgentSessionScope.scopedSessionID(agent: .vibe, sessionID: "x"), "vibe:x")
    }

    func testAClaudeRecordSpellingAVibeKeyIsDropped() {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true }
        )
        let forged = ClaudeHookRecord(event: .sessionStart, sessionID: "vibe:abc", timestamp: 1)
        XCTAssertNil(registry.ingest(forged, origin: .localAuthenticated(peerUID: getuid())))

        let honest = ClaudeHookRecord(event: .stop, agent: .vibe, sessionID: "abc", timestamp: 1)
        XCTAssertEqual(registry.ingest(honest, origin: .localAuthenticated(peerUID: getuid()))?.sessionID, "vibe:abc")
    }

    func testAReusedPidDoesNotKeepADeadVibeSessionJoinable() {
        // Vibe never sends a session end. Its pid being "alive" again after it
        // exited must not be enough: the start time has to match too.
        let currentStart = StartTimeBox(111)
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true },
            processStartMicros: { _ in currentStart.value }
        )
        var record = ClaudeHookRecord(event: .stop, agent: .vibe, sessionID: "abc", timestamp: 1)
        record.process = ClaudeHookProcessInfo(
            hookPID: 9, claudePID: 300, tty: "/dev/ttys042", agentStartMicros: 111
        )
        XCTAssertNotNil(registry.ingest(record, origin: .localAuthenticated(peerUID: getuid())))
        XCTAssertNotNil(registry.snapshot(sessionID: "vibe:abc"))

        currentStart.value = 222 // pid 300 now belongs to another process
        XCTAssertNil(registry.snapshot(sessionID: "vibe:abc"))

        _ = registry.ingest(record, origin: .localAuthenticated(peerUID: getuid()))
        currentStart.value = nil // unreadable is not a match
        XCTAssertNil(registry.snapshot(sessionID: "vibe:abc"))
    }

    func testARecordWithoutAStartTimeKeepsPidOnlyLiveness() {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true },
            processStartMicros: { _ in nil }
        )
        var record = ClaudeHookRecord(event: .sessionStart, sessionID: "claude-1", timestamp: 1)
        record.process = ClaudeHookProcessInfo(hookPID: 9, claudePID: 300)
        _ = registry.ingest(record, origin: .localAuthenticated(peerUID: getuid()))
        XCTAssertNotNil(registry.snapshot(sessionID: "claude-1"))
    }

    func testAVibeFocusDeclarationIsRefused() {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true }
        )
        _ = registry.ingest(
            ClaudeHookRecord(event: .stop, agent: .vibe, sessionID: "abc", timestamp: 1),
            origin: .localAuthenticated(peerUID: getuid())
        )
        var focus = ClaudeHookRecord(event: .focusChanged, agent: .vibe, sessionID: "abc", timestamp: 2)
        focus.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 1, tty: "/dev/ttys001")
        XCTAssertNil(registry.ingest(focus, origin: .localAuthenticated(peerUID: getuid())))
    }
}

// MARK: - Shipped files

final class VibeIntegrationFilesTests: XCTestCase {
    private func file(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("integrations/vibe/\(name)"), encoding: .utf8)
    }

    func testTheShimRunsThePublisherInVibeModeAndPrintsNothing() throws {
        let shim = try file("publish.sh")
        XCTAssertTrue(shim.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(shim.contains(#"LOCALVOXTRAL_CLAUDE_PPID="$PPID" "$BIN" --agent vibe 2>/dev/null"#))
        XCTAssertTrue(shim.hasSuffix("exit 0\n"))
        let code = shim.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        for line in code {
            XCTAssertFalse(line.contains("echo") || line.contains("printf"), String(line))
            XCTAssertFalse(line.hasPrefix("exec ") || line.contains(" exec "), String(line))
        }
    }

    func testTheHookCommandSucceedsSilentlyWhenTheShimIsGone() throws {
        // The half-removed install: hooks.toml still names a script that is
        // not there. Vibe shows a non-zero hook exit on every turn.
        let block = try file("hooks.toml")
        let commands = block.split(separator: "\n").filter { $0.hasPrefix("command = ") }
        XCTAssertEqual(commands.count, 2)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-nohome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        for line in commands {
            // TOML basic string: strip `command = "` and the closing quote, unescape `\"`.
            let command = String(line.dropFirst(#"command = ""#.count).dropLast())
                .replacingOccurrences(of: #"\""#, with: "\"")
            let output = home.appendingPathComponent("out")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            let sink = try FileHandle(forWritingTo: output)
            process.standardOutput = sink
            process.standardError = sink
            try process.run()
            process.waitUntilExit()
            try sink.close()
            XCTAssertEqual(process.terminationStatus, 0, command)
            XCTAssertEqual(try Data(contentsOf: output), Data(), command)
        }
    }

    func testTheHooksBlockDeclaresOnlyTheTwoEventsTheParserReads() throws {
        let block = try file("hooks.toml")
        XCTAssertTrue(block.hasPrefix("# >>> localvoxtral >>>\n"))
        XCTAssertTrue(block.hasSuffix("# <<< localvoxtral <<<\n"))
        let types = block.split(separator: "\n").filter { $0.hasPrefix("type = ") }
        XCTAssertEqual(types, [#"type = "post_tool""#, #"type = "post_agent""#])
        XCTAssertFalse(block.contains("strict = true"), "a strict hook turns our failure into the user's")
        for tool in VibeHookInputParser.fileTools {
            XCTAssertTrue(block.contains(tool), "\(tool) is parsed but never hooked")
        }
    }
}
