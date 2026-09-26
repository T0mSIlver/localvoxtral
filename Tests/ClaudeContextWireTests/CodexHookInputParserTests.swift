import ClaudeContextWire
import Foundation
import XCTest

/// Every payload here was recorded from Codex CLI 0.156.0 hooks on a real run
/// (`Tests/CodexHookPayloads/README.md`), not written by hand.
final class CodexHookInputParserTests: XCTestCase {
    static func payload(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("CodexHookPayloads/\(name).json"))
    }

    private func parse(_ name: String) throws -> ClaudeHookRecord? {
        CodexHookInputParser.parse(data: try Self.payload(name), timestamp: 1_700_000_000)
    }

    private let sessionID = "01a0dec1-c2ba-71b3-b640-a2568cef221b"
    private let cwd = "/home/dev/work/localvoxtral/.claude/worktrees/interesting-mirzakhani-907bab/.scratch/codex-probe/proj"

    func testTheHookedEventsMapOntoTheWire() throws {
        let expected: [(String, ClaudeHookEvent)] = [
            ("SessionStart", .sessionStart),
            ("UserPromptSubmit", .userPromptSubmit),
            ("PostToolUse-apply_patch", .postToolUse),
            ("Stop", .stop),
            ("SessionEnd", .sessionEnd),
        ]
        for (name, event) in expected {
            let record = try XCTUnwrap(try parse(name), name)
            XCTAssertEqual(record.event, event, name)
            XCTAssertEqual(record.agent, .codex, name)
            XCTAssertEqual(record.sessionID, sessionID, name)
            XCTAssertEqual(record.rawCwd, cwd, name)
            XCTAssertEqual(record.version, ClaudeHookWire.version, name)
        }
    }

    func testTheSubmittedPromptIsKept() throws {
        let record = try XCTUnwrap(try parse("UserPromptSubmit"))
        XCTAssertEqual(
            record.prompt,
            "Read notes.txt with a shell command, then use apply_patch to add a line 'gamma' at the end of notes.txt. Reply with one word: done."
        )
    }

    func testAPatchNamesTheFileItEdited() throws {
        let record = try XCTUnwrap(try parse("PostToolUse-apply_patch"))
        XCTAssertEqual(record.toolName, "apply_patch")
        XCTAssertEqual(record.files, [ClaudeFileTouch(path: "\(cwd)/notes.txt", kind: .edited)])
    }

    func testRelativePatchPathsResolveAgainstTheSessionsDirectory() throws {
        let record = try XCTUnwrap(try parse("PostToolUse-apply_patch-relative-add-move"))
        // `*** Update File: notes.txt` moved to `renamed.txt`: both names
        // count, the new one is what exists now.
        XCTAssertEqual(record.files, [
            ClaudeFileTouch(path: "\(cwd)/sub/new.txt", kind: .edited),
            ClaudeFileTouch(path: "\(cwd)/notes.txt", kind: .edited),
            ClaudeFileTouch(path: "\(cwd)/renamed.txt", kind: .edited),
        ])
    }

    func testAShellCommandNamesNoFile() throws {
        // Codex has no read tool: `cat notes.txt` is a Bash command, and a
        // command string is not ours to parse for paths.
        let record = try XCTUnwrap(try parse("PostToolUse-Bash"))
        XCTAssertEqual(record.toolName, "Bash")
        XCTAssertEqual(record.files, [])
    }

    func testASubagentsEditsCountForTheSession() throws {
        let record = try XCTUnwrap(try parse("subagent-PostToolUse-apply_patch"))
        XCTAssertEqual(record.sessionID, "01a0dec4-3d09-7f70-a49b-97c282cc58f0", "the parent's id")
        XCTAssertEqual(record.files.map(\.path), ["\(cwd)/notes.txt"])
    }

    func testEventsThePluginDoesNotPublishAreDropped() throws {
        for name in ["PreToolUse-apply_patch", "SubagentStart", "SubagentStop"] {
            XCTAssertNil(try parse(name), name)
        }
    }

    func testNothingButTheAllowlistCrossesTheWire() throws {
        for name in ["UserPromptSubmit", "PostToolUse-apply_patch", "PostToolUse-Bash", "Stop"] {
            let record = try XCTUnwrap(try parse(name), name)
            let line = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record), name)
            let text = String(decoding: line, as: UTF8.self)
            for dropped in ["transcript_path", "rollout-", "gpt-6", "bypassPermissions", "turn_id",
                            "*** Begin Patch", "+gamma", "alpha\\nbeta", "last_assistant_message"] {
                XCTAssertFalse(text.contains(dropped), "\(name) leaks \(dropped)")
            }
        }
    }

    func testASubagentPromptIsNotTheUsers() throws {
        // Recorded subagent payloads carry `agent_id` on every event they
        // raise; Codex raised no UserPromptSubmit for the subagent in the
        // recorded run, so this one is the recorded top-level prompt with the
        // subagent's `agent_id` from the same run added.
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Self.payload("UserPromptSubmit")) as? [String: Any]
        )
        let subagent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Self.payload("subagent-PostToolUse-apply_patch")) as? [String: Any]
        )
        payload["agent_id"] = subagent["agent_id"]
        payload["agent_type"] = subagent["agent_type"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(CodexHookInputParser.parse(data: data, timestamp: 0))
    }

    func testTheShippedHooksPublishExactlyTheEventsTheParserReads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "integrations/codex/plugins/localvoxtral/hooks/hooks.json"))
        let hooks = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]]
        )
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"])
        XCTAssertEqual(hooks["PostToolUse"]?.first?["matcher"] as? String, "apply_patch")
    }
}
