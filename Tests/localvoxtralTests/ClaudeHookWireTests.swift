import Foundation
import XCTest
@testable import ClaudeContextWire

// MARK: - Wire decoding and caps

final class ClaudeHookWireCodecTests: XCTestCase {
    private func line(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }

    private func validJSON(
        version: Int = 1,
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

    // MARK: Version gating

    func testRejectsFutureVersion() {
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(validJSON(version: 2)))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unsupportedVersion(2))
        }
    }

    func testRejectsMissingVersion() {
        let json = #"{"event":"Stop","session_id":"s","ts":1}"#
        XCTAssertThrowsError(try ClaudeHookWireCodec.decodeLine(line(json))) { error in
            XCTAssertEqual(error as? ClaudeHookWireError, .unsupportedVersion(nil))
        }
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
