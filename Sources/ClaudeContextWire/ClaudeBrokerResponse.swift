import Foundation

/// The broker's reply to a published record.
///
/// The socket is request/response: the publisher writes one record line and
/// reads one response line back. The reply is a RECEIPT, not a channel — it
/// says which wire version the broker answered in and whether the record was
/// committed. Nothing in it is ever written to a terminal; the publisher's
/// stdout stays empty on every hook path (see `ClaudeHookOutput`).
public struct ClaudeBrokerResponse: Sendable, Equatable, Codable {
    public var version: Int
    /// Whether the record was actually committed to the registry. Nil means
    /// the reply came from a pre-`accepted`-era broker, which consumers must
    /// treat exactly as they always did — as success. Deliberately NOT a
    /// version bump: synthesized Codable omits the key when nil and ignores
    /// unknown keys on decode, so both directions of a version skew (old
    /// publisher/new broker, new publisher/old broker) decode cleanly.
    ///
    /// The same property is what let the `marker` field be REMOVED without a
    /// bump: it was optional too, so a reply that omits it still decodes in an
    /// already-installed publisher, which then finds no marker and prints
    /// nothing — which is exactly what the marker-free publisher does.
    public var accepted: Bool?

    public init(version: Int = ClaudeHookWire.version, accepted: Bool? = nil) {
        self.version = version
        self.accepted = accepted
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case accepted
    }

    public static func encodeLine(_ response: ClaudeBrokerResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Decode a reply. Returns nil for anything unexpected — a caller treats
    /// that as "the broker said nothing usable", which changes nothing about
    /// what the hook prints.
    public static func decodeLine(_ line: Data, limits: ClaudeHookLimits = .default) -> ClaudeBrokerResponse? {
        guard line.count <= limits.maxLineBytes else { return nil }
        guard let response = try? JSONDecoder().decode(ClaudeBrokerResponse.self, from: line) else {
            return nil
        }
        // Any readable wire version, not just the current one: a publisher one
        // release ahead of or behind the app must still be able to read the
        // receipt (the status line renders it) rather than lose the reply
        // entirely until both halves are updated.
        guard ClaudeHookWire.readableVersions.contains(response.version) else { return nil }
        return response
    }
}

/// The JSON the REMOTE listener answers a hook request with.
///
/// Claude Code parses a hook's stdout as control JSON. That cuts both ways: it
/// is why the body has to be valid JSON, and it is why the key set is a
/// property of a TYPE with exactly one property rather than of a filter
/// someone has to remember to apply. Claude Code executes what it finds here —
/// an extra key would at best be ignored and at worst be a control channel we
/// did not mean to open.
///
/// `suppressOutput` is the whole vocabulary: keep the hook silent in the
/// transcript. There is deliberately no field that can put bytes on a
/// terminal.
public struct ClaudeHookOutput: Sendable, Equatable, Codable {
    /// Keep the hook silent in the transcript. Nothing here is for the user to
    /// read; the request exists for the app's registry.
    public var suppressOutput: Bool

    public init(suppressOutput: Bool = true) {
        self.suppressOutput = suppressOutput
    }
}
