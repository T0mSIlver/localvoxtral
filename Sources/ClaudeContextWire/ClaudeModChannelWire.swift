import Foundation

/// The channel from the app to one Claude Code session's mod (#1408).
///
/// The mod (`integrations/claude-code/plugins/localvoxtral-mod`) runs
/// `localvoxtral-claude-hook --attach --session <id>` for the session's life.
/// That process connects to the app's socket, sends an `Attach` line, and
/// keeps the connection open; the broker writes `Message` lines down it, and
/// the process copies each one that decodes to its stdout, where the mod
/// reads it. The mod answers a message with `--mod-reply`, a one-shot
/// connection carrying a `Reply` line, and says the session ended with a
/// `Bye` line the same way (#1646).
///
/// Every line is one JSON object. The shapes tell themselves apart by a key
/// no hook record has: `mod_attach`, `mod_message`, `mod_reply` and
/// `mod_bye`.
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
        /// A spoken send (#1644): put `text` in the box at the cursor, then
        /// submit the box's whole text and empty it, with no key. `ok` once
        /// the box held it; the reply's `submitted` says whether it was then
        /// submitted, and `queued` that the submit waits for the running
        /// turn. A box the mod cannot submit as typed (a paste placeholder,
        /// a slash command) answers `ok: false` with nothing changed. An
        /// empty `text` submits the box as it stands: a Live Auto-Paste
        /// spoken send, after its appends (#1645).
        case send
        /// Ask the session's own model `text` over its transcript, tool-less
        /// (`$.model.fork`, #1410). `ok` with the answer in the reply's
        /// `text`.
        case terms
        /// Answer with the prompt box as the person left it: `ok` with the
        /// draft around the cursor in the reply's `text` and the cursor's
        /// UTF-16 offset into it in `cursor` (#1406). An empty box answers
        /// `ok` with `""`, which is also all a surface that binds no box
        /// can say.
        case draft
        /// What the band above the prompt shows. Not answered. Either the
        /// joined dictation's state (#1411): `phase` and the words so far
        /// in `text`; or, with `waiting` set and no `phase`, the other
        /// sessions that wait for the user (#1695).
        case state
        /// The app took the mod's `Bye` and ended the channel (#1646): the
        /// mod stops its `--attach` and, if the process goes on under a new
        /// session id (`/clear`), attaches again for that one. Not answered.
        case bye
        /// One Live Auto-Paste delta (#1645): put `text` in the box at the
        /// cursor, after the stream's earlier deltas. `seq` counts the
        /// stream's appends from 1. Not answered, so a delta costs no reply
        /// process. A gap in `seq` or a refused fill ends the stream: the mod
        /// fills nothing after it, and never out of order.
        case append
        /// How far the stream got: `ok` with the number of appends filled in
        /// order in the reply's `seq`, once every append written before it
        /// was handled. Ends the stream; the next append starts at 1. The
        /// app asks it at the dictation's start (a mod older than `append`
        /// answers `unknown_kind`) and at its stop.
        case ack
        /// A spoken stop phrase (#1696): end the session's running main-loop
        /// turn (`$.turn.abort`), with no key. `ok` once it is ended; with
        /// no turn running, `ok: false` with `noTurnReason`.
        case abort
    }

    /// What a `state` message says the dictation is doing.
    public enum Phase: String, Codable, Sendable {
        case listening
        case finishing
        /// Over: the band clears.
        case done
    }

    /// One request from the app to the mod.
    public struct Message: Codable, Equatable, Sendable {
        public var modMessage: Int
        public var kind: Kind
        /// Matches the `Reply`. The hub assigns it.
        public var id: String
        /// What `fill` and `append` put in the box; the question `terms`
        /// asks; the words so far for `state`.
        public var text: String?
        public var phase: Phase?
        /// For `state`: the names of the other sessions waiting for the
        /// user, oldest first; empty when none does. Names only, never what
        /// an agent said (#717).
        public var waiting: [String]?
        /// An `append`'s place in its stream, from 1.
        public var seq: Int?

        public init(
            kind: Kind,
            id: String = "",
            text: String? = nil,
            phase: Phase? = nil,
            waiting: [String]? = nil,
            seq: Int? = nil,
            version: Int = ClaudeModChannelWire.version
        ) {
            self.modMessage = version
            self.kind = kind
            self.id = id
            self.text = text
            self.phase = phase
            self.waiting = waiting
            self.seq = seq
        }

        enum CodingKeys: String, CodingKey {
            case modMessage = "mod_message"
            case kind
            case id
            case text
            case phase
            case waiting
            case seq
        }
    }

    /// What a `terms` fork cost, as the API counted it.
    public struct Usage: Codable, Equatable, Sendable {
        public var inputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?
        public var outputTokens: Int?

        public init(
            inputTokens: Int? = nil,
            cacheCreationInputTokens: Int? = nil,
            cacheReadInputTokens: Int? = nil,
            outputTokens: Int? = nil
        ) {
            self.inputTokens = inputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.outputTokens = outputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokens = "output_tokens"
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
        /// The model's answer to `terms`; the draft for `draft`. Never set
        /// for `fill`.
        public var text: String?
        /// Where the cursor sits in a `draft` reply's `text`, in UTF-16 code
        /// units.
        public var cursor: Int?
        /// What a `terms` fork cost.
        public var usage: Usage?
        /// For `send`: whether the box's text was submitted.
        public var submitted: Bool?
        /// For `send`: the submit waits for the session's running turn.
        public var queued: Bool?
        /// For `ack`: how many of the stream's appends the mod filled, in
        /// order from the first.
        public var seq: Int?

        /// The `reason` of a request the mod refused because its process
        /// went on under another session (`/clear`, a resume) before the
        /// app closed this session's channel.
        public static let sessionChangedReason = "session_changed"
        /// The refusal of an `abort` while no turn runs.
        public static let noTurnReason = "no_turn"

        public init(
            sessionID: String,
            id: String,
            ok: Bool,
            reason: String? = nil,
            text: String? = nil,
            cursor: Int? = nil,
            usage: Usage? = nil,
            submitted: Bool? = nil,
            queued: Bool? = nil,
            seq: Int? = nil,
            version: Int = ClaudeModChannelWire.version
        ) {
            self.submitted = submitted
            self.queued = queued
            self.seq = seq
            self.modReply = version
            self.sessionID = sessionID
            self.id = id
            self.ok = ok
            self.reason = reason
            self.text = text
            self.cursor = cursor
            self.usage = usage
        }

        enum CodingKeys: String, CodingKey {
            case modReply = "mod_reply"
            case sessionID = "session_id"
            case id
            case ok
            case reason
            case text
            case cursor
            case usage
            case submitted
            case queued
            case seq
        }
    }

    /// The mod's word that its session is ending (#1646), sent on
    /// `session.end` through `--mod-reply`. The app ends the session when the
    /// session's channel detaches after it; with no channel attached it
    /// changes nothing.
    public struct Bye: Codable, Equatable, Sendable {
        public var modBye: Int
        public var sessionID: String

        public init(sessionID: String, version: Int = ClaudeModChannelWire.version) {
            self.modBye = version
            self.sessionID = sessionID
        }

        enum CodingKeys: String, CodingKey {
            case modBye = "mod_bye"
            case sessionID = "session_id"
        }
    }

    public static func isAttach(_ line: Data) -> Bool { hasKey("mod_attach", in: line) }
    public static func isReply(_ line: Data) -> Bool { hasKey("mod_reply", in: line) }
    public static func isBye(_ line: Data) -> Bool { hasKey("mod_bye", in: line) }

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

extension ClaudeModChannelWire.Bye: ClaudeModChannelWire.Versioned {
    public var wireVersion: Int { modBye }
}
