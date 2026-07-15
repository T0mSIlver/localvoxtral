import Foundation

/// The OpenAI-Realtime-compatible message subset the app exchanges with the ASR backend.
/// Matches what `RealtimeAPIWebSocketClient` sends and expects (verified against the client),
/// so this Swift server is a drop-in for the Python `voxmlx` process. Pure and Metal-free.
public enum RealtimeClientMessage: Equatable, Sendable {
    case sessionUpdate
    /// 16 kHz mono PCM16LE, base64-encoded.
    case audioAppend(base64PCM16: String)
    /// `final == true` finalizes the utterance; a non-final commit is a no-op (matches voxmlx).
    case commit(final: Bool)
    case clear
    /// A well-formed frame we don't act on (forward-compat: ignore, don't error).
    case ignored(type: String)

    public enum ParseError: Error, Equatable, Sendable {
        case notJSONObject
        case missingType
        case invalidAudioPayload
    }

    public static func parse(_ data: Data) throws -> RealtimeClientMessage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSONObject
        }
        guard let type = obj["type"] as? String else { throw ParseError.missingType }

        switch type {
        case "session.update":
            return .sessionUpdate
        case "input_audio_buffer.append":
            guard let audio = obj["audio"] as? String, !audio.isEmpty else {
                throw ParseError.invalidAudioPayload
            }
            return .audioAppend(base64PCM16: audio)
        case "input_audio_buffer.commit":
            // `final` may arrive as a Bool or a numeric 0/1 depending on the encoder.
            let final = (obj["final"] as? Bool) ?? ((obj["final"] as? NSNumber)?.boolValue ?? false)
            return .commit(final: final)
        case "input_audio_buffer.clear":
            return .clear
        default:
            return .ignored(type: type)
        }
    }
}

/// Server→client messages. Serialized to compact JSON text frames.
public enum RealtimeServerMessage: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case transcriptDelta(String)
    case transcriptDone(text: String)
    case error(message: String)

    public func json() -> String {
        switch self {
        case .sessionCreated:
            return #"{"type":"session.created"}"#
        case .sessionUpdated:
            return #"{"type":"session.updated"}"#
        case .transcriptDelta(let delta):
            return Self.object(["type": "response.audio_transcript.delta", "delta": delta])
        case .transcriptDone(let text):
            return Self.object(["type": "response.audio_transcript.done", "text": text])
        case .error(let message):
            return Self.object(["type": "error", "message": message])
        }
    }

    /// JSONSerialization with sorted keys so a value like a string with quotes/newlines is
    /// escaped correctly (never hand-format JSON around model-produced text).
    private static func object(_ dict: [String: String]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"error","message":"serialization failed"}"#
        }
        return string
    }
}

public enum PCM16 {
    /// Decode base64 PCM16LE mono to normalized Float samples in [-1, 1), the input the
    /// streaming session's `step([Float])` expects. Returns nil on undecodable base64 or an
    /// odd byte count (a truncated sample).
    public static func decode(base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard data.count % 2 == 0 else { return nil }
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let sample = Int16(bitPattern: (hi << 8) | lo)
                out[i] = Float(sample) / 32768.0
            }
        }
        return out
    }
}
