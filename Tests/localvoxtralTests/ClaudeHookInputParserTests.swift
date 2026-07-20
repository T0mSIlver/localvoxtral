import Foundation
import XCTest
@testable import ClaudeContextWire

// MARK: - Raw Claude Code hook payload -> bounded wire record

final class ClaudeHookInputParserTests: XCTestCase {
    private func parse(_ json: String, fallbackEvent: String? = nil) -> ClaudeHookRecord? {
        ClaudeHookInputParser.parse(
            data: Data(json.utf8),
            fallbackEvent: fallbackEvent,
            timestamp: 1_700_000_000
        )
    }

    func testParsesUserPromptSubmit() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/repo","prompt":"fix ClaudeHookWire"}
        """#))
        XCTAssertEqual(record.event, .userPromptSubmit)
        XCTAssertEqual(record.sessionID, "s1")
        XCTAssertEqual(record.rawCwd, "/repo")
        XCTAssertEqual(record.prompt, "fix ClaudeHookWire")
        XCTAssertEqual(record.timestamp, 1_700_000_000)
    }

    func testFallsBackToArgvEventWhenPayloadOmitsIt() throws {
        let record = try XCTUnwrap(parse(#"{"session_id":"s1"}"#, fallbackEvent: "Stop"))
        XCTAssertEqual(record.event, .stop)
    }

    func testPayloadEventWinsOverArgvFallback() throws {
        let record = try XCTUnwrap(
            parse(#"{"hook_event_name":"Stop","session_id":"s1"}"#, fallbackEvent: "SessionStart")
        )
        XCTAssertEqual(record.event, .stop)
    }

    func testRejectsUnknownEvent() {
        XCTAssertNil(parse(#"{"hook_event_name":"PreCompact","session_id":"s1"}"#))
    }

    func testRejectsMissingOrEmptySessionID() {
        XCTAssertNil(parse(#"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(parse(#"{"hook_event_name":"Stop","session_id":""}"#))
    }

    func testRejectsMalformedJSON() {
        XCTAssertNil(parse("not json at all"))
    }

    func testRejectsOversizedPayloadWithoutParsing() {
        let huge = #"{"hook_event_name":"Stop","session_id":"s1","prompt":"\#(String(repeating: "x", count: 500))"}"#
        XCTAssertNil(
            ClaudeHookInputParser.parse(
                data: Data(huge.utf8),
                fallbackEvent: nil,
                timestamp: 1,
                limits: ClaudeHookLimits(maxLineBytes: 64)
            )
        )
    }

    // MARK: The allowlist — what must NOT cross the socket

    func testTranscriptPathIsDropped() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"Stop","session_id":"s1","transcript_path":"/tmp/t.jsonl"}
        """#))
        // There is no field to hold it; the encoded line proves it is gone.
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("t.jsonl"))
    }

    func testFileContentInToolInputIsDropped() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Write",
         "tool_input":{"file_path":"/repo/a.swift","content":"SECRET API KEY"},
         "tool_response":{"output":"ALSO SECRET"}}
        """#))
        XCTAssertEqual(record.files.map(\.path), ["/repo/a.swift"])
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET API KEY"))
        XCTAssertFalse(text.contains("ALSO SECRET"))
    }

    func testBashCommandStringIsNotCollected() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash",
         "tool_input":{"command":"cat /etc/passwd"}}
        """#))
        XCTAssertTrue(record.files.isEmpty, "a command string is not a file path")
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("passwd"))
    }

    // MARK: File path extraction

    func testEditingToolMarksFileAsEdited() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Edit",
         "tool_input":{"file_path":"/repo/a.swift"}}
        """#))
        XCTAssertEqual(record.files, [ClaudeFileTouch(path: "/repo/a.swift", kind: .edited)])
    }

    func testReadToolMarksFileAsRead() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read",
         "tool_input":{"file_path":"/repo/b.swift"}}
        """#))
        XCTAssertEqual(record.files, [ClaudeFileTouch(path: "/repo/b.swift", kind: .read)])
    }

    func testNotebookPathIsCollected() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"NotebookEdit",
         "tool_input":{"notebook_path":"/repo/n.ipynb"}}
        """#))
        XCTAssertEqual(record.files, [ClaudeFileTouch(path: "/repo/n.ipynb", kind: .edited)])
    }

    func testDeprecatedMultiEditIsNotTreatedAsAnEditingTool() throws {
        // MultiEdit is deprecated in Claude Code; Edit carries batches now.
        // Nothing should special-case it.
        XCTAssertFalse(ClaudeHookInputParser.editingTools.contains("MultiEdit"))
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"MultiEdit",
         "tool_input":{"file_path":"/repo/a.swift"}}
        """#))
        XCTAssertEqual(record.files.map(\.kind), [.read])
    }

    func testFileChangedTopLevelPathsAreCollectedAsEdits() throws {
        // FileChanged means the bytes on disk changed — an edit by definition,
        // and it carries no tool_name to infer that from. Classifying it as a
        // read (the tool-lookup default) would misfile every one.
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"FileChanged","session_id":"s1","file_paths":["/repo/x.swift","/repo/y.swift"]}
        """#))
        XCTAssertEqual(record.files.map(\.path), ["/repo/x.swift", "/repo/y.swift"])
        XCTAssertEqual(record.files.map(\.kind), [.edited, .edited])
    }

    // MARK: CwdChanged

    func testCwdChangedPrefersNewCwd() throws {
        // `cwd` on a CwdChanged is the OLD directory. Reading it would move the
        // session backwards on the one event whose job is to move it forwards.
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"CwdChanged","session_id":"s1","cwd":"/repo/old","new_cwd":"/repo/new"}
        """#))
        XCTAssertEqual(record.rawCwd, "/repo/new")
    }

    func testCwdChangedFallsBackToCwdWhenNewCwdAbsent() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"CwdChanged","session_id":"s1","cwd":"/repo/only"}
        """#))
        XCTAssertEqual(record.rawCwd, "/repo/only")
    }

    func testEmptyNewCwdDoesNotShadowCwd() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"CwdChanged","session_id":"s1","cwd":"/repo/old","new_cwd":""}
        """#))
        XCTAssertEqual(record.rawCwd, "/repo/old")
    }

    func testNewCwdIsIgnoredOnOtherEvents() throws {
        // Only CwdChanged carries new_cwd; honouring it elsewhere would let an
        // unrelated payload key move the session.
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"Stop","session_id":"s1","cwd":"/repo/real","new_cwd":"/repo/bogus"}
        """#))
        XCTAssertEqual(record.rawCwd, "/repo/real")
    }

    func testRelativePathsAreRejected() throws {
        // Our cwd is not the session's, so a relative path is unresolvable.
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read",
         "tool_input":{"file_path":"src/a.swift"}}
        """#))
        XCTAssertTrue(record.files.isEmpty)
    }

    func testDuplicatePathsAreDeduplicatedPreservingOrder() throws {
        let record = try XCTUnwrap(parse(#"""
        {"hook_event_name":"FileChanged","session_id":"s1",
         "file_paths":["/repo/a","/repo/b","/repo/a"]}
        """#))
        XCTAssertEqual(record.files.map(\.path), ["/repo/a", "/repo/b"])
    }

    func testFilePathsAreCappedByLimits() throws {
        let paths = (0..<50).map { "\"/repo/f\($0)\"" }.joined(separator: ",")
        let record = try XCTUnwrap(
            ClaudeHookInputParser.parse(
                data: Data(#"{"hook_event_name":"FileChanged","session_id":"s1","file_paths":[\#(paths)]}"#.utf8),
                fallbackEvent: nil,
                timestamp: 1,
                limits: ClaudeHookLimits(maxFilePathsPerRecord: 3)
            )
        )
        XCTAssertEqual(record.files.count, 3)
    }

    func testParsedRecordCarriesCurrentWireVersion() throws {
        let record = try XCTUnwrap(parse(#"{"hook_event_name":"Stop","session_id":"s1"}"#))
        XCTAssertEqual(record.version, ClaudeHookWire.version)
    }
}
