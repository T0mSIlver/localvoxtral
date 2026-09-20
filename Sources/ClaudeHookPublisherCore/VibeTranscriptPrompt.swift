import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The last prompt the user typed into a Vibe session, read from the session's
/// `messages.jsonl`.
///
/// This is the one place a session log is read, and only because no Vibe hook
/// payload carries the prompt (`docs/agent/invariants.md`). The read is bounded
/// on every axis: one file the hook payload named, which must be a regular file
/// called `messages.jsonl` owned by this user; only its tail; only a line whose
/// `role` is `user` and that Vibe did not inject itself; only its `content`
/// string, truncated to the wire's prompt limit. Assistant messages, reasoning,
/// tool calls and tool results are never decoded past their `role`.
public enum VibeTranscriptPrompt {
    public static let fileName = "messages.jsonl"

    /// How much of the file's end is read. A turn's tool results sit between
    /// the prompt and the end of the file, so a long turn can push the prompt
    /// out of the window; that costs the prompt, never correctness.
    public static let tailBytes = 512 * 1024

    public static func lastUserPrompt(
        atPath path: String?,
        limits: ClaudeHookLimits = .default
    ) -> String? {
        guard let path, path.hasPrefix("/"),
              (path as NSString).lastPathComponent == fileName,
              let tail = readTail(path: path)
        else { return nil }
        return lastUserPrompt(inTail: tail, limits: limits)
    }

    /// Newest-first scan of complete lines. The first line of a tail window is
    /// usually cut mid-record; it fails to parse and is skipped like any other
    /// line that is not a JSON object.
    static func lastUserPrompt(inTail tail: Data, limits: ClaudeHookLimits) -> String? {
        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any],
                  message["role"] as? String == "user"
            else { continue }
            // `injected` marks text Vibe wrote under the user role (a hook's
            // retry reason, a reminder). It is not something the user said.
            if message["injected"] as? Bool == true { continue }
            guard let content = message["content"] as? String else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return ClaudeHookWireCodec.truncate(trimmed, toUTF8Bytes: limits.maxPromptBytes)
        }
        return nil
    }

    /// The file's last `tailBytes`, or nil for anything that is not a regular
    /// file of ours. `O_NOFOLLOW` and the `fstat` on the OPEN descriptor keep
    /// the checks and the read on the same file.
    static func readTail(path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid()
        else { return nil }

        let size = Int(info.st_size)
        guard size > 0 else { return nil }
        let length = min(size, tailBytes)
        var buffer = [UInt8](repeating: 0, count: length)
        var filled = 0
        while filled < length {
            let offset = filled
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress!.advanced(by: offset), length - offset, off_t(size - length + offset))
            }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            filled += count
        }
        guard filled > 0 else { return nil }
        return Data(buffer[0..<filled])
    }
}
