import Foundation

/// Turns an OpenAI Codex CLI hook payload into our bounded wire record.
///
/// Codex's hooks are a near clone of Claude Code's (measured on 0.156.0, the
/// payloads in `Tests/CodexHookPayloads`): the same event names, `session_id`,
/// `cwd`, `hook_event_name`, the prompt on `UserPromptSubmit`. What differs:
///
/// * There is no read tool. The model reads through `Bash`, whose input is a
///   shell command, so only `apply_patch` names files, and only inside its
///   patch text (`tool_input.command`), as `*** Add File:`, `*** Update File:`
///   and `*** Move to:` headers. Paths are whatever the model wrote, absolute
///   or relative to the session's `cwd`.
/// * A subagent's events carry the PARENT's `session_id` plus an `agent_id`.
///   Its file edits are the session's (same process, same pane, same repo) and
///   are kept; a prompt it submits is not the user's and is dropped, because
///   the prompt block and the learned fixes read it as what the user typed.
///
/// Like `ClaudeHookInputParser` this is an allowlist. `transcript_path`,
/// `model`, `permission_mode`, `turn_id`, `tool_response`,
/// `last_assistant_message` and every other `tool_input` field are dropped:
/// file content never crosses the socket.
public enum CodexHookInputParser {
    /// Events the shipped plugin hooks (`integrations/codex`), mapped onto
    /// the wire. Anything else parses to nil.
    static let events: [String: ClaudeHookEvent] = [
        "SessionStart": .sessionStart,
        "UserPromptSubmit": .userPromptSubmit,
        "PostToolUse": .postToolUse,
        "Stop": .stop,
        // Codex asks the user to approve a tool call (#717). Published as a
        // wait, with none of its `tool_input`.
        "PermissionRequest": .notification,
        "SessionEnd": .sessionEnd,
    ]

    /// The one Codex tool that names files.
    static let patchTool = "apply_patch"

    /// Headers of the patch text that name a file whose new content exists
    /// after the patch. `*** Delete File:` is left out: there is nothing left
    /// to read.
    static let patchFileHeaders = ["*** Add File: ", "*** Update File: ", "*** Move to: "]

    /// Cap on the hook payload read from stdin. An `apply_patch` payload
    /// carries the whole patch, which for a new file is the whole file; none
    /// of it is kept, and a smaller cap would lose the touch of every large
    /// edit. Vibe's cap, for the same reason.
    public static let maxPayloadBytes = 8 * 1024 * 1024

    /// - Returns: nil when the payload is unusable (bad JSON, an event we do
    ///   not publish, no session id). Callers treat nil as "exit 0 quietly".
    public static func parse(
        data: Data,
        timestamp: Double,
        limits: ClaudeHookLimits = .default
    ) -> ClaudeHookRecord? {
        guard data.count <= maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let eventName = payload["hook_event_name"] as? String,
              let event = events[eventName],
              let sessionID = payload["session_id"] as? String, !sessionID.isEmpty
        else { return nil }

        let isSubagent = (payload["agent_id"] as? String).map { !$0.isEmpty } ?? false
        if event == .userPromptSubmit, isSubagent { return nil }

        let cwd = payload["cwd"] as? String
        let toolName = event == .postToolUse ? payload["tool_name"] as? String : nil
        let record = ClaudeHookRecord(
            event: event,
            agent: .codex,
            sessionID: sessionID,
            timestamp: timestamp,
            rawCwd: cwd,
            prompt: event == .userPromptSubmit ? payload["prompt"] as? String : nil,
            toolName: toolName,
            files: toolName == patchTool ? patchedFiles(in: payload, cwd: cwd) : [],
            notificationType: event == .notification ? .permissionPrompt : nil
        )
        return ClaudeHookWireCodec.clamp(record, limits: limits)
    }

    /// The files an `apply_patch` call leaves behind, made absolute,
    /// de-duplicated, in patch order.
    static func patchedFiles(in payload: [String: Any], cwd: String?) -> [ClaudeFileTouch] {
        guard let toolInput = payload["tool_input"] as? [String: Any],
              let patch = toolInput["command"] as? String
        else { return [] }

        var seen = Set<String>()
        var touches: [ClaudeFileTouch] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let header = patchFileHeaders.first(where: { line.hasPrefix($0) }) else { continue }
            let raw = String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
            guard let path = absolutePath(raw, cwd: cwd), seen.insert(path).inserted else { continue }
            touches.append(ClaudeFileTouch(path: path, kind: .edited))
        }
        return touches
    }

    /// A relative path resolves against the payload's `cwd`; anything that
    /// still is not absolute is dropped.
    static func absolutePath(_ raw: String, cwd: String?) -> String? {
        guard !raw.isEmpty else { return nil }
        let path: String
        if raw.hasPrefix("/") {
            path = raw
        } else if let cwd, cwd.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(raw)
        } else {
            return nil
        }
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix("/") ? standardized : nil
    }
}
