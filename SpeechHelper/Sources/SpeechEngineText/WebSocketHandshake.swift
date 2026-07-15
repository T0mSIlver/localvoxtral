import CryptoKit
import Foundation

/// The WebSocket opening handshake (RFC 6455 §4.2) plus a tiny HTTP request parser — enough
/// to tell a `GET /health` probe apart from a `/v1/realtime` upgrade on one loopback port.
/// Pure and Metal-free.
public struct HTTPRequestHead: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]  // lowercased header names

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// A WebSocket upgrade request carries `Upgrade: websocket` + a `Sec-WebSocket-Key`.
    public var isWebSocketUpgrade: Bool {
        (header("upgrade")?.lowercased().contains("websocket") ?? false)
            && header("sec-websocket-key") != nil
    }
}

public enum WebSocketHandshake {
    /// Fixed GUID from RFC 6455 §1.3.
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Parse an HTTP request head from the bytes before the `\r\n\r\n` terminator. Returns nil
    /// if the header block isn't complete yet (caller should read more).
    public static func parseRequestHead(_ buffer: Data) -> (head: HTTPRequestHead, headerBytes: Int)? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerBytes = range.upperBound - buffer.startIndex
        guard let text = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (
            HTTPRequestHead(method: String(parts[0]), path: String(parts[1]), headers: headers),
            headerBytes
        )
    }

    /// `Sec-WebSocket-Accept` = base64(SHA1(key + magicGUID)).
    public static func acceptKey(for secWebSocketKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((secWebSocketKey + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The 101 Switching Protocols response bytes for a given client key.
    public static func upgradeResponse(secWebSocketKey: String) -> Data {
        let accept = acceptKey(for: secWebSocketKey)
        let response = """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(accept)\r
            \r

            """
        return Data(response.utf8)
    }

    /// A minimal HTTP/1.1 response with a JSON body and `Connection: close`.
    public static func httpResponse(status: String, json: String) -> Data {
        let body = Data(json.utf8)
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        return Data(head.utf8) + body
    }
}
