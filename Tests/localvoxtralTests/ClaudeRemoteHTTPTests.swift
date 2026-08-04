import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The bounded HTTP parser, against the bytes a hostile peer would send.
///
/// This parser is the app's only network-facing surface. Everything it accepts,
/// the listener will act on; everything it mis-frames is a request smuggled past
/// the auth check. So the fixtures below are deliberately unfriendly.
final class ClaudeRemoteHTTPTests: XCTestCase {
    private func request(
        method: String = "POST",
        target: String = "/v1/hook/SessionStart",
        version: String = "HTTP/1.1",
        headers: [String] = ["Content-Length: 2"],
        body: String = "{}"
    ) -> Data {
        var text = "\(method) \(target) \(version)\r\n"
        for header in headers { text += header + "\r\n" }
        text += "\r\n"
        return Data(text.utf8) + Data(body.utf8)
    }

    // MARK: Happy path

    func testParsesAWellFormedHookPost() throws {
        let raw = request(headers: [
            "Host: 127.0.0.1:8473",
            "Content-Type: application/json",
            "Authorization: Bearer abc123abc123abc123",
            "Content-Length: 2",
        ])
        let (parsed, bodyOffset) = try ClaudeRemoteHTTPCodec.parseRequestHead(raw)
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/hook/SessionStart")
        XCTAssertEqual(parsed.contentLength, 2)
        XCTAssertEqual(parsed.bearerToken, "abc123abc123abc123")
        XCTAssertEqual(Data(raw[bodyOffset...]), Data("{}".utf8))
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let raw = request(headers: ["AUTHORIZATION: Bearer abc123abc123abc123", "content-LENGTH: 2"])
        let (parsed, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(raw)
        XCTAssertEqual(parsed.bearerToken, "abc123abc123abc123")
        XCTAssertEqual(parsed.contentLength, 2)
    }

    func testQueryStringIsStrippedFromThePath() throws {
        let raw = request(target: "/v1/hook/Stop?retry=1")
        let (parsed, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(raw)
        XCTAssertEqual(parsed.path, "/v1/hook/Stop")
    }

    // MARK: Incremental reads

    func testAnIncompleteHeadAsksForMoreBytesRatherThanFailing() {
        let partial = Data("POST /v1/hook/Stop HTTP/1.1\r\nContent-Len".utf8)
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(partial)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .incompleteHead)
        }
    }

    func testAnIncompleteHeadThatIsAlreadyOversizedIsRejected() {
        // The slowloris shape: never terminate the head, just keep sending. The
        // cap has to apply to the INCOMPLETE case or it never applies at all.
        let flood = Data("POST /v1/hook/Stop HTTP/1.1\r\n".utf8)
            + Data(repeating: 0x41, count: 16 * 1024)
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(flood)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .headTooLarge)
        }
    }

    func testHeadOverTheCapIsRejectedEvenWhenComplete() {
        let padding = String(repeating: "x", count: 9 * 1024)
        let raw = request(headers: ["X-Pad: \(padding)", "Content-Length: 2"])
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .headTooLarge)
        }
    }

    // MARK: Framing

    func testOnlyPOSTIsAccepted() {
        for method in ["GET", "PUT", "DELETE", "OPTIONS"] {
            let raw = request(method: method)
            XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
                XCTAssertEqual(error as? ClaudeRemoteHTTPError, .unsupportedMethod(method))
            }
        }
    }

    func testMissingContentLengthIsRejected() {
        let raw = request(headers: ["Host: 127.0.0.1"])
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .lengthRequired)
        }
    }

    func testOversizedContentLengthIsRejectedBeforeAnyBodyIsRead() {
        // The bound is on the DECLARED length, checked while parsing the head.
        // That is what makes it impossible for a peer to size an allocation:
        // by the time we would read the body, we have already refused.
        let raw = request(headers: ["Content-Length: 1048576"], body: "")
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .bodyTooLarge(1_048_576))
        }
    }

    func testChunkedTransferEncodingIsRejected() {
        // A chunked body's size is only knowable by reading it, which defeats
        // the point of a declared bound.
        let raw = request(headers: ["Transfer-Encoding: chunked"], body: "")
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .unsupportedTransferEncoding)
        }
    }

    func testDuplicateHeadersAreRejectedRatherThanMerged() {
        // Two Content-Lengths is the classic request-smuggling primitive: sender
        // and receiver pick different ones and disagree about where the body
        // ends. Refusing needs no tie-break rule.
        let raw = request(headers: ["Content-Length: 2", "Content-Length: 40"])
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .malformed)
        }
        let twoAuths = request(headers: [
            "Authorization: Bearer aaaaaaaaaaaaaaaaaa",
            "Authorization: Bearer bbbbbbbbbbbbbbbbbb",
            "Content-Length: 2",
        ])
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(twoAuths)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .malformed)
        }
    }

    func testBareLFLineEndingsAreRejected() {
        // Tolerating them would mean two parsers could disagree about where a
        // header ends.
        let raw = Data("POST /v1/hook/Stop HTTP/1.1\nContent-Length: 2\n\n{}".utf8)
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .incompleteHead)
        }
    }

    func testNonNumericContentLengthIsRejected() {
        // `Int("+2")` is 2, so a permissive parse would frame a body the sender
        // measured differently. Digits only.
        for value in ["+2", "-2", "0x2", "2, 40", "two", ""] {
            let raw = request(headers: ["Content-Length: \(value)"])
            XCTAssertThrowsError(
                try ClaudeRemoteHTTPCodec.parseRequestHead(raw),
                "Content-Length: '\(value)' must not parse"
            )
        }
    }

    func testSurroundingWhitespaceInAHeaderValueIsTolerated() throws {
        // OWS around a field value is legal HTTP and OpenSSH-adjacent clients do
        // emit it; rejecting it would fail-open for no security gain.
        let raw = request(headers: ["Content-Length:  2 ", "Authorization:  Bearer abc123abc123abc123 "])
        let (parsed, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(raw)
        XCTAssertEqual(parsed.contentLength, 2)
        XCTAssertEqual(parsed.bearerToken, "abc123abc123abc123")
    }

    func testOnlyASCIIOWSIsTrimmedFromNamesAndValues() throws {
        // Review finding: `trimmingCharacters(in: .whitespaces)` is a UNICODE
        // set. It ate U+00A0 and friends, which laundered a malformed wire
        // value into a well-formed one before any byte-level validator could
        // see it — and, worse, rewrote the field NAME, so `Content-Length<NBSP>`
        // parsed as a Content-Length here while a conforming proxy would read
        // something else. RFC 9110 OWS is `*( SP / HTAB )` and nothing more.
        let padded = Data(
            "POST /v1/hook/Stop HTTP/1.1\r\nX-Thing: pane-7\u{A0}\r\nContent-Length: 2\r\n\r\n{}".utf8
        )
        let (parsed, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(padded)
        XCTAssertEqual(
            parsed.headers["x-thing"], "pane-7\u{A0}",
            "a non-ASCII pad is part of the value, not whitespace to discard"
        )

        // Tab is OWS and still goes.
        let tabbed = Data(
            "POST /v1/hook/Stop HTTP/1.1\r\nX-Thing:\tvalue\t\r\nContent-Length: 2\r\n\r\n{}".utf8
        )
        XCTAssertEqual(try ClaudeRemoteHTTPCodec.parseRequestHead(tabbed).request.headers["x-thing"], "value")

        // And the name is no longer rewritten: a NBSP-suffixed Content-Length
        // is a different header, so the required one is simply absent.
        let paddedName = Data(
            "POST /v1/hook/Stop HTTP/1.1\r\nContent-Length\u{A0}: 2\r\n\r\n{}".utf8
        )
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(paddedName)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .lengthRequired)
        }
    }

    func testHeaderFoldingIsRejected() {
        let raw = Data(
            "POST /v1/hook/Stop HTTP/1.1\r\nX-Thing: a\r\n  continued\r\nContent-Length: 2\r\n\r\n{}".utf8
        )
        XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHTTPError, .malformed)
        }
    }

    func testGarbageRequestLineIsRejected() {
        for line in ["POST\r\n", "POST /x\r\n", "POST /x HTTP/9.9\r\n", "\r\n"] {
            let raw = Data((line + "Content-Length: 0\r\n\r\n").utf8)
            XCTAssertThrowsError(try ClaudeRemoteHTTPCodec.parseRequestHead(raw), "'\(line)' must not parse")
        }
    }

    // MARK: Bearer

    func testBearerTokenExtraction() {
        XCTAssertEqual(ClaudeRemoteHTTPCodec.bearerToken(in: "Bearer abc"), "abc")
        XCTAssertEqual(ClaudeRemoteHTTPCodec.bearerToken(in: "bearer abc"), "abc")
        XCTAssertEqual(ClaudeRemoteHTTPCodec.bearerToken(in: "BEARER abc"), "abc")
        XCTAssertNil(ClaudeRemoteHTTPCodec.bearerToken(in: nil))
        XCTAssertNil(ClaudeRemoteHTTPCodec.bearerToken(in: "Basic abc"), "only Bearer")
        XCTAssertNil(ClaudeRemoteHTTPCodec.bearerToken(in: "Bearer"), "scheme with no credential")
        XCTAssertNil(ClaudeRemoteHTTPCodec.bearerToken(in: "abc"), "no scheme")
    }

    func testAnAbsurdlyLongAuthorizationValueYieldsNoToken() {
        // Bounded before it is ever hashed or compared.
        let huge = "Bearer " + String(repeating: "a", count: 4096)
        XCTAssertNil(ClaudeRemoteHTTPCodec.bearerToken(in: huge))
    }

    func testAnUninterpolatedEnvVarPlaceholderIsNotAToken() throws {
        // What shipped from the plugin's original http-hook shape, where header
        // `${VAR}`s went out uninterpolated (and what any misconfigured client
        // could still send). It must read as "no credential", not as a
        // credential that happens to fail.
        let raw = request(headers: [
            "Authorization: Bearer ${CLAUDE_PLUGIN_OPTION_TOKEN}",
            "Content-Length: 2",
        ])
        let (parsed, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(raw)
        XCTAssertEqual(parsed.bearerToken, "${CLAUDE_PLUGIN_OPTION_TOKEN}")
        XCTAssertFalse(
            ClaudeRemoteTokenDigest.isWellFormed(try XCTUnwrap(parsed.bearerToken)),
            "a literal placeholder must never be well-formed"
        )
    }

    // MARK: Authorization shape

    /// Why a header yielded no credential, which decides which of two fixes the
    /// user needs: update the plugin, or re-run enrollment.
    func testAuthorizationShapeSeparatesAMissingCredentialFromAMalformedHeader() {
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: nil), .missing)
        // The pre-1.1.0 plugin's exact wire shape. The head parser trims the
        // trailing space, so this arrives as a bare scheme.
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: "Bearer"), .missing)
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: "Bearer   "), .missing)
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: ""), .missing)
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: "Basic abc"), .malformed)
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: "abc"), .malformed)
        XCTAssertEqual(
            ClaudeRemoteHTTPCodec.authorizationShape(in: "Bearer " + String(repeating: "a", count: 4096)),
            .malformed,
            "an oversized header is refused, not classified as a credential we failed to read"
        )
        XCTAssertEqual(ClaudeRemoteHTTPCodec.authorizationShape(in: "bearer abc"), .bearer("abc"))
    }

    /// The classifier IS the bearer path, so the two can never disagree about
    /// which strings are credentials.
    func testBearerTokenAndShapeAgreeOnEveryCase() {
        let cases: [String?] = [
            nil, "", "Bearer", "Bearer ", "Bearer abc", "bearer abc", "Basic abc", "abc",
            "Bearer a b", "Bearer " + String(repeating: "a", count: 4096),
        ]
        for value in cases {
            let shape = ClaudeRemoteHTTPCodec.authorizationShape(in: value)
            let token = ClaudeRemoteHTTPCodec.bearerToken(in: value)
            if case .bearer(let credential) = shape {
                XCTAssertEqual(token, credential, "disagreed on \(value ?? "nil")")
            } else {
                XCTAssertNil(token, "disagreed on \(value ?? "nil")")
            }
        }
    }

    // MARK: Event path

    func testEventNameIsRecoveredFromThePath() {
        XCTAssertEqual(ClaudeRemoteHTTPCodec.eventName(inPath: "/v1/hook/SessionStart"), "SessionStart")
        XCTAssertNil(ClaudeRemoteHTTPCodec.eventName(inPath: "/v1/hook/"), "empty event")
        XCTAssertNil(ClaudeRemoteHTTPCodec.eventName(inPath: "/hook/Stop"), "wrong prefix")
        XCTAssertNil(ClaudeRemoteHTTPCodec.eventName(inPath: "/"), "no prefix")
        XCTAssertNil(ClaudeRemoteHTTPCodec.eventName(inPath: "/v1/hook/a/b"), "a path, not a name")
    }

    // MARK: Responses

    /// The response-key allowlist. Claude Code EXECUTES what it finds here, so
    /// an extra key is a control channel we did not mean to open.
    func testMarkerResponseCarriesOnlyTheTwoAllowedKeys() throws {
        for marker in ["lvx-abcd1234", nil] {
            let body = ClaudeRemoteHTTPCodec.markerResponseBody(marker: marker)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertTrue(
                Set(object.keys).isSubset(of: ["terminalSequence", "suppressOutput"]),
                "unexpected response keys: \(Set(object.keys))"
            )
        }
    }

    func testMarkerResponseCarriesTheOSC2Sequence() throws {
        let body = ClaudeRemoteHTTPCodec.markerResponseBody(marker: "lvx-abcd1234")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-abcd1234\u{07}")
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
    }

    /// A marker is written into a terminal, so it is code as much as data. The
    /// response builder must inherit the OSC allowlist rather than restate it.
    func testAnUnsafeMarkerProducesNoTerminalSequenceAtAll() throws {
        let hostile = [
            "lvx-\u{1B}]0;pwned\u{07}",
            "lvx-abc\u{07}",
            "lvx-abc\n",
            "lvx-abc; rm -rf /",
            "not-a-marker",
            "lvx-" + String(repeating: "a", count: 64),
        ]
        for marker in hostile {
            let body = ClaudeRemoteHTTPCodec.markerResponseBody(marker: marker)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(
                object["terminalSequence"],
                "'\(marker)' must produce no sequence, got one"
            )
            XCTAssertEqual(object["suppressOutput"] as? Bool, true)
        }
    }

    func testResponseIsWellFormedAndAlwaysCloses() throws {
        let body = ClaudeRemoteHTTPCodec.markerResponseBody(marker: "lvx-abcd1234")
        let data = ClaudeRemoteHTTPCodec.response(status: 200, body: body)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        // One request per connection: no keep-alive to reason about, and no
        // second request to re-authenticate.
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("\r\n\r\n"))
    }

    func testUnauthorizedResponseIsBodilessAndChallenges() {
        let text = String(decoding: ClaudeRemoteHTTPCodec.response(status: 401), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("WWW-Authenticate: Bearer\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"), "a rejection must say nothing at all")
    }

    // MARK: Peer policy

    func testOnlyLoopbackAddressesAreAccepted() {
        // 127.0.0.0/8 — the far end of an OpenSSH RemoteForward arrives here.
        XCTAssertTrue(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x7F00_0001)) // 127.0.0.1
        XCTAssertTrue(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x7F00_0002))
        XCTAssertTrue(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x7FFF_FFFF))
        XCTAssertFalse(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x0A00_0001)) // 10.0.0.1
        XCTAssertFalse(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0xC0A8_0101)) // 192.168.1.1
        XCTAssertFalse(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x0000_0000)) // 0.0.0.0
        XCTAssertFalse(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x8000_0001)) // 128.0.0.1
        XCTAssertFalse(ClaudeRemotePeerPolicy.isLoopbackIPv4(hostOrderAddress: 0x7E00_0001)) // 126.0.0.1
    }
}
