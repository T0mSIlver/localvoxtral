import Foundation
import XCTest
@testable import ClaudeContextWire

// MARK: - Broker response shape

final class ClaudeBrokerResponseTests: XCTestCase {
    func testRoundTripsTheVersion() throws {
        let line = try XCTUnwrap(ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse()))
        XCTAssertEqual(line.last, 0x0A, "the reply is one NDJSON line")
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
        XCTAssertEqual(decoded.version, ClaudeHookWire.version)
    }

    func testRoundTripsTheAcceptanceVerdict() throws {
        for accepted in [true, false] {
            let line = try XCTUnwrap(
                ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(accepted: accepted))
            )
            let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
            XCTAssertEqual(decoded.accepted, accepted)
        }
    }

    func testNilAcceptanceEncodesNoKeyAndDecodesBackAsNil() throws {
        let line = try XCTUnwrap(ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse()))
        XCTAssertFalse(
            String(decoding: line, as: UTF8.self).contains("accepted"),
            "nil must keep the key off the wire — its absence IS the pre-accepted-era shape"
        )
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(line.dropLast()))
        XCTAssertNil(decoded.accepted)
    }

    func testTheReplyCarriesOnlyVersionAndAcceptance() throws {
        // The whole reply vocabulary, asserted as a key set rather than as
        // prose. A key here is something a publisher could act on, and the
        // publisher must have nothing to act on: it prints nothing on every
        // hook path.
        let line = try XCTUnwrap(
            ClaudeBrokerResponse.encodeLine(ClaudeBrokerResponse(accepted: true))
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["v", "accepted"])
    }

    func testPreAcceptedEraReplyStillDecodesWithNilAcceptance() throws {
        // A reply from a broker built before the field existed. It must keep
        // decoding, with `accepted == nil` — the compat promise the plugin's
        // settle-true fallback rests on. No version bump guards this; the
        // shape itself is the guarantee.
        let json = #"{"v":1}"#
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(Data(json.utf8)))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.accepted)
    }

    func testAMarkerEraReplyStillDecodesAndTheMarkerIsSimplyGone() throws {
        // The compatibility argument for removing `marker` WITHOUT a wire
        // version bump, in the direction that actually ships: an app built
        // before the removal (or a hand-written reply from one) still decodes
        // here, and its now-unknown key is ignored by synthesized Codable.
        // The mirror direction — an already-installed publisher decoding a
        // reply that OMITS the key — is what `marker: String?` always allowed,
        // and it finds no marker, which is the "print nothing" path it has
        // taken by default on every install since the title fallback shipped
        // switched off.
        let json = #"{"accepted":true,"marker":"lvx-abcd1234","v":2}"#
        let decoded = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(Data(json.utf8)))
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.accepted, true)
    }

    func testRejectsForeignVersion() {
        let json = #"{"v":99}"#
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data(json.utf8)))
    }

    func testRejectsMalformedReply() {
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data("not json".utf8)))
        XCTAssertNil(ClaudeBrokerResponse.decodeLine(Data()))
    }

    func testRejectsOversizedReply() {
        let json = #"{"v":1,"pad":"\#(String(repeating: "a", count: 500))"}"#
        XCTAssertNil(
            ClaudeBrokerResponse.decodeLine(Data(json.utf8), limits: ClaudeHookLimits(maxLineBytes: 64))
        )
    }
}

// MARK: - Hook stdout

final class ClaudeHookOutputTests: XCTestCase {
    func testTheOutputTypeCarriesExactlySuppressOutput() throws {
        // The key allowlist is a property of the TYPE, so this asserts the
        // type rather than a filter. Claude Code executes what it finds in a
        // hook's stdout: an extra key would at best be ignored and at worst be
        // a control channel. In particular there must be no field that can put
        // an escape sequence on a terminal.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ClaudeHookOutput())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["suppressOutput"])
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
    }
}
