import Foundation

/// The skill names a remote host's shim reports (#1024): the names of the
/// skills and commands its coding agents can run, so polishing can spell
/// them when the user says one. The shim lists skill folders and command
/// files on the host; nothing else about them crosses.
///
/// Its own header, not an `X-Lvx-Env-*` one: a list is longer than the
/// environment's 200-byte value cap, and it is content rather than a label
/// about where a session runs. Every name is untrusted text that reaches the
/// polish prompt, so only names shaped like a folder name are kept.
public enum AgentSkillNamesCodec {
    /// The header the shim writes, in its canonical spelling.
    public static let headerName = "X-Lvx-Skills"

    /// How the parser keys it: `ClaudeRemoteHTTPCodec` lowercases field names.
    public static var lowercasedHeaderName: String { headerName.lowercased() }

    /// Most bytes of the value the shim sends. The whole request head is
    /// capped at 8 KiB (`ClaudeRemoteHTTPLimits`), and the environment
    /// headers take at most 1 KiB of it.
    public static let maxValueBytes = 2048
    public static let maxNames = 80
    public static let maxNameBytes = 64

    /// A folder name: ASCII letters, digits, `.`, `_` and `-`, not starting
    /// with a dot or a dash.
    public static func isAcceptableName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...maxNameBytes).contains(bytes.count), bytes[0] != UInt8(ascii: "."),
              bytes[0] != UInt8(ascii: "-")
        else { return false }
        return bytes.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// The names a request reports, or nil when it carries no header (an
    /// older shim, or an event that does not list them). An over-long value
    /// reports nothing rather than a truncated list; a malformed name is
    /// dropped and the rest kept.
    public static func names(in headers: [String: String]) -> [String]? {
        guard let value = headers[lowercasedHeaderName] else { return nil }
        guard value.utf8.count <= maxValueBytes else { return [] }
        return accepted(value.split(separator: ",").map { String($0) })
    }

    /// Acceptable names, each once, in their first order, at most `maxNames`.
    public static func accepted(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where isAcceptableName(name) && seen.insert(name.lowercased()).inserted {
            result.append(name)
            if result.count == maxNames { break }
        }
        return result
    }
}
