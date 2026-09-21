import ClaudeContextWire
import Foundation
import XCTest
@testable import ClaudeHookPublisherCore
@testable import localvoxtral

// Vibe's Unified Harness hook payloads, as `_foreign_hooks.py` builds them in
// mistralai-vibe-local-harness 0.5.1 (`_post_agent_payload`,
// `_post_tool_payload`): no session id, no parent, no transcript path, and
// group-qualified tool names. Field failure 2026-09-21: a user on the unified
// rollout never got a join, because every one of these was dropped.

final class VibeUnifiedHarnessParserTests: XCTestCase {
    private let turnEnd = Data(#"{"cwd":"/Users/t/repo","hook_event_name":"post_agent"}"#.utf8)

    private func tool(_ name: String, input: String) -> Data {
        Data("""
        {"cwd":"/Users/t/repo","hook_event_name":"post_tool","tool_name":"\(name)",\
        "tool_call_id":"c1","tool_input":\(input),"tool_status":"success","tool_output":null,\
        "tool_output_text":"secret file body","tool_error":null,"duration_ms":0}
        """.utf8)
    }

    func testATurnEndWithoutASessionIDParses() throws {
        let input = try XCTUnwrap(VibeHookInputParser.parse(data: turnEnd))
        XCTAssertEqual(input.kind, .postAgent)
        XCTAssertEqual(input.cwd, "/Users/t/repo")
        XCTAssertNil(input.transcriptPath)
    }

    func testQualifiedFileToolsNameTheirPathUnderEitherArgument() throws {
        let read = try XCTUnwrap(VibeHookInputParser.parse(
            data: tool("file_system.read_file", input: #"{"path":"Sources/App.swift","offset":0}"#)))
        XCTAssertEqual(read.files, [ClaudeFileTouch(path: "/Users/t/repo/Sources/App.swift", kind: .read)])

        let write = try XCTUnwrap(VibeHookInputParser.parse(
            data: tool("file_system.write_file", input: #"{"path":"/Users/t/repo/a.txt","content":"x"}"#)))
        XCTAssertEqual(write.files, [ClaudeFileTouch(path: "/Users/t/repo/a.txt", kind: .edited)])

        let edit = try XCTUnwrap(VibeHookInputParser.parse(
            data: tool("file_system.search_replace", input: #"{"file_path":"b.txt","blocks":[]}"#)))
        XCTAssertEqual(edit.files, [ClaudeFileTouch(path: "/Users/t/repo/b.txt", kind: .edited)])
    }

    func testOtherQualifiedToolsCarryNoFiles() throws {
        let bash = try XCTUnwrap(VibeHookInputParser.parse(
            data: tool("file_system.bash", input: #"{"command":"cat /etc/passwd","path":"/etc/passwd"}"#)))
        XCTAssertEqual(bash.files, [])
    }

    func testASessionIDWithoutTheParentFieldIsStillDropped() {
        // The legacy runner always writes `parent_session_id`. A payload that
        // names a session and omits it is neither shape.
        let data = Data(#"{"session_id":"s","cwd":"/r","hook_event_name":"post_agent"}"#.utf8)
        XCTAssertNil(VibeHookInputParser.parse(data: data))
    }

    func testAParentWithoutASessionIDIsDropped() {
        let data = Data(#"{"parent_session_id":"p","cwd":"/r","hook_event_name":"post_agent"}"#.utf8)
        XCTAssertNil(VibeHookInputParser.parse(data: data))
    }

    func testTheShippedHookMatchesBothRunnersFileTools() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["integrations/vibe/hooks.toml", "integrations/vibe/remote/hooks.toml"] {
            let block = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let line = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix(#"match = "re:"#) }, file)
            let pattern = String(line.dropFirst(#"match = "re:"#.count).dropLast())
            XCTAssertFalse(pattern.contains("\\"), "a TOML basic string would need the backslash doubled")
            // Both runners match case-insensitively against the whole name.
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            func matches(_ name: String) -> Bool {
                regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            for name in ["read_file", "write_file", "edit",
                         "file_system.read_file", "file_system.write_file", "file_system.search_replace"] {
                XCTAssertTrue(matches(name), "\(name) is never hooked by \(file)")
            }
            for name in ["bash", "file_system.bash", "file_systemXread_file", "my_read_file", "edit_notes"] {
                XCTAssertFalse(matches(name), "\(name) is hooked by \(file)")
            }
        }
    }
}

final class VibeUnifiedHarnessPublisherTests: XCTestCase {
    private var directory: URL!
    private var registry: ClaudeSessionRegistry!
    private var broker: ClaudeContextBroker!
    private var socketPath: String { directory.appendingPathComponent("s").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // /tmp: `sun_path` is 104 bytes on Darwin (see ClaudeContextBrokerTests).
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true },
            processStartMicros: { [300: 1_700_000_000_000_123, 301: 1_700_000_000_000_999][$0] }
        )
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry)
        try broker.start()
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A hook whose wrapper shell is pid 500, spawned by the Vibe at `vibePID`.
    private func run(_ payload: String, vibePID: Int32, tty: String, startMicros: Int64?) -> ClaudeHookPublisher.Outcome {
        let publisher = ClaudeHookPublisher(
            environment: .init(
                now: { 1_700_000_000 },
                pid: { 4242 },
                ppid: { 500 },
                ttyName: { $0 == vibePID ? tty : nil },
                variables: [ClaudeHookSocketPath.environmentKey: socketPath]
            ),
            publisher: UnixSocketPublisher(timeout: 2.0)
        )
        let vibe = ClaudeHookPublisher.VibeEnvironment(
            ownSession: { 500 },
            processFacts: { pid in
                pid == 500 ? .init(parent: vibePID, session: 500, hasTTY: false)
                    : .init(parent: 1, session: vibePID, hasTTY: true, startMicros: startMicros)
            },
            lastUserPrompt: { path, _ in path == nil ? nil : "unexpected" }
        )
        return publisher.runVibe(stdin: Data(payload.utf8), vibe: vibe)
    }

    private let turnEnd = #"{"cwd":"/tmp","hook_event_name":"post_agent"}"#

    private func ingest(count: Int, _ body: () -> Void) {
        let done = expectation(description: "ingested")
        done.expectedFulfillmentCount = count
        broker.debugConfigureIngestHook { _ in done.fulfill() }
        body()
        wait(for: [done], timeout: 5)
    }

    func testATurnEndWithoutASessionIDJoinsOnVibesTty() throws {
        ingest(count: 1) {
            XCTAssertEqual(run(turnEnd, vibePID: 300, tty: "/dev/ttys042", startMicros: 1_700_000_000_000_123), .published)
        }
        guard case .resolved(let snapshot) = registry.resolve(tty: "/dev/ttys042") else {
            return XCTFail("the pane Vibe runs in has no session")
        }
        XCTAssertEqual(snapshot.agent, .vibe)
        XCTAssertEqual(snapshot.process?.claudePID, 300)
        XCTAssertEqual(snapshot.process?.agentStartMicros, 1_700_000_000_000_123)
        XCTAssertNil(snapshot.latestPriorUserPrompt, "this runner names no session log")
    }

    func testTwoVibesAreTwoSessionsAndEachHookLandsOnItsOwn() throws {
        ingest(count: 3) {
            XCTAssertEqual(run(turnEnd, vibePID: 300, tty: "/dev/ttys042", startMicros: 1_700_000_000_000_123), .published)
            XCTAssertEqual(run(turnEnd, vibePID: 301, tty: "/dev/ttys043", startMicros: 1_700_000_000_000_999), .published)
            XCTAssertEqual(run(turnEnd, vibePID: 300, tty: "/dev/ttys042", startMicros: 1_700_000_000_000_123), .published)
        }
        guard case .resolved(let first) = registry.resolve(tty: "/dev/ttys042"),
              case .resolved(let second) = registry.resolve(tty: "/dev/ttys043")
        else { return XCTFail("each pane must resolve to exactly one session") }
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(first.process?.claudePID, 300)
        XCTAssertEqual(second.process?.claudePID, 301)
    }

    func testWithoutAStartTimeThereIsNoSessionToName() {
        XCTAssertEqual(run(turnEnd, vibePID: 300, tty: "/dev/ttys042", startMicros: nil), .droppedUnparseable)
        guard case .unknown = registry.resolve(tty: "/dev/ttys042") else {
            return XCTFail("nothing may register without an id")
        }
    }
}
