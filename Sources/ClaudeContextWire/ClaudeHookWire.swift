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
    public static let version = 1
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

    public init(hookPID: Int32, claudePID: Int32, tty: String? = nil, termProgram: String? = nil) {
        self.hookPID = hookPID
        self.claudePID = claudePID
        self.tty = tty
        self.termProgram = termProgram
    }

    enum CodingKeys: String, CodingKey {
        case hookPID = "hook_pid"
        case claudePID = "claude_pid"
        case tty
        case termProgram = "term_program"
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
}

/// Errors surfaced while turning a wire line into a record.
public enum ClaudeHookWireError: Error, Equatable {
    /// Line exceeded `ClaudeHookLimits.maxLineBytes`.
    case lineTooLong(bytes: Int)
    /// `v` was absent or not a version this build understands.
    case unsupportedVersion(Int?)
    /// Event name we do not know (e.g. from a newer plugin).
    case unknownEvent(String?)
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
        guard claimedVersion == ClaudeHookWire.version else {
            throw ClaudeHookWireError.unsupportedVersion(claimedVersion)
        }
        let eventName = dictionary["event"] as? String
        guard let eventName, ClaudeHookEvent(rawValue: eventName) != nil else {
            throw ClaudeHookWireError.unknownEvent(eventName)
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
