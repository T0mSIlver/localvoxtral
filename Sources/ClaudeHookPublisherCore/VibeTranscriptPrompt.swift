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
/// called `messages.jsonl` owned by this user; only its tail; only a line that
/// Vibe wrote with `"role": "user"` and `"injected": false`; only its `content`
/// string, truncated to the wire's prompt limit. A line without the user-role
/// marker is never parsed, and nothing but the chosen `content` string is kept
/// or sent.
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

    /// The same read, abandoned after `deadline` seconds.
    ///
    /// `O_NONBLOCK` does nothing for a regular file: with `~/.vibe` on a
    /// stalled network or FUSE volume, `open` or `pread` can block past Vibe's
    /// hook timeout, and Vibe reports a timed-out hook on the user's turn. The
    /// read runs on its own thread; past the deadline the hook publishes
    /// without a prompt and exits, which ends the thread with the process.
    public static func lastUserPrompt(
        atPath path: String?,
        limits: ClaudeHookLimits = .default,
        deadline: TimeInterval,
        read: @escaping @Sendable (String?, ClaudeHookLimits) -> String? = {
            VibeTranscriptPrompt.lastUserPrompt(atPath: $0, limits: $1)
        }
    ) -> String? {
        let result = DeadlineResult()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.set(read(path, limits))
            done.signal()
        }
        thread.start()
        guard done.wait(timeout: .now() + deadline) == .success else { return nil }
        return result.value
    }

    private final class DeadlineResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ prompt: String?) { lock.withLock { stored = prompt } }
        var value: String? { lock.withLock { stored } }
    }

    /// How Vibe (`json.dumps`) and a compact encoder spell a user line's role.
    static let userRoleMarkers = [Data(#""role": "user""#.utf8), Data(#""role":"user""#.utf8)]

    /// Newest-first scan of complete lines. The first line of a tail window is
    /// usually cut mid-record; it fails to parse and is skipped like any other
    /// line that is not a JSON object.
    static func lastUserPrompt(inTail tail: Data, limits: ClaudeHookLimits) -> String? {
        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            // Assistant and tool lines stop here, unparsed. A tool line that
            // QUOTES the marker gets parsed and then fails the role check.
            guard userRoleMarkers.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any],
                  message["role"] as? String == "user"
            else { continue }
            // `injected` marks text Vibe wrote under the user role (a hook's
            // retry reason, a reminder). Required present and false: if a Vibe
            // update drops the field, losing the prompt is the safe failure.
            guard message["injected"] as? Bool == false,
                  let content = message["content"] as? String
            else { continue }
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
