import Foundation
import XCTest
@testable import ClaudeContextWire

// MARK: - Broker response shape

final class ClaudeBrokerResponseTests: XCTestCase {
    func testRoundTripsAMarker() throws {
        let line = try XCTUnwrap(
            ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(marker: "lvx-abcd1234"))
        )
        XCTAssertEqual(line.last, 0x0A, "the reply is one NDJSON line")
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
        XCTAssertEqual(decoded.marker, "lvx-abcd1234")
        XCTAssertEqual(decoded.version, ClaudeHookWire.version)
    }

    func testRoundTripsAnAbsentMarker() throws {
        let line = try XCTUnwrap(ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(marker: nil)))
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
        XCTAssertNil(decoded.marker)
    }

    func testRoundTripsTheAcceptanceVerdict() throws {
        for accepted in [true, false] {
            let line = try XCTUnwrap(
                ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(marker: nil, accepted: accepted))
            )
            let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
            XCTAssertEqual(decoded.accepted, accepted)
        }
    }

    func testNilAcceptanceEncodesNoKeyAndDecodesBackAsNil() throws {
        let line = try XCTUnwrap(ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(marker: nil)))
        XCTAssertFalse(
            String(decoding: line, as: UTF8.self).contains("accepted"),
            "nil must keep the key off the wire — its absence IS the pre-accepted-era shape"
        )
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
        XCTAssertNil(decoded.accepted)
    }

    func testPreAcceptedEraReplyStillDecodesWithNilAcceptance() throws {
        // A reply from a broker built before the field existed. It must keep
        // decoding, with `accepted == nil` — the compat promise the plugin's
        // settle-true fallback rests on. No version bump guards this; the
        // shape itself is the guarantee.
        let json = #"{"v":1,"marker":"lvx-abcd1234"}"#
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(Data(json.utf8)))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.marker, "lvx-abcd1234")
        XCTAssertNil(decoded.accepted)
    }

    func testRejectsForeignVersion() {
        let json = #"{"v":99,"marker":"lvx-abcd1234"}"#
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data(json.utf8)))
    }

    func testRejectsMalformedReply() {
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data("not json".utf8)))
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data()))
    }

    func testRejectsOversizedReply() {
        let json = #"{"v":1,"marker":"\#(String(repeating: "a", count: 500))"}"#
        XCTAssertNil(
            ClaudeBrokerResponse.decodeLine(Data(json.utf8), limits: ClaudeHookLimits(maxLineBytes: 64))
        )
    }
}

// MARK: - OSC safety

final class ClaudeMarkerSequenceTests: XCTestCase {
    func testValidMarkerProducesOSC2TitleSequence() throws {
        let sequence = try XCTUnwrap(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-abcd1234"))
        XCTAssertEqual(sequence, "\u{1B}]2;lvx-abcd1234\u{07}")
    }

    func testSequenceIsBoundedAndWellFormed() throws {
        let sequence = try XCTUnwrap(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-abcd1234"))
        XCTAssertTrue(sequence.hasPrefix("\u{1B}]2;"))
        XCTAssertTrue(sequence.hasSuffix("\u{07}"))
        XCTAssertLessThanOrEqual(sequence.utf8.count, ClaudeMarkerSequence.maxSequenceBytes)
    }

    // An escape sequence is code as much as data. A marker carrying BEL, ESC,
    // or a newline would terminate the sequence early and leave the rest to be
    // interpreted as further terminal commands — writing arbitrary control
    // bytes into the user's terminal. The allowlist is what prevents that, so
    // these are the tests that matter most in this file.

    func testRejectsMarkerContainingSequenceTerminator() {
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-ab\u{07}cd"))
    }

    func testRejectsMarkerContainingEscape() {
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-ab\u{1B}]0;pwned\u{07}"))
    }

    func testRejectsMarkerContainingNewline() {
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-ab\ncd"))
    }

    func testRejectsMarkerWithShellMetacharacters() {
        for marker in ["lvx-a;rm -rf /", "lvx-a$(id)", "lvx-a`id`", "lvx-a|b", "lvx-a b"] {
            XCTAssertNil(
                ClaudeMarkerSequence.windowTitleSequence(marker: marker),
                "\(marker) must not reach a terminal"
            )
        }
    }

    func testRejectsNonASCIIMarker() {
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-café"))
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "lvx-\u{202E}abc"))
    }

    func testRejectsMarkerWithoutOurPrefix() {
        // An allowlisted grammar, not merely "no control characters": we only
        // ever emit markers we minted.
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "abcd1234"))
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: "evil-abcd"))
    }

    func testRejectsEmptyAndOverlongMarkers() {
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: ""))
        let overlong = "lvx-" + String(repeating: "a", count: ClaudeMarkerSequence.maxMarkerLength)
        XCTAssertFalse(ClaudeMarkerSequence.isValidMarker(overlong))
        XCTAssertNil(ClaudeMarkerSequence.windowTitleSequence(marker: overlong))
    }

    func testAcceptsMarkersTheRegistryActuallyMints() {
        // The allowlist must not reject our own production marker grammar.
        XCTAssertTrue(ClaudeMarkerSequence.isValidMarker("lvx-00000000"))
        XCTAssertTrue(ClaudeMarkerSequence.isValidMarker("lvx-ffffffff"))
    }
}

// MARK: - Hook stdout

final class ClaudeHookOutputTests: XCTestCase {
    func testMarkerOutputIsValidJSONWithSuppressOutput() throws {
        let data = try XCTUnwrap(ClaudeHookOutput.markerOutputLine(marker: "lvx-abcd1234"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-abcd1234\u{07}")
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
        XCTAssertEqual(object.count, 2, "no field we did not intend to send")
    }

    func testOutputContainsNoRawNewline() throws {
        // Claude Code reads a hook's stdout as one JSON document. A literal
        // newline inside it would be at best ignored and at worst reparsed.
        let data = try XCTUnwrap(ClaudeHookOutput.markerOutputLine(marker: "lvx-abcd1234"))
        XCTAssertFalse(data.contains(0x0A))
    }

    func testNoMarkerMeansNoOutputAtAll() {
        // Nil means print NOTHING — not an empty object, not a newline. For
        // UserPromptSubmit, non-JSON stdout is appended to the user's prompt,
        // so silence is the only safe fallback.
        XCTAssertNil(ClaudeHookOutput.markerOutputLine(marker: nil))
    }

    func testUnsafeMarkerMeansNoOutputAtAll() {
        XCTAssertNil(ClaudeHookOutput.markerOutputLine(marker: "lvx-a\u{07}\u{1B}]0;pwned\u{07}"))
        XCTAssertNil(ClaudeHookOutput.markerOutputLine(marker: "not-ours"))
    }
}
