import Foundation

/// The channel from the app to one Claude Code session's mod (#1408).
///
/// The mod (`integrations/claude-code/plugins/localvoxtral-mod`) runs
/// `localvoxtral-claude-hook --attach --session <id>` for the session's life.
/// That process connects to the app's socket, sends an `Attach` line, and
/// keeps the connection open; the broker writes `Message` lines down it, and
/// the process copies each one that decodes to its stdout, where the mod
/// reads it. The mod answers a message with `--mod-reply`, a one-shot
/// connection carrying a `Reply` line.
///
/// Every line is one JSON object. The three shapes tell themselves apart by
/// a key no hook record has: `mod_attach`, `mod_message` and `mod_reply`.
public enum ClaudeModChannelWire {
    public static let version = 1
    /// One message or reply, whole. Dictated text is the largest payload.
    public static let maxLineBytes = 64 * 1024

    /// The first and only line `--attach` sends.
    public struct Attach: Codable, Equatable, Sendable {
        public var modAttach: Int
        public var sessionID: String
        /// The Claude Code process the publisher runs under. A mod's child
        /// is a direct child of `claude` (measured, #1407).
        public var claudePID: Int32

        public init(sessionID: String, claudePID: Int32, version: Int = ClaudeModChannelWire.version) {
            self.modAttach = version
            self.sessionID = sessionID
            self.claudePID = claudePID
        }

        enum CodingKeys: String, CodingKey {
            case modAttach = "mod_attach"
            case sessionID = "session_id"
            case claudePID = "claude_pid"
        }
    }

    /// The broker's answer to `Attach`. On `accepted: false` it closes.
    public struct AttachReply: Codable, Equatable, Sendable {
        public var modAttach: Int
        public var accepted: Bool

        public init(accepted: Bool, version: Int = ClaudeModChannelWire.version) {
            self.modAttach = version
            self.accepted = accepted
        }

        enum CodingKeys: String, CodingKey {
            case modAttach = "mod_attach"
            case accepted
        }
    }

    /// What the mod is asked to do. A mod drops a kind it does not know, so
    /// a newer app never breaks an older mod.
    public enum Kind: String, Codable, Sendable {
        /// Answer `ok`; nothing else. Proves the channel end to end.
        case ping
        /// Put `text` in the session's prompt box at the cursor (#1409).
        /// `ok` only once the box holds it.
        case fill
    }

    /// One request from the app to the mod.
    public struct Message: Codable, Equatable, Sendable {
        public var modMessage: Int
        public var kind: Kind
        /// Matches the `Reply`. The hub assigns it.
        public var id: String
        /// What `fill` puts in the box.
        public var text: String?

        public init(kind: Kind, id: String = "", text: String? = nil, version: Int = ClaudeModChannelWire.version) {
            self.modMessage = version
            self.kind = kind
            self.id = id
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case modMessage = "mod_message"
            case kind
            case id
            case text
        }
    }

    /// The mod's answer to one `Message`.
    public struct Reply: Codable, Equatable, Sendable {
        public var modReply: Int
        public var sessionID: String
        public var id: String
        public var ok: Bool
        /// Why it was not done, as a short code (`dialog`, `no_composer`),
        /// never text the person typed or dictated.
        public var reason: String?

        public init(
            sessionID: String,
            id: String,
            ok: Bool,
            reason: String? = nil,
            version: Int = ClaudeModChannelWire.version
        ) {
            self.modReply = version
            self.sessionID = sessionID
            self.id = id
            self.ok = ok
            self.reason = reason
        }

        enum CodingKeys: String, CodingKey {
            case modReply = "mod_reply"
            case sessionID = "session_id"
            case id
            case ok
            case reason
        }
    }

    public static func isAttach(_ line: Data) -> Bool { hasKey("mod_attach", in: line) }
    public static func isReply(_ line: Data) -> Bool { hasKey("mod_reply", in: line) }

    /// Decodes a line of this wire, or nil: over the size cap, not JSON, the
    /// wrong shape, or a version this build does not speak.
    public static func decode<Value: Decodable & Versioned>(_ type: Value.Type, from line: Data) -> Value? {
        guard line.count <= maxLineBytes,
              let value = try? JSONDecoder().decode(type, from: line),
              value.wireVersion == version
        else { return nil }
        return value
    }

    /// The value as one newline-terminated line, or nil over the size cap.
    public static func encodeLine<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value), data.count <= maxLineBytes else { return nil }
        data.append(0x0A)
        return data
    }

    private static func hasKey(_ key: String, in line: Data) -> Bool {
        // Every hook record passes through here, and few are this wire's:
        // look for the key's bytes before parsing the line.
        guard line.count <= maxLineBytes,
              line.range(of: Data("\"\(key)\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line),
              let dictionary = object as? [String: Any]
        else { return false }
        return dictionary[key] != nil
    }

    /// A shape of this wire, by the version its own key carries.
    public protocol Versioned {
        var wireVersion: Int { get }
    }
}

extension ClaudeModChannelWire.Attach: ClaudeModChannelWire.Versioned {
    public var wireVersion: Int { modAttach }
}

extension ClaudeModChannelWire.AttachReply: ClaudeModChannelWire.Versioned {
    public var wireVersion: Int { modAttach }
}

extension ClaudeModChannelWire.Message: ClaudeModChannelWire.Versioned {
    public var wireVersion: Int { modMessage }
}

extension ClaudeModChannelWire.Reply: ClaudeModChannelWire.Versioned {
    public var wireVersion: Int { modReply }
}
