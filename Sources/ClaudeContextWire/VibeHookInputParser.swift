import Foundation

/// Turns a Mistral Vibe CLI hook payload into our bounded wire records.
///
/// Vibe (2.25) has three hook types — `pre_tool`, `post_tool`, `post_agent` —
/// and every payload carries `session_id`, `parent_session_id`,
/// `transcript_path`, `cwd` and `hook_event_name`. There is no session-start,
/// prompt-submit or session-end event, so a session first exists for us at its
/// first file-tool call or at the end of its first turn, and it ends by pid
/// liveness and TTL rather than by an explicit record.
///
/// Like `ClaudeHookInputParser` this is an allowlist:
///
/// * `tool_output`, `tool_output_text`, `tool_error` — dropped. File content
///   never crosses the socket.
/// * `tool_input` — dropped except `file_path`.
/// * `transcript_path` — never crosses the wire. It is handed to the publisher
///   (`VibeHookInput.transcriptPath`) for the one read documented in
///   `docs/agent/invariants.md`: the last user message, because no Vibe hook
///   payload carries the prompt.
public enum VibeHookInputParser {
    /// Vibe's built-in tools that name one file in `tool_input.file_path`.
    static let editingTools: Set<String> = ["write_file", "edit"]
    public static let fileTools: Set<String> = editingTools.union(["read_file"])

    /// Cap on the hook payload read from stdin. Far above the wire's line
    /// limit on purpose: a `post_tool` payload embeds the tool's whole output
    /// (a `read_file` result carries the file), none of which is kept, and
    /// holding it to 64 KiB would drop the touch of every file worth reading.
    public static let maxPayloadBytes = 8 * 1024 * 1024

    public static func parse(data: Data) -> VibeHookInput? {
        guard data.count <= maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return nil }

        let kind: VibeHookInput.Kind
        switch payload["hook_event_name"] as? String {
        case "post_tool": kind = .postTool
        case "post_agent": kind = .postAgent
        default: return nil
        }

        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return nil }

        // A subagent's hooks fire with the parent's id in `parent_session_id`
        // (subagents inherit the hook configuration). Its activity is not the
        // session the user is typing into, so it is dropped. Vibe always writes
        // the field, `null` at top level, so a payload WITHOUT it is not
        // provably top-level and is dropped too.
        guard payload["parent_session_id"] is NSNull else { return nil }

        let cwd = payload["cwd"] as? String
        let toolName = payload["tool_name"] as? String
        return VibeHookInput(
            kind: kind,
            sessionID: sessionID,
            cwd: cwd,
            toolName: toolName,
            files: kind == .postTool ? filePaths(in: payload, toolName: toolName, cwd: cwd) : [],
            transcriptPath: payload["transcript_path"] as? String
        )
    }

    /// `tool_input.file_path` of a known file tool, made absolute.
    ///
    /// Vibe passes the model's raw argument, which is often relative to the
    /// session's cwd (measured on 2.25.4: `{"file_path": "note.txt"}`), so a
    /// relative path is resolved against the payload's `cwd`. Anything that
    /// still is not absolute is dropped.
    static func filePaths(in payload: [String: Any], toolName: String?, cwd: String?) -> [ClaudeFileTouch] {
        guard let toolName, fileTools.contains(toolName),
              let toolInput = payload["tool_input"] as? [String: Any],
              let raw = toolInput["file_path"] as? String, !raw.isEmpty
        else { return [] }

        let path: String
        if raw.hasPrefix("/") {
            path = raw
        } else if let cwd, cwd.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(raw)
        } else {
            return []
        }
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return [] }
        return [ClaudeFileTouch(path: standardized, kind: editingTools.contains(toolName) ? .edited : .read)]
    }
}

/// One parsed Vibe hook invocation. Not a wire type: `records(prompt:timestamp:)`
/// produces what crosses the socket.
public struct VibeHookInput: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case postTool
        case postAgent
    }

    public var kind: Kind
    public var sessionID: String
    public var cwd: String?
    public var toolName: String?
    public var files: [ClaudeFileTouch]
    /// Local to the publisher process. Never encoded.
    public var transcriptPath: String?

    /// The wire records for this invocation, in send order.
    ///
    /// A non-empty prompt goes first as `UserPromptSubmit`, so the event record
    /// after it leaves the session's activity correct: `Stop` ends the turn,
    /// `PostToolUse` keeps it working.
    public func records(
        prompt: String?,
        timestamp: Double,
        limits: ClaudeHookLimits = .default
    ) -> [ClaudeHookRecord] {
        var records: [ClaudeHookRecord] = []
        if let prompt, !prompt.isEmpty {
            records.append(ClaudeHookRecord(
                event: .userPromptSubmit,
                agent: .vibe,
                sessionID: sessionID,
                timestamp: timestamp,
                rawCwd: cwd,
                prompt: prompt
            ))
        }
        switch kind {
        case .postTool:
            records.append(ClaudeHookRecord(
                event: .postToolUse,
                agent: .vibe,
                sessionID: sessionID,
                timestamp: timestamp,
                rawCwd: cwd,
                toolName: toolName,
                files: files
            ))
        case .postAgent:
            records.append(ClaudeHookRecord(
                event: .stop,
                agent: .vibe,
                sessionID: sessionID,
                timestamp: timestamp,
                rawCwd: cwd
            ))
        }
        return records.map { ClaudeHookWireCodec.clamp($0, limits: limits) }
    }
}
