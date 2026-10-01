import ClaudeContextWire
import Foundation

/// A Codex session's title, `thread_name`, read from Codex's
/// `session_index.jsonl` (#1020). No Codex hook payload carries it.
///
/// Codex appends a line `{"id", "thread_name", "updated_at"}` whenever it
/// names or renames a thread (0.156.0, measured 2026-09-28), so the newest
/// line for an id is its current name. The read is bounded like
/// `VibeTranscriptPrompt`'s: one regular file owned by this user, its tail
/// only, only lines that name the session's id, only the `thread_name`
/// string.
public enum CodexSessionIndex {
    public static let fileName = "session_index.jsonl"

    /// A line is about 140 bytes, so this holds the last few hundred renames.
    /// A session named before them loses its title, never correctness.
    public static let tailBytes = 64 * 1024

    /// `$CODEX_HOME/session_index.jsonl`, else `~/.codex/session_index.jsonl`.
    public static func path(variables: [String: String]) -> String? {
        if let home = variables["CODEX_HOME"], home.hasPrefix("/") {
            return (home as NSString).appendingPathComponent(fileName)
        }
        guard let home = variables["HOME"], home.hasPrefix("/") else { return nil }
        return (home as NSString).appendingPathComponent(".codex/" + fileName)
    }

    public static func threadName(sessionID: String, atPath path: String?) -> String? {
        guard let path, !sessionID.isEmpty,
              let tail = VibeTranscriptPrompt.readTail(path: path, tailBytes: tailBytes)
        else { return nil }
        return threadName(sessionID: sessionID, inTail: tail)
    }

    /// The same read, abandoned after `deadline` seconds, for the reason
    /// `VibeTranscriptPrompt.lastUserPrompt(atPath:limits:deadline:read:)`
    /// gives: a stalled volume must not hold the hook past Codex's timeout.
    public static func threadName(
        sessionID: String,
        atPath path: String?,
        deadline: TimeInterval
    ) -> String? {
        let result = DeadlineResult()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.set(threadName(sessionID: sessionID, atPath: path))
            done.signal()
        }
        thread.start()
        guard done.wait(timeout: .now() + deadline) == .success else { return nil }
        return result.value
    }

    private final class DeadlineResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ name: String?) { lock.withLock { stored = name } }
        var value: String? { lock.withLock { stored } }
    }

    /// Newest-first scan. The id is matched as bytes before a line is
    /// parsed, so no other session's line is decoded.
    static func threadName(sessionID: String, inTail tail: Data) -> String? {
        let needle = Data(sessionID.utf8)
        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard line.range(of: needle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any],
                  entry["id"] as? String == sessionID,
                  let name = entry["thread_name"] as? String
            else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
