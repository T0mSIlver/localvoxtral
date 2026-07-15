import Foundation

/// Minimal RFC 6455 frame codec — just enough for the realtime ASR protocol on loopback.
/// Pure and Metal-free so the framing logic is unit-testable without a socket or a model.
///
/// Scope: single-frame text/binary messages plus control frames (ping/pong/close). The app's
/// `URLSessionWebSocketTask` client sends each realtime message as one (possibly large,
/// masked) frame, so continuation frames are decoded defensively but the server only ever
/// *emits* unfragmented frames.
public enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public struct WebSocketFrame: Equatable, Sendable {
    public let fin: Bool
    public let opcode: WebSocketOpcode
    public let payload: Data

    public init(fin: Bool, opcode: WebSocketOpcode, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketDecodeResult: Equatable, Sendable {
    /// A complete frame plus the number of bytes it consumed from the buffer.
    case frame(WebSocketFrame, consumed: Int)
    /// Not enough bytes yet — read more and retry.
    case incomplete
}

public enum WebSocketFrameError: Error, Equatable, Sendable {
    /// A client frame was not masked (RFC 6455 requires client→server frames to be masked).
    case clientFrameNotMasked
    case reservedOpcode(UInt8)
    /// Payload length field exceeds what we will buffer (guards against a hostile length).
    case payloadTooLarge(UInt64)
}

public enum WebSocketFrameCodec {
    /// Hard cap on a single inbound frame we will assemble (audio-append base64 for a chunk
    /// is a few KB; a whole utterance's worth is well under this). Prevents a bogus 64-bit
    /// length from making us allocate gigabytes.
    public static let maxPayloadBytes: UInt64 = 32 * 1024 * 1024

    /// Try to decode one frame from the front of `buffer`. Returns `.incomplete` if more
    /// bytes are needed. `requireMask` enforces the client-frame masking rule.
    public static func decode(_ buffer: Data, requireMask: Bool = true) throws -> WebSocketDecodeResult {
        // Index into `buffer` via its own indices (Data slices are not zero-based).
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return .incomplete }

        let b0 = bytes[0]
        let b1 = bytes[1]
        let fin = (b0 & 0x80) != 0
        let rawOpcode = b0 & 0x0F
        guard let opcode = WebSocketOpcode(rawValue: rawOpcode) else {
            throw WebSocketFrameError.reservedOpcode(rawOpcode)
        }
        let masked = (b1 & 0x80) != 0
        if requireMask && !masked {
            throw WebSocketFrameError.clientFrameNotMasked
        }

        var offset = 2
        var payloadLen = UInt64(b1 & 0x7F)
        if payloadLen == 126 {
            guard bytes.count >= offset + 2 else { return .incomplete }
            payloadLen = (UInt64(bytes[offset]) << 8) | UInt64(bytes[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard bytes.count >= offset + 8 else { return .incomplete }
            payloadLen = 0
            for i in 0..<8 { payloadLen = (payloadLen << 8) | UInt64(bytes[offset + i]) }
            offset += 8
        }
        if payloadLen > maxPayloadBytes {
            throw WebSocketFrameError.payloadTooLarge(payloadLen)
        }

        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return .incomplete }
            maskKey = Array(bytes[offset..<offset + 4])
            offset += 4
        }

        let len = Int(payloadLen)
        guard bytes.count >= offset + len else { return .incomplete }

        var payload = [UInt8](bytes[offset..<offset + len])
        if masked {
            for i in 0..<len { payload[i] ^= maskKey[i % 4] }
        }
        offset += len

        return .frame(
            WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload)),
            consumed: offset
        )
    }

    /// Encode a server→client frame. Server frames are never masked (RFC 6455).
    public static func encode(_ frame: WebSocketFrame) -> Data {
        var out = [UInt8]()
        out.append((frame.fin ? 0x80 : 0x00) | frame.opcode.rawValue)

        let len = frame.payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127)
            let len64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((len64 >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(contentsOf: frame.payload)
        return Data(out)
    }

    public static func text(_ string: String) -> Data {
        encode(WebSocketFrame(fin: true, opcode: .text, payload: Data(string.utf8)))
    }

    public static func pong(_ payload: Data) -> Data {
        encode(WebSocketFrame(fin: true, opcode: .pong, payload: payload))
    }

    /// A close frame with the normal-closure status code (1000).
    public static func close() -> Data {
        encode(WebSocketFrame(fin: true, opcode: .close, payload: Data([0x03, 0xE8])))
    }
}
