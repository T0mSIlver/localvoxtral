import Foundation
import XCTest
@testable import ClaudeContextWire

// MARK: - Wire decoding and caps

final class ClaudeHookWireCodecTests: XCTestCase {
    private func line(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }

    private func validJSON(
        version: Int = 2,
        event: String = "UserPromptSubmit",
        sessionID: String = "sess-1",
        extra: String = ""
    ) -> String {
        #"{"v":\#(version),"event":"\#(event)","session_id":"\#(sessionID)","ts":1000.5\#(extra)}"#
    }

    func testDecodesWellFormedRecord() throws {
        let record = try ClaudeHookWireCodec.decodeLine(
            line(validJSON(extra: #","cwd":"/repo","prompt":"fix the parser""#))
        )
        XCTAssertEqual(record.event, .userPromptSubmit)
        XCTAssertEqual(record.sessionID, "sess-1")
        XCTAssertEqual(record.timestamp, 1000.5)
        XCTAssertEqual(record.rawCwd, "/repo")
        XCTAssertEqual(record.prompt, "fix the parser")
    }

    func testRoundTripsThroughEncodeLine() throws {
        let original = ClaudeHookRecord(
            event: .postToolUse,
            sessionID: "sess-round",
            timestamp: 42.0,
            rawCwd: "/repo",
            toolName: "Edit",
            files: [ClaudeFileTouch(path: "/repo/a.swift", kind: .edited)],
            process: ClaudeHookProcessInfo(
                hookPID: 5, claudePID: 4, tty: "/dev/ttys001", termProgram: "ghostty"
            )
        )
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(original))
        XCTAssertEqual(encoded.last, 0x0A, "must be newline-terminated NDJSON")
        XCTAssertEqual(try ClaudeHookWireCodec.decodeLine(encoded), original)
    }

    func testHerdrProcessFieldsUseGoldenWireNamesAndDecode() throws {
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "sess-herdr",
            timestamp: 1.5,
            process: ClaudeHookProcessInfo(
                hookPID: 42,
                claudePID: 41,
                herdrPaneID: "pane-7",
                herdrSocketPath: "herdr.sock"
            )
        )

        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"event":"SessionStart","files":[],"process":{"claude_pid":41,"herdr_pane_id":"pane-7","herdr_socket_path":"herdr.sock","hook_pid":42},"session_id":"sess-herdr","ts":1.5,"v":2}"# + "\n"
        )
        let decoded = try ClaudeHookWireCodec.decodeLine(encoded)
        XCTAssertEqual(decoded.process?.herdrPaneID, "pane-7")
        XCTAssertEqual(decoded.process?.herdrSocketPath, "herdr.sock")
    }

    func testClampTruncatesBothHerdrProcessFields() {
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "s",
            timestamp: 1,
            process: ClaudeHookProcessInfo(
                hookPID: 2,
                claudePID: 1,
                herdrPaneID: String(repeating: "p", count: 20),
                herdrSocketPath: String(repeating: "s", count: 20)
            )
        )

        let clamped = ClaudeHookWireCodec.clamp(
            record,
            limits: ClaudeHookLimits(maxPathBytes: 5)
        )
        XCTAssertEqual(clamped.process?.herdrPaneID, "ppppp")
        XCTAssertEqual(clamped.process?.herdrSocketPath, "sssss")
    }

    func testCmuxAndBridgeProcessFieldsUseGoldenWireNamesAndDecode() throws {
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "sess-cmux",
            timestamp: 1.5,
            process: ClaudeHookProcessInfo(
                hookPID: 42,
                claudePID: 41,
                cmuxSurfaceID: "surface-3",
                cmuxSocketPath: "cmux.sock",
                bridgeSessionID: "bridge-abc"
            )
        )

        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"event":"SessionStart","files":[],"process":{"bridge_session_id":"bridge-abc","claude_pid":41,"cmux_socket_path":"cmux.sock","cmux_surface_id":"surface-3","hook_pid":42},"session_id":"sess-cmux","ts":1.5,"v":2}"# + "\n"
        )
        let decoded = try ClaudeHookWireCodec.decodeLine(encoded)
        XCTAssertEqual(decoded.process?.cmuxSurfaceID, "surface-3")
        XCTAssertEqual(decoded.process?.cmuxSocketPath, "cmux.sock")
        XCTAssertEqual(decoded.process?.bridgeSessionID, "bridge-abc")
    }

    func testClampTruncatesTheCmuxAndBridgeProcessFields() {
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "s",
            timestamp: 1,
            process: ClaudeHookProcessInfo(
                hookPID: 2,
                claudePID: 1,
                cmuxSurfaceID: String(repeating: "u", count: 20),
                cmuxSocketPath: String(repeating: "k", count: 20),
                bridgeSessionID: String(repeating: "b", count: 20)
            )
        )

        let clamped = ClaudeHookWireCodec.clamp(record, limits: ClaudeHookLimits(maxPathBytes: 5))
        XCTAssertEqual(clamped.process?.cmuxSurfaceID, "uuuuu")
        XCTAssertEqual(clamped.process?.cmuxSocketPath, "kkkkk")
        XCTAssertEqual(clamped.process?.bridgeSessionID, "bbbbb")
    }

    func testAWireLineWithoutTheCmuxAndBridgeFieldsIsUnchangedByThem() throws {
        // The compatibility property: an install running an older publisher
        // still sends lines with no such keys, and re-encoding one must not
        // invent them — a broker/publisher version skew is the normal state
        // during an update, not an edge case.
        let oldLine = line(
            #"{"event":"SessionStart","process":{"claude_pid":1,"herdr_pane_id":"pane-7","hook_pid":2},"session_id":"old","ts":1,"v":2}"#
        )
        let record = try ClaudeHookWireCodec.decodeLine(oldLine)
        XCTAssertEqual(record.process?.herdrPaneID, "pane-7")
        XCTAssertNil(record.process?.cmuxSurfaceID)
        XCTAssertNil(record.process?.cmuxSocketPath)
        XCTAssertNil(record.process?.bridgeSessionID)

        let reencoded = String(
            decoding: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)), as: UTF8.self
        )
        for key in ["cmux_surface_id", "cmux_socket_path", "bridge_session_id"] {
            XCTAssertFalse(reencoded.contains(key), "an absent field must stay absent")
        }
    }

    func testAbsentHerdrProcessFieldsDecodeAsNil() throws {
        let json = validJSON(
            event: "SessionStart",
            extra: #","process":{"hook_pid":2,"claude_pid":1}"#
        )
        let record = try ClaudeHookWireCodec.decodeLine(line(json))
        XCTAssertNil(record.process?.herdrPaneID)
        XCTAssertNil(record.process?.herdrSocketPath)
    }

    func testOldWireLineWithoutHerdrFieldsRemainsCompatible() throws {
        let oldLine = line(
            #"{"event":"SessionStart","process":{"claude_pid":1,"hook_pid":2,"term_program":"ghostty","tty":"device"},"session_id":"old","ts":1,"v":1}"#
        )
        let record = try ClaudeHookWireCodec.decodeLine(oldLine)
        XCTAssertEqual(record.process?.tty, "device")
        XCTAssertEqual(record.process?.termProgram, "ghostty")
        XCTAssertNil(record.process?.herdrPaneID)
        XCTAssertNil(record.process?.herdrSocketPath)

        let reencoded = String(decoding: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("herdr_pane_id"))
        XCTAssertFalse(reencoded.contains("herdr_socket_path"))
    }

    // MARK: Version gating

    func testRejectsFutureVersion() {
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(validJSON(version: 3)))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unsupportedVersion(3))
        }
    }

    func testRejectsMissingVersion() {
        let json = #"{"event":"Stop","session_id":"s","ts":1}"#
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(json))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unsupportedVersion(nil))
        }
    }

    // MARK: v1 compatibility and the agent field (wire v2)

    func testV1LineStillDecodesAndIsAClaudeRecordByConstruction() throws {
        // Every v1 record predates the agent field, and every v1 publisher was
        // the Claude Code hook — so v1 must keep decoding, as Claude.
        let record = try ClaudeHookWireCodec.decodeLine(line(validJSON(version: 1)))
        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.agent, .claude)
    }

    func testV2LineWithoutAgentFieldDefaultsToClaude() throws {
        let record = try ClaudeHookWireCodec.decodeLine(line(validJSON()))
        XCTAssertEqual(record.agent, .claude)
    }

    func testOpencodeAgentRoundTripsWithGoldenWireShape() throws {
        let record = ClaudeHookRecord(
            event: .userPromptSubmit,
            agent: .opencode,
            sessionID: "ses_0123",
            timestamp: 9.5,
            prompt: "rename the flag"
        )
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"agent":"opencode","event":"UserPromptSubmit","files":[],"prompt":"rename the flag","session_id":"ses_0123","ts":9.5,"v":2}"# + "\n"
        )
        XCTAssertEqual(try ClaudeHookWireCodec.decodeLine(encoded), record)
    }

    func testClaudeAgentIsOmittedFromTheWireSoV1ReadersStayCompatible() throws {
        let record = ClaudeHookRecord(event: .stop, sessionID: "s", timestamp: 1)
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains("agent"),
            "absence is the default: a Claude record must not grow an agent key"
        )
    }

    func testRejectsUnknownAgentPreciselyRatherThanDefaultingToClaude() {
        // Defaulting would hand a future agent Claude's channel rules (title
        // markers, bare session-id namespace). Ignored, precisely.
        XCTAssertThrowsError(
            try ClaudeHookWireCodec.decodeLine(line(validJSON(extra: #","agent":"aider""#)))
        ) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unknownAgent("aider"))
        }
        XCTAssertThrowsError(
            try ClaudeHookWireCodec.decodeLine(line(validJSON(extra: #","agent":7"#)))
        ) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unknownAgent(nil))
        }
    }

    func testV1LineCarryingAnExplicitAgentKeyIsMalformed() {
        // No v1 writer ever emitted the key — "absent = claude" IS the v1
        // contract. A v1 line carrying it is hand-crafted, not old.
        XCTAssertThrowsError(
            try ClaudeHookWireCodec.decodeLine(
                line(validJSON(version: 1, extra: #","agent":"claude""#))
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .malformed)
        }
    }

    func testFocusClearedEventDecodes() throws {
        let json = validJSON(
            event: "FocusCleared",
            extra: #","agent":"opencode","process":{"hook_pid":9,"claude_pid":9,"tty":"/dev/ttys004"}"#
        )
        let record = try ClaudeHookWireCodec.decodeLine(line(json))
        XCTAssertEqual(record.event, .focusCleared)
        XCTAssertEqual(record.agent, .opencode)
    }

    func testFocusChangedEventDecodes() throws {
        let json = validJSON(
            event: "FocusChanged",
            extra: #","agent":"opencode","process":{"hook_pid":9,"claude_pid":9,"tty":"/dev/ttys004"}"#
        )
        let record = try ClaudeHookWireCodec.decodeLine(line(json))
        XCTAssertEqual(record.event, .focusChanged)
        XCTAssertEqual(record.agent, .opencode)
        XCTAssertEqual(record.process?.tty, "/dev/ttys004")
    }

    // MARK: Session-id namespacing per agent

    func testOpencodeSessionIDsAreScopedAndClaudeIDsStayBare() {
        XCTAssertEqual(
            ClaudeAgentSessionScope.scopedSessionID(agent: .opencode, sessionID: "ses_1"),
            "opencode:ses_1"
        )
        XCTAssertEqual(
            ClaudeAgentSessionScope.scopedSessionID(agent: .claude, sessionID: "b81c2a"),
            "b81c2a"
        )
        // The two receiver-side namespaces must never alias each other.
        XCTAssertNotEqual(ClaudeAgentSessionScope.opencodePrefix, "remote:")
    }

    func testRejectsUnknownEventRatherThanThrowingGenericError() {
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(validJSON(event: "PreCompact")))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unknownEvent("PreCompact"))
        }
    }

    func testRejectsEmptySessionID() {
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(validJSON(sessionID: "")))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .missingSessionID)
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line("{not json"))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .malformed)
        }
    }

    // MARK: Caps — the broker re-applies them, never trusting the sender

    func testRejectsOverlongLine() {
        let limits = ClaudeHookLimits(maxLineBytes: 32)
        let long = line(validJSON(extra: #","prompt":"\#(String(repeating: "x", count: 200))""#))
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(long, limits: limits)) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .lineTooLong(bytes: long.count))
        }
    }

    func testDecodeClampsPromptEvenWhenSenderDidNot() throws {
        let limits = ClaudeHookLimits(maxLineBytes: 64 * 1024, maxPromptBytes: 10)
        let json = validJSON(extra: #","prompt":"\#(String(repeating: "a", count: 500))""#)
        let record = try ClaudeHookWireCodec.decodeLine(line(json), limits: limits)
        XCTAssertEqual(record.prompt?.utf8.count, 10)
    }

    func testDecodeClampsFileListLength() throws {
        let limits = ClaudeHookLimits(maxFilePathsPerRecord: 2)
        let files = (0..<10).map { #"{"path":"/repo/f\#($0)","kind":"read"}"# }.joined(separator: ",")
        let json = validJSON(event: "PostToolUse", extra: #","files":[\#(files)]"#)
        let record = try ClaudeHookWireCodec.decodeLine(line(json), limits: limits)
        XCTAssertEqual(record.files.count, 2)
        XCTAssertEqual(record.files.map(\.path), ["/repo/f0", "/repo/f1"])
    }

    func testEncodeReturnsNilWhenRecordCannotFitLineCap() {
        // maxPromptBytes lets the prompt through, but the whole line still
        // blows the line cap: drop rather than emit a truncated, unparseable
        // object.
        let limits = ClaudeHookLimits(maxLineBytes: 40, maxPromptBytes: 4096)
        let record = ClaudeHookRecord(
            event: .userPromptSubmit,
            sessionID: "s",
            timestamp: 1,
            prompt: String(repeating: "x", count: 1000)
        )
        XCTAssertNil(ClaudeHookWireCodec.encodeLine(record, limits: limits))
    }

    func testTruncationKeepsValidUTF8OnMultiByteBoundary() {
        // "é" is 2 bytes: a byte-slice cut at 5 would split the third one and
        // produce an invalid string.
        let value = String(repeating: "é", count: 10)
        let truncated = ClaudeHookWireCodec.truncate(value, toUTF8Bytes: 5)
        XCTAssertEqual(truncated, "éé", "must cut on a character boundary")
        XCTAssertLessThanOrEqual(truncated.utf8.count, 5)
    }

    func testTruncateLeavesShortValueUntouched() {
        XCTAssertEqual(ClaudeHookWireCodec.truncate("abc", toUTF8Bytes: 10), "abc")
    }

    // MARK: Trust is not a field

    func testOriginFieldOnTheWireIsIgnoredAndCannotUpgradeTrust() throws {
        // A hostile publisher declaring itself local must gain nothing: the
        // decoded record has no origin at all, so the broker's peer-credential
        // verdict is the only source of trust.
        let json = validJSON(extra: #","origin":"localAuthenticated","trusted":true,"peer_uid":0"#)
        let record = try ClaudeHookWireCodec.decodeLine(line(json))
        XCTAssertEqual(record.sessionID, "sess-1")

        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("origin"))
        XCTAssertFalse(text.contains("trusted"))
        XCTAssertFalse(text.contains("peer_uid"))
    }

    func testTranscriptPathNeverSurvivesDecoding() throws {
        let json = validJSON(extra: #","transcript_path":"/tmp/transcript.jsonl""#)
        let record = try ClaudeHookWireCodec.decodeLine(line(json))
        let encoded = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("transcript"))
    }
}

// MARK: - Stream framing

final class ClaudeHookWireSplitLinesTests: XCTestCase {
    func testSplitsCompleteLines() {
        let (lines, remainder) = ClaudeHookWireCodec.splitLines(Data("a\nb\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        XCTAssertTrue(remainder.isEmpty)
    }

    func testHoldsPartialLineAsRemainder() {
        let (lines, remainder) = ClaudeHookWireCodec.splitLines(Data("a\npartial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["a"])
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "partial")
    }

    func testReassemblesAcrossArbitraryChunkBoundaries() {
        // A stream socket may deliver a record in any number of pieces.
        var pending = Data()
        var collected: [String] = []
        for chunk in ["{\"a\":", "1}\n{\"b\"", ":2}\n"] {
            pending.append(Data(chunk.utf8))
            let (lines, remainder) = ClaudeHookWireCodec.splitLines(pending)
            pending = remainder
            collected.append(contentsOf: lines.map { String(decoding: $0, as: UTF8.self) })
        }
        XCTAssertEqual(collected, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testEmptyBufferYieldsNothing() {
        let (lines, remainder) = ClaudeHookWireCodec.splitLines(Data())
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(remainder.isEmpty)
    }
}
