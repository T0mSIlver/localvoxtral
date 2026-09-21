import Foundation

/// Turns a Mistral Vibe CLI hook payload into our bounded wire records.
///
/// Vibe (2.25) has three hook types — `pre_tool`, `post_tool`, `post_agent`.
/// There is no session-start, prompt-submit or session-end event, so a session
/// first exists for us at its first file-tool call or at the end of its first
/// turn, and it ends by pid liveness and TTL rather than by an explicit record.
///
/// Vibe has TWO hook runners, chosen per user by a server-side rollout
/// (`vibe_cli_unified_harness_rollout`), and they send different payloads:
///
/// * legacy (`vibe/core/hooks`): `session_id`, `parent_session_id`,
///   `transcript_path`, `cwd`, `hook_event_name`; tools `read_file`,
///   `write_file`, `edit`, the path in `tool_input.file_path`.
/// * Unified Harness (`mistralai_vibe_local_harness/vibe/_foreign_hooks.py`,
///   read at 0.5.1): `cwd` and `hook_event_name` only — no session id, no
///   parent, no transcript. Tools are group-qualified
///   (`file_system.read_file`, `file_system.write_file`,
///   `file_system.search_replace`) and read/write name the path in
///   `tool_input.path`.
///
/// Field failure 2026-09-21: requiring `session_id` dropped every payload of a
/// user on the unified rollout, silently, so their sessions never joined.
///
/// Like `ClaudeHookInputParser` this is an allowlist:
///
/// * `tool_output`, `tool_output_text`, `tool_error` — dropped. File content
///   never crosses the socket.
/// * `tool_input` — dropped except the path argument (`file_path` or `path`).
/// * `transcript_path` — never crosses the wire. It is handed to the publisher
///   (`VibeHookInput.transcriptPath`) for the one read documented in
///   `docs/agent/invariants.md`: the last user message, because no Vibe hook
///   payload carries the prompt.
public enum VibeHookInputParser {
    /// Vibe's built-in tools that name one file, under both runners' names.
    static let editingTools: Set<String> = [
        "write_file", "edit",
        "file_system.write_file", "file_system.search_replace",
    ]
    public static let fileTools: Set<String> = editingTools.union(["read_file", "file_system.read_file"])
    /// Where a file tool names its path: legacy tools and the unified
    /// `search_replace` use `file_path`, unified read/write use `path`.
    static let pathArguments = ["file_path", "path"]

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

        let sessionID: String?
        if payload["session_id"] == nil, payload["parent_session_id"] == nil {
            // The Unified Harness shape: the runner has a session id and does
            // not send it. The publisher names the session after the Vibe
            // process instead (`ClaudeHookPublisher.vibeProcessSessionID`).
            // This runner marks no subagent either. One runs inside the same
            // Vibe process, so its records count toward the session of the
            // pane it runs in.
            sessionID = nil
        } else {
            guard let id = payload["session_id"] as? String, !id.isEmpty else { return nil }
            // A subagent's hooks fire with the parent's id in
            // `parent_session_id` (subagents inherit the hook configuration).
            // Its activity is not the session the user is typing into, so it
            // is dropped. The legacy runner always writes the field, `null` at
            // top level, so a payload that has a session id WITHOUT it is not
            // provably top-level and is dropped too.
            guard payload["parent_session_id"] is NSNull else { return nil }
            sessionID = id
        }

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

    /// The path argument of a known file tool, made absolute.
    ///
    /// Vibe passes the model's raw argument, which is often relative to the
    /// session's cwd (measured on 2.25.4: `{"file_path": "note.txt"}`), so a
    /// relative path is resolved against the payload's `cwd`. Anything that
    /// still is not absolute is dropped.
    static func filePaths(in payload: [String: Any], toolName: String?, cwd: String?) -> [ClaudeFileTouch] {
        guard let toolName, fileTools.contains(toolName),
              let toolInput = payload["tool_input"] as? [String: Any],
              let raw = pathArguments.lazy.compactMap({ toolInput[$0] as? String }).first,
              !raw.isEmpty
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
    /// Nil for a Unified Harness payload, which carries none.
    public var sessionID: String?
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
    ///
    /// - Parameter processSessionID: the id a payload without one is published
    ///   under. With neither there is nothing to attribute the records to, and
    ///   none are produced.
    public func records(
        prompt: String?,
        timestamp: Double,
        processSessionID: String? = nil,
        limits: ClaudeHookLimits = .default
    ) -> [ClaudeHookRecord] {
        guard let sessionID = sessionID ?? processSessionID else { return [] }
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
