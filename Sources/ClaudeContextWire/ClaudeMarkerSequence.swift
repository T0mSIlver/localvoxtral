import Foundation

/// The broker's reply to a published record.
///
/// The socket is request/response: the publisher writes one record line and
/// reads one response line back. The response carries the marker the BROKER
/// allocated for that session — the publisher never invents one, so two
/// terminals can never disagree about who owns a marker.
public struct ClaudeBrokerResponse: Sendable, Equatable, Codable {
    public var version: Int
    /// Marker for the session this record belongs to. Nil when the broker
    /// accepted the record but has no marker to publish (e.g. it was rejected).
    public var marker: String?
    /// Whether the record was actually committed to the registry. Nil means
    /// the reply came from a pre-`accepted`-era broker, which consumers must
    /// treat exactly as they always did — as success. Deliberately NOT a
    /// version bump: synthesized Codable omits the key when nil and ignores
    /// unknown keys on decode, so both directions of a version skew (old
    /// publisher/new broker, new publisher/old broker) decode cleanly.
    public var accepted: Bool?

    public init(version: Int = ClaudeHookWire.version, marker: String?, accepted: Bool? = nil) {
        self.version = version
        self.marker = marker
        self.accepted = accepted
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case marker
        case accepted
    }

    public static func encodeLine(_ response: ClaudeBrokerResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Decode a reply. Returns nil for anything unexpected — the publisher
    /// treats that as "no marker", which means "emit nothing".
    public static func decodeLine(_ line: Data, limits: ClaudeHookLimits = .default) -> ClaudeBrokerResponse? {
        guard line.count <= limits.maxLineBytes else { return nil }
        guard let response = try? JSONDecoder().decode(ClaudeBrokerResponse.self, from: line) else {
            return nil
        }
        // Any readable wire version, not just the current one: a publisher one
        // release ahead of or behind the app must degrade to "no marker", not
        // lose the marker channel entirely until both halves are updated.
        guard ClaudeHookWire.readableVersions.contains(response.version) else { return nil }
        return response
    }
}

/// Builds the terminal escape sequence that carries a marker into the window
/// title, where a focus probe can read it back.
///
/// This is the focus join: the app knows which marker it gave a session, and
/// the marker is visible in the terminal's title, so the focused window
/// identifies its own session. No guessing, no cwd heuristics.
///
/// Everything here is about NOT injecting arbitrary bytes into someone's
/// terminal. An escape sequence is code as much as data: a marker containing
/// `BEL`, `ESC`, or a newline would terminate the sequence early and leave the
/// remainder to be interpreted as further commands. So the marker is validated
/// against a strict allowlist and the result is length-bounded — and when
/// anything is off, we emit NOTHING rather than something almost-right.
public enum ClaudeMarkerSequence {
    /// Marker grammar: `lvx-` plus lowercase hex. Nothing else is ever emitted.
    /// Deliberately far narrower than "no control characters" — an allowlist
    /// cannot be defeated by an encoding trick the way a denylist can.
    static let allowedMarkerCharacters = Set("abcdef0123456789-lvx")

    /// Hard ceiling on the whole sequence. A title write is not a place to
    /// discover that a peer sent a megabyte.
    public static let maxSequenceBytes = 128

    /// Longest marker we will put in a title.
    public static let maxMarkerLength = 32

    public static func isValidMarker(_ marker: String) -> Bool {
        guard !marker.isEmpty, marker.count <= maxMarkerLength else { return false }
        guard marker.hasPrefix("lvx-") else { return false }
        return marker.allSatisfy { character in
            character.unicodeScalars.allSatisfy { $0.isASCII }
                && character.unicodeScalars.allSatisfy { allowedMarkerCharacters.contains(Character($0)) }
        }
    }

    /// The OSC 2 (set window title) sequence for a marker, or nil if the marker
    /// is not one we are willing to emit.
    ///
    /// `ESC ] 2 ; <title> BEL` — BEL-terminated rather than ST, since that is
    /// the form every terminal we care about accepts.
    public static func windowTitleSequence(marker: String) -> String? {
        guard isValidMarker(marker) else { return nil }
        let sequence = "\u{1B}]2;\(marker)\u{07}"
        guard sequence.utf8.count <= maxSequenceBytes else { return nil }
        return sequence
    }
}

/// The JSON a hook prints on stdout.
///
/// Claude Code parses a hook's stdout as control JSON. That cuts both ways: it
/// is how we ask for a terminal sequence to be written, and it is why the
/// publisher must emit either VALID JSON or absolutely nothing. A
/// `UserPromptSubmit` hook's non-JSON stdout is appended to the user's prompt —
/// a half-written or malformed object would land in their context as garbage.
public struct ClaudeHookOutput: Sendable, Equatable, Codable {
    /// Escape sequence for Claude Code to write to the terminal.
    public var terminalSequence: String?
    /// Keep the hook silent in the transcript. Nothing here is for the user to
    /// read; the marker is for the app.
    public var suppressOutput: Bool

    public init(terminalSequence: String?, suppressOutput: Bool = true) {
        self.terminalSequence = terminalSequence
        self.suppressOutput = suppressOutput
    }

    /// The stdout line for a marker, or nil when there is nothing safe to say.
    ///
    /// Nil means the publisher prints NOTHING at all — not an empty object, not
    /// a newline. Silence is always a valid hook result; a guess is not.
    public static func markerOutputLine(marker: String?) -> Data? {
        guard let marker, let sequence = ClaudeMarkerSequence.windowTitleSequence(marker: marker) else {
            return nil
        }
        let output = ClaudeHookOutput(terminalSequence: sequence, suppressOutput: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(output) else { return nil }
        return data
    }
}
