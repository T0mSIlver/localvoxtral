import Foundation

/// The wire contract between the Claude Code hook publisher
/// (`localvoxtral-claude-hook`) and the in-app broker.
///
/// Deliberately dependency-free (Foundation only) so the same types compile on
/// macOS for the app and on Linux for a remote/SSH publisher build.
///
/// Format: one JSON object per line (NDJSON), UTF-8, `\n` terminated, with a
/// mandatory integer `v`. Readers reject any version they were not written
/// against rather than guessing — a record whose shape we do not understand is
/// dropped, never partially trusted.
public enum ClaudeHookWire {
    /// Current wire version. Bump on any incompatible field change.
    ///
    /// v2 added the `agent` field (absent = `.claude`) and the `FocusChanged`
    /// event for the opencode integration.
    public static let version = 2

    /// Versions this build still reads. v1 is the pre-agent wire: every v1
    /// record is, by definition, a Claude Code record, so v1 lines decode with
    /// `agent == .claude` rather than being dropped — the publisher binary and
    /// the app usually ship together, but a stale installed plugin pointing at
    /// an old publisher must not silently lose all context after an update.
    public static let readableVersions: Set<Int> = [1, 2]
}

/// Which coding agent published a record. Content, not trust: trust stays a
/// property of the transport (`ClaudeTransportOrigin`), and every local agent
/// publishes over the same peer-authenticated socket. What the agent tag
/// decides is session-id namespacing (`ClaudeAgentSessionScope`) and
/// per-agent channel rules — e.g. the broker never returns a title marker to
/// an opencode session, because opencode owns its window title the way herdr
/// owns its pane titles.
///
/// Decoding an unknown agent name is a drop, mirroring unknown events: a
/// newer plugin talking to an older app degrades to "ignored", and an agent
/// whose channel rules we do not know must not inherit another's.
public enum ClaudeHookAgent: String, Sendable, Equatable, CaseIterable, Codable {
    case claude
    case opencode
}

/// Namespacing for per-agent session ids, mirroring `ClaudeRemoteSessionScope`.
///
/// Two agents pick their own session ids and cannot coordinate — Claude Code
/// uses bare UUIDs, opencode uses `ses_…` — so a bare id is a claim, not a
/// key. Scoping opencode ids under a prefix no Claude-published UUID can carry
/// makes cross-agent collision structurally impossible. Applied by the
/// RECEIVER (`ClaudeSessionRegistry.ingest`), never trusted from the wire, so
/// a publisher cannot pre-scope itself into another namespace being honest or
/// otherwise — the registry recomputes the key from the agent tag every time.
/// (A local peer lying about its agent tag is a same-UID process and already
/// outside the threat model, same as the remote scope's note on host ids.)
public enum ClaudeAgentSessionScope {
    /// Distinct from `ClaudeRemoteSessionScope.prefix` ("remote:") — the two
    /// namespaces must never alias.
    public static let opencodePrefix = "opencode:"

    public static func scopedSessionID(agent: ClaudeHookAgent, sessionID: String) -> String {
        switch agent {
        case .claude:
            return sessionID
        case .opencode:
            return opencodePrefix + sessionID
        }
    }
}

/// Hook events the plugin publishes. Cases map 1:1 to Claude Code hook names.
///
/// Decoding an unknown event name yields `nil` rather than throwing: a newer
/// plugin talking to an older app must degrade to "ignored", not "broker error".
public enum ClaudeHookEvent: String, Sendable, Equatable, CaseIterable, Codable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case cwdChanged = "CwdChanged"
    case postToolUse = "PostToolUse"
    /// Claude Code only fires `FileChanged` for a hook that declares
    /// `watchPaths`. The plugin declares none — `PostToolUse` already tells us
    /// about every file the model touches, and watching the user's tree would
    /// mean firing on every unrelated `git checkout` — so nothing sends this
    /// today.
    ///
    /// The wire case and its parser support stay for the day we do declare
    /// watchPaths; the dead HOOK is what was removed, not the ability to read
    /// the event. See `ClaudeHookInputParser.filePaths` for its classification.
    case fileChanged = "FileChanged"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    /// Published by the opencode plugin's TUI half only (v2): "the pane on
    /// this TTY currently displays this session". One opencode process hosts
    /// several sessions on one terminal, so per-session TTY claims cannot
    /// disambiguate them — an explicit, freshness-bounded focus declaration
    /// can. Claude Code never sends this; nothing in its hook set knows what a
    /// pane displays.
    case focusChanged = "FocusChanged"
    /// The pane left its session view (v2, opencode TUI half only): "this TTY
    /// no longer displays the named session". Retracts the pane's focus
    /// declaration immediately instead of letting it linger until TTL — a
    /// user who navigated home is not dictating into the session they left.
    /// The named session is the one being retracted; the registry clears the
    /// TTY's declaration regardless, because a clear can only ever widen
    /// abstention.
    case focusCleared = "FocusCleared"
}

/// Hard bounds applied at BOTH ends of the wire.
///
/// The publisher truncates to these before sending; the broker re-applies them
/// on decode and never trusts that the sender did. A hostile or buggy peer
/// cannot make the app allocate unboundedly.
public struct ClaudeHookLimits: Sendable, Equatable {
    /// Max bytes for one NDJSON line, including the newline. A line longer than
    /// this is dropped whole — we do not attempt to salvage a prefix.
    public var maxLineBytes: Int
    /// Max UTF-8 bytes of a prompt we retain.
    public var maxPromptBytes: Int
    /// Max UTF-8 bytes of any single path-ish or identifier string.
    public var maxPathBytes: Int
    /// Max file paths carried by a single record.
    public var maxFilePathsPerRecord: Int

    public init(
        maxLineBytes: Int = 64 * 1024,
        maxPromptBytes: Int = 8 * 1024,
        maxPathBytes: Int = 4 * 1024,
        maxFilePathsPerRecord: Int = 16
    ) {
        self.maxLineBytes = maxLineBytes
        self.maxPromptBytes = maxPromptBytes
        self.maxPathBytes = maxPathBytes
        self.maxFilePathsPerRecord = maxFilePathsPerRecord
    }

    public static let `default` = ClaudeHookLimits()
}

/// Safe process/TTY metadata added by the publisher.
///
/// Everything here is about WHERE the session runs, never about what it
/// contains. No argv, no environment dump, no user text.
public struct ClaudeHookProcessInfo: Sendable, Equatable, Codable {
    /// The publisher's own pid. **Diagnostics only — never liveness.**
    ///
    /// The publisher is a one-shot process: it writes a line and exits, so this
    /// pid is dead within milliseconds of the record arriving. Probing it would
    /// mark every local session stale the moment it was created.
    public var hookPID: Int32
    /// The long-lived ancestor that spawned the hook — i.e. Claude Code itself.
    ///
    /// This is the pid the registry probes: it lives as long as the session
    /// does, which is exactly the question liveness asks.
    ///
    /// It is NOT simply the publisher's `getppid()` — the shim runs the
    /// publisher as a child (so it can survive a failed exec), which makes its
    /// parent a shell that exits immediately. The shim passes its own `$PPID`
    /// instead; see `ClaudeHookPublisher.claudeAncestorPID`.
    public var claudePID: Int32
    /// Controlling TTY device path (e.g. `/dev/ttys004`), when the hook ran
    /// attached to one.
    public var tty: String?
    /// `$TERM_PROGRAM` (e.g. `ghostty`, `iTerm.app`), when set.
    public var termProgram: String?
    /// herdr pane identity, published only when the hook ran inside a herdr pane.
    public var herdrPaneID: String?
    /// The herdr JSON API socket path herdr injected into the pane environment.
    public var herdrSocketPath: String?
    /// cmux surface identity, published only when the hook ran inside a cmux
    /// surface. Same shape and same trust as the herdr pair: a LOCAL session's
    /// values, vouched for by the AF_UNIX peer-UID check, naming things on this
    /// machine. A remote session's equivalents never land here — they arrive as
    /// request headers and stay in `ClaudeRemoteSessionEnvironment`.
    public var cmuxSurfaceID: String?
    /// The cmux control socket path from the surface environment.
    public var cmuxSocketPath: String?
    /// `$CLAUDE_CODE_BRIDGE_SESSION_ID` — the browser-side session handle a
    /// Remote Control bridge injects, when this session is driven by one.
    public var bridgeSessionID: String?

    public init(
        hookPID: Int32,
        claudePID: Int32,
        tty: String? = nil,
        termProgram: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil,
        cmuxSurfaceID: String? = nil,
        cmuxSocketPath: String? = nil,
        bridgeSessionID: String? = nil
    ) {
        self.hookPID = hookPID
        self.claudePID = claudePID
        self.tty = tty
        self.termProgram = termProgram
        self.herdrPaneID = herdrPaneID
        self.herdrSocketPath = herdrSocketPath
        self.cmuxSurfaceID = cmuxSurfaceID
        self.cmuxSocketPath = cmuxSocketPath
        self.bridgeSessionID = bridgeSessionID
    }

    enum CodingKeys: String, CodingKey {
        case hookPID = "hook_pid"
        case claudePID = "claude_pid"
        case tty
        case termProgram = "term_program"
        case herdrPaneID = "herdr_pane_id"
        case herdrSocketPath = "herdr_socket_path"
        case cmuxSurfaceID = "cmux_surface_id"
        case cmuxSocketPath = "cmux_socket_path"
        case bridgeSessionID = "bridge_session_id"
    }
}

/// How a file path was touched, derived from the tool that reported it.
public enum ClaudeFileTouchKind: String, Sendable, Equatable, Codable {
    case read
    case edited
}

/// One file path plus how it was touched.
public struct ClaudeFileTouch: Sendable, Equatable, Codable {
    public var path: String
    public var kind: ClaudeFileTouchKind

    public init(path: String, kind: ClaudeFileTouchKind) {
        self.path = path
        self.kind = kind
    }
}

/// A normalized, bounded hook record as it crosses the socket.
///
/// Note what is absent and stays absent:
///
/// * `transcript_path` — the publisher drops it. We never scrape transcript
///   contents, so carrying the path would only be a liability.
/// * `origin`/trust fields — trust is a property of the TRANSPORT, decided by
///   the broker from peer credentials (see `ClaudeTransportOrigin`). A sender
///   cannot describe itself as trusted. `init(from:)` ignores any such key.
public struct ClaudeHookRecord: Sendable, Equatable {
    public var version: Int
    public var event: ClaudeHookEvent
    /// Which coding agent published this. Encoded only when it is not the
    /// default `.claude`, so v1 readers' "absent field" and v2's default agree
    /// byte-for-byte on every Claude record.
    public var agent: ClaudeHookAgent
    public var sessionID: String
    /// Seconds since the UNIX epoch, as stamped by the publisher.
    public var timestamp: Double
    /// The session's working directory as the hook reported it. Raw and
    /// UNTRUSTED at this layer — only `ClaudeWorkspaceReference.make` decides
    /// whether it may ever become a local filesystem path.
    public var rawCwd: String?
    public var prompt: String?
    public var toolName: String?
    public var files: [ClaudeFileTouch]
    public var process: ClaudeHookProcessInfo?

    public init(
        version: Int = ClaudeHookWire.version,
        event: ClaudeHookEvent,
        agent: ClaudeHookAgent = .claude,
        sessionID: String,
        timestamp: Double,
        rawCwd: String? = nil,
        prompt: String? = nil,
        toolName: String? = nil,
        files: [ClaudeFileTouch] = [],
        process: ClaudeHookProcessInfo? = nil
    ) {
        self.version = version
        self.event = event
        self.agent = agent
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.rawCwd = rawCwd
        self.prompt = prompt
        self.toolName = toolName
        self.files = files
        self.process = process
    }
}

extension ClaudeHookRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case event
        case agent
        case sessionID = "session_id"
        case timestamp = "ts"
        case rawCwd = "cwd"
        case prompt
        case toolName = "tool_name"
        case files
        case process
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        event = try container.decode(ClaudeHookEvent.self, forKey: .event)
        // Absent means the default agent — that is what makes every v1 line
        // (which predates the field) a Claude record by construction. An
        // unknown agent NAME never reaches this decoder: `decodeLine` probes
        // and rejects it first, the same way it handles unknown events.
        agent = try container.decodeIfPresent(ClaudeHookAgent.self, forKey: .agent) ?? .claude
        sessionID = try container.decode(String.self, forKey: .sessionID)
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        rawCwd = try container.decodeIfPresent(String.self, forKey: .rawCwd)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        files = try container.decodeIfPresent([ClaudeFileTouch].self, forKey: .files) ?? []
        process = try container.decodeIfPresent(ClaudeHookProcessInfo.self, forKey: .process)
        // Any other key on the wire — notably an `origin`-shaped one — is
        // silently discarded here. That is the point: trust is not a field.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(event, forKey: .event)
        // Omitted when `.claude`: absence IS the default, so a Claude record's
        // bytes carry no agent key — the exact shape a v1 reader expects.
        if agent != .claude {
            try container.encode(agent, forKey: .agent)
        }
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(rawCwd, forKey: .rawCwd)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encode(files, forKey: .files)
        try container.encodeIfPresent(process, forKey: .process)
    }
}

/// Errors surfaced while turning a wire line into a record.
public enum ClaudeHookWireError: Error, Equatable {
    /// Line exceeded `ClaudeHookLimits.maxLineBytes`.
    case lineTooLong(bytes: Int)
    /// `v` was absent or not a version this build understands.
    case unsupportedVersion(Int?)
    /// Event name we do not know (e.g. from a newer plugin).
    case unknownEvent(String?)
    /// Agent name we do not know. Dropped for the same reason as an unknown
    /// event — and additionally because per-agent channel rules (marker
    /// emission, session namespacing) cannot be applied to an agent this build
    /// has never heard of.
    case unknownAgent(String?)
    /// Malformed JSON, or a required field missing.
    case malformed
    /// `session_id` was empty — the record cannot be attributed.
    case missingSessionID
}

public enum ClaudeHookWireCodec {
    /// Encode a record to a single NDJSON line (trailing `\n` included),
    /// clamping every bounded field first.
    ///
    /// Returns nil if the record still exceeds `maxLineBytes` after clamping,
    /// which the publisher treats as "drop it" rather than "send a truncated
    /// object that will not parse".
    public static func encodeLine(
        _ record: ClaudeHookRecord,
        limits: ClaudeHookLimits = .default
    ) -> Data? {
        let clamped = clamp(record, limits: limits)
        let encoder = JSONEncoder()
        // Stable key order keeps golden-line tests meaningful.
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(clamped) else { return nil }
        data.append(0x0A)
        guard data.count <= limits.maxLineBytes else { return nil }
        return data
    }

    /// Decode one NDJSON line, re-applying every bound regardless of what the
    /// sender claims to have done.
    public static func decodeLine(
        _ line: Data,
        limits: ClaudeHookLimits = .default
    ) throws -> ClaudeHookRecord {
        guard line.count <= limits.maxLineBytes else {
            throw ClaudeHookWireError.lineTooLong(bytes: line.count)
        }
        let trimmed = stripTrailingNewline(line)
        guard !trimmed.isEmpty else { throw ClaudeHookWireError.malformed }

        // Probe version/event before full decoding so we can report precisely
        // (and so an unknown event is "ignore", not "error").
        guard
            let object = try? JSONSerialization.jsonObject(with: trimmed),
            let dictionary = object as? [String: Any]
        else {
            throw ClaudeHookWireError.malformed
        }
        let claimedVersion = dictionary["v"] as? Int
        guard let claimedVersion, ClaudeHookWire.readableVersions.contains(claimedVersion) else {
            throw ClaudeHookWireError.unsupportedVersion(claimedVersion)
        }
        let eventName = dictionary["event"] as? String
        guard let eventName, ClaudeHookEvent(rawValue: eventName) != nil else {
            throw ClaudeHookWireError.unknownEvent(eventName)
        }
        // Probed like the event: an unknown agent must be a precise "ignored",
        // not a generic decode failure — and never a fallthrough to `.claude`,
        // which would hand a future agent Claude's channel rules.
        if let agentValue = dictionary["agent"] {
            // No v1 writer ever emitted this key — v1 predates it, and
            // "absent = claude" is the entire v1 compatibility contract. A v1
            // line that carries it anyway is not an old publisher; it is a
            // malformed or hand-crafted record, and it is dropped as such.
            guard claimedVersion >= 2 else {
                throw ClaudeHookWireError.malformed
            }
            let agentName = agentValue as? String
            guard let agentName, ClaudeHookAgent(rawValue: agentName) != nil else {
                throw ClaudeHookWireError.unknownAgent(agentName)
            }
        }

        guard let record = try? JSONDecoder().decode(ClaudeHookRecord.self, from: trimmed) else {
            throw ClaudeHookWireError.malformed
        }
        guard !record.sessionID.isEmpty else {
            throw ClaudeHookWireError.missingSessionID
        }
        return clamp(record, limits: limits)
    }

    /// Split a byte buffer into complete NDJSON lines plus the unconsumed
    /// remainder. Used by the broker to handle arbitrary TCP-like chunking of
    /// a stream socket.
    ///
    /// A pending remainder longer than `maxLineBytes` is the caller's cue to
    /// drop the connection: a peer streaming a single unbounded line must not
    /// be able to grow our buffer forever.
    public static func splitLines(_ buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                lines.append(buffer[start..<index])
                start = buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        return (lines, Data(buffer[start..<buffer.endIndex]))
    }

    static func clamp(_ record: ClaudeHookRecord, limits: ClaudeHookLimits) -> ClaudeHookRecord {
        var clamped = record
        clamped.sessionID = truncate(record.sessionID, toUTF8Bytes: limits.maxPathBytes)
        clamped.prompt = record.prompt.map { truncate($0, toUTF8Bytes: limits.maxPromptBytes) }
        clamped.rawCwd = record.rawCwd.map { truncate($0, toUTF8Bytes: limits.maxPathBytes) }
        clamped.toolName = record.toolName.map { truncate($0, toUTF8Bytes: limits.maxPathBytes) }
        clamped.files = record.files.prefix(limits.maxFilePathsPerRecord).map {
            ClaudeFileTouch(path: truncate($0.path, toUTF8Bytes: limits.maxPathBytes), kind: $0.kind)
        }
        if var process = record.process {
            process.tty = process.tty.map { truncate($0, toUTF8Bytes: limits.maxPathBytes) }
            process.termProgram = process.termProgram.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            process.herdrPaneID = process.herdrPaneID.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            process.herdrSocketPath = process.herdrSocketPath.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            process.cmuxSurfaceID = process.cmuxSurfaceID.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            process.cmuxSocketPath = process.cmuxSocketPath.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            process.bridgeSessionID = process.bridgeSessionID.map {
                truncate($0, toUTF8Bytes: limits.maxPathBytes)
            }
            clamped.process = process
        }
        return clamped
    }

    /// Truncate on a Character boundary so the result is always valid UTF-8
    /// (a byte-slice truncation could split a multi-byte scalar and produce a
    /// string that fails to encode).
    static func truncate(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        var used = 0
        for character in value {
            let width = String(character).utf8.count
            if used + width > limit { break }
            result.append(character)
            used += width
        }
        return result
    }

    private static func stripTrailingNewline(_ line: Data) -> Data {
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)] == 0x0A || line[line.index(before: end)] == 0x0D {
            end = line.index(before: end)
        }
        return Data(line[line.startIndex..<end])
    }
}
