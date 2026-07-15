import Foundation
import XCTest

@testable import SpeechEngineText

/// Metal-free tests for the loopback realtime server's pure codecs: WebSocket framing, the
/// upgrade handshake, the protocol messages, and PCM16 decode. These are the pieces that
/// carry bytes on and off the wire, so they get exercised directly rather than through a
/// socket.
final class RealtimeServerCodecTests: XCTestCase {
    // MARK: WebSocket frames

    /// Round-trip a masked client frame through decode (server frames are unmasked, so we
    /// build the masked bytes by hand the way a client would).
    private func maskedClientFrame(opcode: WebSocketOpcode, payload: [UInt8], mask: [UInt8]) -> Data {
        var out: [UInt8] = [0x80 | opcode.rawValue]
        let len = payload.count
        if len < 126 {
            out.append(0x80 | UInt8(len))
        } else if len <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        } else {
            out.append(0x80 | 127)
            let l = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((l >> UInt64(shift)) & 0xFF)) }
        }
        out.append(contentsOf: mask)
        for (i, b) in payload.enumerated() { out.append(b ^ mask[i % 4]) }
        return Data(out)
    }

    func testDecodeMaskedTextFrame() throws {
        let text = "hello realtime"
        let frame = maskedClientFrame(opcode: .text, payload: [UInt8](text.utf8), mask: [0x12, 0x34, 0x56, 0x78])
        guard case .frame(let decoded, let consumed) = try WebSocketFrameCodec.decode(frame) else {
            return XCTFail("expected a complete frame")
        }
        XCTAssertEqual(decoded.opcode, .text)
        XCTAssertTrue(decoded.fin)
        XCTAssertEqual(String(data: decoded.payload, encoding: .utf8), text)
        XCTAssertEqual(consumed, frame.count)
    }

    func testDecodeIsIncompleteUntilFullFrameArrives() throws {
        let full = maskedClientFrame(opcode: .text, payload: [UInt8]("abc".utf8), mask: [1, 2, 3, 4])
        for prefixLen in 0..<full.count {
            XCTAssertEqual(try WebSocketFrameCodec.decode(full.prefix(prefixLen)), .incomplete,
                           "prefix of \(prefixLen) bytes should be incomplete")
        }
        guard case .frame = try WebSocketFrameCodec.decode(full) else { return XCTFail() }
    }

    func testDecodeExtendedLength126() throws {
        let payload = [UInt8](repeating: 0x41, count: 300)  // > 125 → 16-bit length path
        let frame = maskedClientFrame(opcode: .binary, payload: payload, mask: [9, 8, 7, 6])
        guard case .frame(let decoded, _) = try WebSocketFrameCodec.decode(frame) else { return XCTFail() }
        XCTAssertEqual([UInt8](decoded.payload), payload)
    }

    func testUnmaskedClientFrameRejected() {
        let unmasked = Data([0x81, 0x03, 0x61, 0x62, 0x63])  // FIN+text, len 3, no mask
        XCTAssertThrowsError(try WebSocketFrameCodec.decode(unmasked)) { error in
            XCTAssertEqual(error as? WebSocketFrameError, .clientFrameNotMasked)
        }
    }

    func testHostileLengthRejectedBeforeAllocating() {
        // FIN+binary, 127 length marker, 64-bit length = 0xFFFFFFFF (masked bit set).
        var bytes: [UInt8] = [0x82, 0xFF]
        bytes.append(contentsOf: [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try WebSocketFrameCodec.decode(Data(bytes))) { error in
            guard case .payloadTooLarge = (error as? WebSocketFrameError) else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
        }
    }

    func testServerEncodeIsUnmaskedAndDecodesBack() throws {
        let data = WebSocketFrameCodec.text("δelta")  // multibyte to check length in bytes
        // A server frame must have the mask bit clear.
        XCTAssertEqual(data[1] & 0x80, 0)
        // Decode it back allowing unmasked (as a client would).
        guard case .frame(let f, let consumed) = try WebSocketFrameCodec.decode(data, requireMask: false) else {
            return XCTFail()
        }
        XCTAssertEqual(String(data: f.payload, encoding: .utf8), "δelta")
        XCTAssertEqual(consumed, data.count)
    }

    // MARK: Handshake

    func testAcceptKeyMatchesRFC6455Example() {
        // The canonical example from RFC 6455 §1.3.
        XCTAssertEqual(
            WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testParseRequestHeadDistinguishesHealthFromUpgrade() {
        let health = Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        guard let (h, _) = WebSocketHandshake.parseRequestHead(health) else { return XCTFail() }
        XCTAssertEqual(h.path, "/health")
        XCTAssertFalse(h.isWebSocketUpgrade)

        let upgrade = Data(
            "GET /v1/realtime HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc==\r\n\r\n".utf8)
        guard let (u, _) = WebSocketHandshake.parseRequestHead(upgrade) else { return XCTFail() }
        XCTAssertTrue(u.isWebSocketUpgrade)
        XCTAssertEqual(u.header("sec-websocket-key"), "abc==")
    }

    func testParseRequestHeadIncompleteUntilTerminator() {
        XCTAssertNil(WebSocketHandshake.parseRequestHead(Data("GET /health HTTP/1.1\r\nHost: x".utf8)))
    }

    // MARK: Protocol

    func testParseAudioAppend() throws {
        let msg = try RealtimeClientMessage.parse(Data(#"{"type":"input_audio_buffer.append","audio":"AAECAw=="}"#.utf8))
        XCTAssertEqual(msg, .audioAppend(base64PCM16: "AAECAw=="))
    }

    func testParseCommitFinalAndNonFinal() throws {
        XCTAssertEqual(try RealtimeClientMessage.parse(Data(#"{"type":"input_audio_buffer.commit","final":true}"#.utf8)), .commit(final: true))
        XCTAssertEqual(try RealtimeClientMessage.parse(Data(#"{"type":"input_audio_buffer.commit"}"#.utf8)), .commit(final: false))
    }

    func testUnknownTypeIsIgnoredNotAnError() throws {
        XCTAssertEqual(try RealtimeClientMessage.parse(Data(#"{"type":"response.created"}"#.utf8)), .ignored(type: "response.created"))
    }

    func testServerMessageJSONEscapesText() {
        // A transcript containing a quote and newline must be valid JSON, not hand-broken.
        let json = RealtimeServerMessage.transcriptDone(text: "he said \"hi\"\nbye").json()
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(parsed?["type"], "response.audio_transcript.done")
        XCTAssertEqual(parsed?["text"], "he said \"hi\"\nbye")
    }

    // MARK: PCM16

    func testPCM16DecodeNormalizes() {
        // int16 samples 0, 32767, -32768 → 0, ~1, -1
        let bytes: [UInt8] = [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]
        let b64 = Data(bytes).base64EncodedString()
        let samples = PCM16.decode(base64: b64)
        XCTAssertEqual(samples?.count, 3)
        XCTAssertEqual(samples?[0], 0)
        XCTAssertEqual(samples?[1] ?? 0, 0.99997, accuracy: 0.0001)
        XCTAssertEqual(samples?[2], -1)
    }

    func testPCM16RejectsOddByteCount() {
        XCTAssertNil(PCM16.decode(base64: Data([0x01, 0x02, 0x03]).base64EncodedString()))
    }
}
