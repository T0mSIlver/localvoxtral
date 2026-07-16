import Foundation

/// Where a snippet came from within a tool call.
public enum ClaudeContentSnippetKind: String, Sendable, Equatable, Codable {
    /// A value the model passed INTO a tool (`Edit.new_string`, `Write.content`).
    case toolInput
    /// A value a tool handed BACK (`Read` output, a tool response body).
    case toolOutput
}

/// A bounded, sanitized fragment of what a session was just working on.
///
/// This exists only for REMOTE sessions. A local session's files are on this
/// machine and the repository collector can read them properly — a snippet would
/// be a worse copy of something we already have. A remote session's files are on
/// another machine we have no business reaching into, so the hook payload is the
/// only thing we will ever know about them, and these are it.
///
/// The text is opaque by construction. It is never parsed, never resolved
/// against a path, and never used to decide anything — it is grounding material
/// for a polish prompt and nothing else.
public struct ClaudeContentSnippet: Sendable, Equatable, Codable {
    /// Provenance, e.g. `Edit new_string`. Sanitized and bounded like the text.
    public var label: String
    public var kind: ClaudeContentSnippetKind
    public var text: String

    public init(label: String, kind: ClaudeContentSnippetKind, text: String) {
        self.label = label
        self.kind = kind
        self.text = text
    }
}

public struct ClaudeSnippetLimits: Sendable, Equatable {
    public var maxSnippetBytes: Int
    public var maxSnippetsPerRecord: Int
    public var maxLabelBytes: Int

    public init(
        maxSnippetBytes: Int = 512,
        maxSnippetsPerRecord: Int = 4,
        maxLabelBytes: Int = 128
    ) {
        self.maxSnippetBytes = maxSnippetBytes
        self.maxSnippetsPerRecord = maxSnippetsPerRecord
        self.maxLabelBytes = maxLabelBytes
    }

    public static let `default` = ClaudeSnippetLimits()
}

/// Strips anything from foreign text that could act rather than read.
///
/// Remote content is written by a model on a machine we do not control, and it
/// ends up in two places that both interpret bytes: a polish prompt, and (via
/// diagnostics or a title) potentially a terminal. So this is an ALLOWLIST of
/// the character classes that carry meaning for grounding — everything else is
/// removed, not escaped:
///
/// * C0 controls and DEL — `ESC` is how a string becomes a terminal command.
/// * C1 controls — `0x9B` is a single-byte CSI on terminals that decode it.
/// * bidi overrides and zero-width characters — "trojan source": text that
///   renders as one thing and reads as another.
///
/// Tabs, newlines, and CRs become spaces rather than vanishing, so words on
/// either side of a line break do not fuse into a nonsense token.
public enum ClaudeTextSanitizer {
    static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, // LRM, RLM
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2066, 0x2067, 0x2068, 0x2069, // LRI, RLI, FSI, PDI
    ]

    public static func sanitize(_ raw: String, maxBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                scalars.append(" ")
            case 0x00...0x1F, 0x7F: // C0 + DEL
                continue
            case 0x80...0x9F: // C1
                continue
            case 0x200B, 0x2060, 0xFEFF: // zero-width space / joiner / BOM
                continue
            default:
                if bidiControls.contains(scalar.value) { continue }
                scalars.append(scalar)
            }
        }
        // Collapse the runs the substitutions above just created, so a 400-line
        // indented file does not spend its whole budget on whitespace.
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return ClaudeHookWireCodec.truncate(collapsed, toUTF8Bytes: maxBytes)
    }
}

/// Turns a REMOTE Claude Code hook's HTTP body into a wire record plus snippets.
///
/// The record half reuses `ClaudeHookInputParser` verbatim — the same allowlist
/// the local publisher applies, including dropping `transcript_path` and any
/// `origin`-shaped key. The snippet half is the remote-only addition.
///
/// Note what this does NOT do: decide trust. It returns a record; the LISTENER
/// decides the origin, from which token authenticated the connection. A payload
/// claiming to be local is just a payload with a key nobody reads.
public enum ClaudeRemoteHookPayloadParser {
    public struct Payload: Sendable, Equatable {
        public var record: ClaudeHookRecord
        public var snippets: [ClaudeContentSnippet]

        public init(record: ClaudeHookRecord, snippets: [ClaudeContentSnippet]) {
            self.record = record
            self.snippets = snippets
        }
    }

    /// `tool_input` keys worth grounding on, in priority order. Everything else
    /// in the object is ignored — notably `command`, which `Bash` carries and
    /// which the plugin does not subscribe to anyway.
    static let inputSnippetKeys = ["new_string", "old_string", "content"]
    /// `tool_response` keys that hold text a tool returned.
    static let outputSnippetKeys = ["content", "stdout", "output"]

    public static func parse(
        data: Data,
        fallbackEvent: String?,
        timestamp: Double,
        limits: ClaudeHookLimits = .default,
        snippetLimits: ClaudeSnippetLimits = .default
    ) -> Payload? {
        guard let record = ClaudeHookInputParser.parse(
            data: data,
            fallbackEvent: fallbackEvent,
            timestamp: timestamp,
            limits: limits
        ) else { return nil }

        // Only tool events carry content worth excerpting. Re-decoding is cheap
        // next to a network round trip, and it keeps the local parser — which
        // must never learn to extract content — untouched.
        guard record.event == .postToolUse,
              data.count <= limits.maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            return Payload(record: record, snippets: [])
        }

        return Payload(
            record: record,
            snippets: snippets(in: payload, toolName: record.toolName, limits: snippetLimits)
        )
    }

    static func snippets(
        in payload: [String: Any],
        toolName: String?,
        limits: ClaudeSnippetLimits
    ) -> [ClaudeContentSnippet] {
        let tool = toolName.map { ClaudeTextSanitizer.sanitize($0, maxBytes: 64) } ?? "tool"
        var result: [ClaudeContentSnippet] = []

        func append(label: String, kind: ClaudeContentSnippetKind, raw: String) {
            guard result.count < limits.maxSnippetsPerRecord else { return }
            let text = ClaudeTextSanitizer.sanitize(raw, maxBytes: limits.maxSnippetBytes)
            guard !text.isEmpty else { return }
            result.append(
                ClaudeContentSnippet(
                    label: ClaudeTextSanitizer.sanitize(label, maxBytes: limits.maxLabelBytes),
                    kind: kind,
                    text: text
                )
            )
        }

        if let toolInput = payload["tool_input"] as? [String: Any] {
            for key in inputSnippetKeys {
                guard let value = toolInput[key] as? String else { continue }
                append(label: "\(tool) \(key)", kind: .toolInput, raw: value)
            }
        }

        // A tool response is a string for some tools and an object for others.
        // Both shapes are handled; anything else is simply not excerpted.
        if let text = payload["tool_response"] as? String {
            append(label: "\(tool) response", kind: .toolOutput, raw: text)
        } else if let response = payload["tool_response"] as? [String: Any] {
            for key in outputSnippetKeys {
                guard let value = response[key] as? String else { continue }
                append(label: "\(tool) \(key)", kind: .toolOutput, raw: value)
            }
            // `Read` nests its text one level down.
            if let file = response["file"] as? [String: Any],
               let content = file["content"] as? String {
                append(label: "\(tool) file", kind: .toolOutput, raw: content)
            }
        }

        return result
    }
}

/// Namespacing for remote session ids.
///
/// Two hosts pick their own session ids and cannot coordinate, so a bare
/// `session_id` is not a key — it is a claim. Scoping it under the id of the
/// host whose TOKEN authenticated the request makes the key ours: a host can
/// only ever name sessions inside its own namespace, and it cannot spell a local
/// session's id at all.
public enum ClaudeRemoteSessionScope {
    /// Prefix no locally-published session id can collide with: a local id comes
    /// from Claude Code and is a bare UUID.
    public static let prefix = "remote:"

    public static func scopedSessionID(hostID: String, sessionID: String) -> String {
        "\(prefix)\(hostID):\(sessionID)"
    }

    public static func isScoped(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(prefix)
    }

    /// Transport channel label for a host, used as `ClaudeTransportOrigin.remote`'s
    /// channel. Identifies WHICH remote, so two hosts never share an origin.
    public static func channel(hostID: String) -> String {
        "ssh:\(hostID)"
    }
}
