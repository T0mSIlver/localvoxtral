import Foundation

/// Turns Claude Code's raw hook stdin JSON into our bounded wire record.
///
/// This is where the "what do we keep" decision lives, and it is an allowlist,
/// not a filter. Claude Code's hook payload carries plenty we deliberately drop:
///
/// * `transcript_path` — dropped. We do not scrape transcript contents, so we
///   do not carry the pointer either.
/// * `tool_input` / `tool_response` bodies — dropped except for the specific
///   path-shaped keys below. File CONTENT (`Write.content`, `Edit.new_string`,
///   command strings, `Read` output) never crosses the socket.
/// * any `origin`-ish key — dropped. Trust comes from the transport.
public enum ClaudeHookInputParser {
    /// Tool-input keys that name a single file. Everything else in `tool_input`
    /// is ignored.
    static let filePathKeys = ["file_path", "notebook_path"]

    /// Tools whose PostToolUse means "the model changed this file"; anything
    /// else path-bearing counts as a read.
    ///
    /// No `MultiEdit`: it is deprecated in Claude Code, and `Edit` now carries
    /// batches itself.
    static let editingTools: Set<String> = ["Edit", "Write", "NotebookEdit"]

    /// Parse the raw hook JSON.
    ///
    /// - Parameters:
    ///   - data: raw stdin bytes.
    ///   - fallbackEvent: the event name passed on argv by the shim, used when
    ///     the payload omits `hook_event_name`.
    ///   - timestamp: publisher-stamped epoch seconds (injected for tests).
    /// - Returns: nil when the payload is unusable (bad JSON, unknown event,
    ///   no session id). Callers treat nil as "exit 0 quietly".
    public static func parse(
        data: Data,
        fallbackEvent: String?,
        timestamp: Double,
        limits: ClaudeHookLimits = .default
    ) -> ClaudeHookRecord? {
        guard data.count <= limits.maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return nil }

        let eventName = (payload["hook_event_name"] as? String) ?? fallbackEvent
        guard let eventName, let event = ClaudeHookEvent(rawValue: eventName) else { return nil }

        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return nil }

        let toolName = payload["tool_name"] as? String
        var record = ClaudeHookRecord(
            event: event,
            sessionID: sessionID,
            timestamp: timestamp,
            rawCwd: workingDirectory(in: payload, event: event),
            prompt: payload["prompt"] as? String,
            toolName: toolName,
            files: filePaths(in: payload, event: event, toolName: toolName)
        )
        record.version = ClaudeHookWire.version
        return ClaudeHookWireCodec.clamp(record, limits: limits)
    }

    /// The session's working directory.
    ///
    /// `CwdChanged` reports the destination in `new_cwd`; its `cwd` is the OLD
    /// directory. Reading `cwd` there would move the session backwards on every
    /// change — the one event whose entire purpose is to move it forwards.
    static func workingDirectory(in payload: [String: Any], event: ClaudeHookEvent) -> String? {
        if event == .cwdChanged, let newCwd = payload["new_cwd"] as? String, !newCwd.isEmpty {
            return newCwd
        }
        return payload["cwd"] as? String
    }

    /// Extract path-shaped values from the payload.
    ///
    /// Handles the two shapes we see: a `tool_input` object (PostToolUse) and a
    /// top-level `file_path`/`file_paths` (FileChanged).
    static func filePaths(
        in payload: [String: Any],
        event: ClaudeHookEvent,
        toolName: String?
    ) -> [ClaudeFileTouch] {
        // FileChanged means the bytes on disk changed — that is an edit by
        // definition, and it carries no tool name to infer it from. Falling
        // through to the tool lookup would misfile every one of them as a read.
        let kind: ClaudeFileTouchKind
        if event == .fileChanged {
            kind = .edited
        } else if let toolName, editingTools.contains(toolName) {
            kind = .edited
        } else {
            kind = .read
        }

        var paths: [String] = []
        if let toolInput = payload["tool_input"] as? [String: Any] {
            for key in filePathKeys {
                if let path = toolInput[key] as? String { paths.append(path) }
            }
        }
        for key in filePathKeys {
            if let path = payload[key] as? String { paths.append(path) }
        }
        if let list = payload["file_paths"] as? [String] {
            paths.append(contentsOf: list)
        }

        // Absolute paths only, de-duplicated, order preserved. A relative path
        // is unresolvable from here (our cwd is not the session's) and a
        // non-path string is not ours to guess at.
        var seen = Set<String>()
        return paths.compactMap { path -> ClaudeFileTouch? in
            guard path.hasPrefix("/"), !seen.contains(path) else { return nil }
            seen.insert(path)
            return ClaudeFileTouch(path: path, kind: kind)
        }
    }
}
