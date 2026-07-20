import ClaudeContextWire
import Foundation
import XCTest

/// Parsing what a remote Claude Code actually POSTs.
///
/// The fixtures are shaped like real hook payloads, including the parts we
/// deliberately throw away. The assertions about what is ABSENT matter more than
/// the ones about what is present: this parser is the only thing standing
/// between a remote host's transcript and our process.
final class ClaudeRemoteHookPayloadTests: XCTestCase {
    private let timestamp: Double = 1_700_000_000

    private func parse(_ payload: [String: Any], fallbackEvent: String? = nil) -> ClaudeRemoteHookPayloadParser.Payload? {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return ClaudeRemoteHookPayloadParser.parse(
            data: data,
            fallbackEvent: fallbackEvent,
            timestamp: timestamp
        )
    }

    // MARK: Records

    func testParsesAUserPromptSubmitPayload() throws {
        let payload = parse([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "abc-123",
            "cwd": "/home/dev/work/service",
            "prompt": "fix the retry loop in RealtimeClient",
            "transcript_path": "/home/dev/.claude/projects/x/transcript.jsonl",
        ])
        let record = try XCTUnwrap(payload?.record)
        XCTAssertEqual(record.event, .userPromptSubmit)
        XCTAssertEqual(record.sessionID, "abc-123")
        XCTAssertEqual(record.prompt, "fix the retry loop in RealtimeClient")
        XCTAssertEqual(record.rawCwd, "/home/dev/work/service")
        XCTAssertEqual(record.timestamp, timestamp)
        XCTAssertTrue(payload?.snippets.isEmpty == true, "a prompt is not a tool snippet")
    }

    func testTheURLPathSuppliesTheEventWhenThePayloadOmitsIt() throws {
        let payload = parse(["session_id": "abc-123"], fallbackEvent: "Stop")
        XCTAssertEqual(payload?.record.event, .stop)
    }

    func testPayloadEventWinsOverTheURLPath() throws {
        // The URL is chosen by a manifest; the payload is what Claude Code
        // actually did. A mismatch means the manifest is wrong, and following
        // the payload is the one that stays correct.
        let payload = parse(
            ["hook_event_name": "Stop", "session_id": "abc-123"],
            fallbackEvent: "SessionStart"
        )
        XCTAssertEqual(payload?.record.event, .stop)
    }

    func testUnusablePayloadsYieldNothing() {
        XCTAssertNil(parse(["hook_event_name": "SessionStart"]), "no session id")
        XCTAssertNil(parse(["hook_event_name": "SessionStart", "session_id": ""]), "empty session id")
        XCTAssertNil(parse(["hook_event_name": "Telepathy", "session_id": "a"]), "unknown event")
        XCTAssertNil(parse(["session_id": "a"]), "no event anywhere")
        XCTAssertNil(
            ClaudeRemoteHookPayloadParser.parse(
                data: Data("not json".utf8), fallbackEvent: "Stop", timestamp: timestamp
            )
        )
    }

    func testAPayloadCannotDescribeItselfAsTrusted() throws {
        // Trust is a property of the transport. There is no wire key for it, so
        // an `origin` in the payload is just a key nobody reads — and this test
        // is what keeps it that way if someone adds one to the record type.
        let payload = parse([
            "hook_event_name": "SessionStart",
            "session_id": "abc-123",
            "origin": "localAuthenticated",
            "trusted": true,
            "peer_uid": 501,
        ])
        let record = try XCTUnwrap(payload?.record)
        let encoded = try JSONEncoder().encode(record)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("localAuthenticated"))
        XCTAssertFalse(text.contains("trusted"))
        XCTAssertFalse(text.contains("peer_uid"))
    }

    func testTranscriptPathIsNeverCarried() throws {
        let payload = parse([
            "hook_event_name": "SessionStart",
            "session_id": "abc-123",
            "transcript_path": "/home/dev/.claude/projects/x/transcript.jsonl",
        ])
        let encoded = try JSONEncoder().encode(try XCTUnwrap(payload?.record))
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains("transcript"),
            "we do not scrape transcripts, so we do not carry the pointer either"
        )
    }

    // MARK: Snippets

    private func postToolUse(
        tool: String,
        input: [String: Any] = [:],
        response: Any? = nil
    ) -> ClaudeRemoteHookPayloadParser.Payload? {
        var payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": "abc-123",
            "cwd": "/srv/app",
            "tool_name": tool,
            "tool_input": input,
        ]
        if let response { payload["tool_response"] = response }
        return parse(payload)
    }

    func testEditToolInputBecomesSnippets() throws {
        let payload = try XCTUnwrap(postToolUse(
            tool: "Edit",
            input: [
                "file_path": "/srv/app/Sources/RetryPolicy.swift",
                "old_string": "maxAttempts = 3",
                "new_string": "maxAttempts = 5",
            ]
        ))
        XCTAssertEqual(
            payload.snippets,
            [
                ClaudeContentSnippet(label: "Edit new_string", kind: .toolInput, text: "maxAttempts = 5"),
                ClaudeContentSnippet(label: "Edit old_string", kind: .toolInput, text: "maxAttempts = 3"),
            ],
            "new_string first: what the code says NOW is the better grounding"
        )
        XCTAssertEqual(
            payload.record.files,
            [ClaudeFileTouch(path: "/srv/app/Sources/RetryPolicy.swift", kind: .edited)]
        )
    }

    func testWriteContentBecomesASnippet() throws {
        let payload = try XCTUnwrap(postToolUse(
            tool: "Write",
            input: ["file_path": "/srv/app/README.md", "content": "# Service\n\nA thing."]
        ))
        XCTAssertEqual(payload.snippets.count, 1)
        XCTAssertEqual(payload.snippets[0].kind, .toolInput)
        XCTAssertEqual(payload.snippets[0].text, "# Service A thing.")
    }

    func testReadResponseBecomesASnippetInBothResponseShapes() throws {
        let asString = try XCTUnwrap(postToolUse(
            tool: "Read", input: ["file_path": "/srv/app/x.swift"], response: "let x = 1"
        ))
        XCTAssertEqual(
            asString.snippets,
            [ClaudeContentSnippet(label: "Read response", kind: .toolOutput, text: "let x = 1")]
        )

        let nested = try XCTUnwrap(postToolUse(
            tool: "Read",
            input: ["file_path": "/srv/app/x.swift"],
            response: ["file": ["filePath": "/srv/app/x.swift", "content": "let y = 2"]]
        ))
        XCTAssertEqual(
            nested.snippets,
            [ClaudeContentSnippet(label: "Read file", kind: .toolOutput, text: "let y = 2")]
        )
    }

    func testOnlyToolEventsProduceSnippets() throws {
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "CwdChanged"] {
            let payload = parse([
                "hook_event_name": event,
                "session_id": "abc-123",
                "tool_input": ["content": "should not appear"],
                "tool_response": "nor this",
            ])
            XCTAssertEqual(payload?.snippets, [], "\(event) must carry no snippets")
        }
    }

    func testSnippetsAreCappedPerRecord() throws {
        let payload = try XCTUnwrap(postToolUse(
            tool: "Edit",
            input: ["old_string": "a", "new_string": "b", "content": "c"],
            response: ["content": "d", "stdout": "e", "output": "f"]
        ))
        XCTAssertEqual(payload.snippets.count, ClaudeSnippetLimits.default.maxSnippetsPerRecord)
    }

    func testSnippetTextIsBounded() throws {
        // Well under the payload cap, so this exercises the SNIPPET bound rather
        // than the whole-body one the next test covers.
        let long = String(repeating: "x", count: 8 * 1024)
        let payload = try XCTUnwrap(postToolUse(tool: "Write", input: ["content": long]))
        XCTAssertEqual(payload.snippets.count, 1)
        XCTAssertEqual(
            payload.snippets[0].text.utf8.count,
            ClaudeSnippetLimits.default.maxSnippetBytes
        )
    }

    func testAnOversizedBodyIsNotParsedAtAll() {
        let huge = String(repeating: "x", count: ClaudeHookLimits.default.maxLineBytes * 2)
        let data = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse", "session_id": "a", "tool_input": ["content": huge],
        ])
        XCTAssertNil(
            ClaudeRemoteHookPayloadParser.parse(data: data, fallbackEvent: nil, timestamp: 0),
            "the bound is on the payload, not on what we choose to keep from it"
        )
    }

    func testNonStringToolValuesAreIgnoredRatherThanCoerced() throws {
        let payload = try XCTUnwrap(postToolUse(
            tool: "Edit",
            input: ["new_string": 42, "old_string": ["nested": "object"]],
            response: ["content": [1, 2, 3]]
        ))
        XCTAssertEqual(payload.snippets, [])
    }

    func testEmptyValuesProduceNoSnippet() throws {
        let payload = try XCTUnwrap(postToolUse(tool: "Write", input: ["content": "   \n\t  "]))
        XCTAssertEqual(payload.snippets, [], "whitespace is not context")
    }

    // MARK: Sanitization

    /// Snippets are foreign text written by a model on a machine we do not
    /// control, and they end up in a prompt and potentially near a terminal.
    func testControlCharactersAreStrippedFromSnippets() throws {
        let hostile = "before\u{1B}]0;pwned\u{07}after\u{9B}31mred\u{202E}reversed\u{200B}zero"
        let payload = try XCTUnwrap(postToolUse(tool: "Write", input: ["content": hostile]))
        let text = payload.snippets[0].text
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B }, "no ESC")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x07 }, "no BEL")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x9B }, "no C1 CSI")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x202E }, "no bidi override")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x200B }, "no zero-width")
        XCTAssertEqual(text, "before]0;pwnedafter31mredreversedzero")
    }

    func testLabelsAreSanitizedToo() throws {
        // The tool name is attacker-influenced in exactly the same way the text
        // is; a label is not automatically safe for being short.
        let payload = try XCTUnwrap(postToolUse(
            tool: "Ed\u{1B}]2;pwned\u{07}it", input: ["content": "x"]
        ))
        XCTAssertFalse(payload.snippets[0].label.unicodeScalars.contains { $0.value == 0x1B })
    }

    func testNewlinesAndTabsBecomeSpacesRatherThanVanishing() {
        // Dropping them would fuse the words on either side into a nonsense
        // token, which is worse than useless for grounding.
        XCTAssertEqual(
            ClaudeTextSanitizer.sanitize("let a = 1\nlet b = 2\t\tdone", maxBytes: 512),
            "let a = 1 let b = 2 done"
        )
    }

    func testSanitizerCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(ClaudeTextSanitizer.sanitize("  a     b  ", maxBytes: 512), "a b")
        XCTAssertEqual(ClaudeTextSanitizer.sanitize("\n\n\n", maxBytes: 512), "")
        XCTAssertEqual(ClaudeTextSanitizer.sanitize("", maxBytes: 512), "")
    }

    func testSanitizerTruncatesOnACharacterBoundary() {
        // A byte-slice truncation could split a multi-byte scalar and produce a
        // string that fails to encode.
        let text = ClaudeTextSanitizer.sanitize(String(repeating: "é", count: 100), maxBytes: 11)
        XCTAssertLessThanOrEqual(text.utf8.count, 11)
        XCTAssertEqual(text, String(repeating: "é", count: 5))
    }

    func testSanitizerKeepsTheCharactersGroundingActuallyNeeds() {
        // Identifiers, paths, and punctuation are the whole point.
        let source = "func retry(_ x: Int) -> Bool { /* ok */ return x > 0 } // path/to/File.swift"
        XCTAssertEqual(ClaudeTextSanitizer.sanitize(source, maxBytes: 512), source)
        XCTAssertEqual(ClaudeTextSanitizer.sanitize("café — naïve 日本語", maxBytes: 512), "café — naïve 日本語")
    }

    // MARK: Session scoping

    func testSessionScopeNamespacesByHost() {
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "habc", sessionID: "s-1")
        XCTAssertEqual(scoped, "remote:habc:s-1")
        XCTAssertTrue(ClaudeRemoteSessionScope.isScoped(scoped))
        XCTAssertFalse(ClaudeRemoteSessionScope.isScoped("s-1"), "a bare Claude session id is local")
    }

    func testTwoHostsCannotCollideOnTheSameSessionID() {
        XCTAssertNotEqual(
            ClaudeRemoteSessionScope.scopedSessionID(hostID: "hAAA", sessionID: "same"),
            ClaudeRemoteSessionScope.scopedSessionID(hostID: "hBBB", sessionID: "same")
        )
    }

    func testAHostCannotForgeAnotherHostsScopedID() {
        // A payload claiming session_id "remote:hBBB:victim" from host A gets
        // scoped again under A, landing in A's namespace — not B's.
        let forged = ClaudeRemoteSessionScope.scopedSessionID(
            hostID: "hAAA",
            sessionID: "remote:hBBB:victim"
        )
        XCTAssertEqual(forged, "remote:hAAA:remote:hBBB:victim")
        XCTAssertNotEqual(
            forged,
            ClaudeRemoteSessionScope.scopedSessionID(hostID: "hBBB", sessionID: "victim")
        )
    }

    func testChannelsIdentifyTheHost() {
        XCTAssertEqual(ClaudeRemoteSessionScope.channel(hostID: "habc"), "ssh:habc")
        XCTAssertNotEqual(
            ClaudeRemoteSessionScope.channel(hostID: "hAAA"),
            ClaudeRemoteSessionScope.channel(hostID: "hBBB")
        )
    }
}
