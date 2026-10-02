import Foundation

/// The repositories a remote host's coding agents worked in (#1027), as its
/// shim reports them on SessionStart: read from the host's Claude Code
/// transcripts, so a repository is listed before a dictation ever joins a
/// session in it. Each entry is `<epoch>:<name>:<repository>`, comma
/// separated, newest first: when an agent last worked there, the main
/// checkout's folder name, and its `origin` as `X-Lvx-Env-Repository`
/// spells it.
///
/// Every field is untrusted text that reaches the polish prompt, so an entry
/// is kept only when its name is shaped like a folder name and its
/// repository like a remote.
public enum AgentProjectsCodec {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let repository: String
        public let lastActive: Date

        public init(name: String, repository: String, lastActive: Date) {
            self.name = name
            self.repository = repository
            self.lastActive = lastActive
        }
    }

    public static let headerName = "X-Lvx-Agent-Projects"
    public static var lowercasedHeaderName: String { headerName.lowercased() }

    /// The shim's caps; the request head is capped at 8 KiB.
    public static let maxValueBytes = 2048
    public static let maxEntries = 30
    public static let maxRepositoryBytes = 200

    /// The entries a request reports, or nil when it carries no header. An
    /// over-long value reports nothing; a malformed entry is dropped and the
    /// rest kept.
    public static func entries(in headers: [String: String]) -> [Entry]? {
        guard let value = headers[lowercasedHeaderName] else { return nil }
        guard value.utf8.count <= maxValueBytes else { return [] }
        var seen = Set<String>()
        var result: [Entry] = []
        for raw in value.split(separator: ",") {
            guard let entry = entry(String(raw)), seen.insert(entry.name.lowercased()).inserted else { continue }
            result.append(entry)
            if result.count == maxEntries { break }
        }
        return result
    }

    static func entry(_ raw: String) -> Entry? {
        let fields = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              (1...12).contains(fields[0].count), fields[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = TimeInterval(fields[0]),
              AgentSkillNamesCodec.isAcceptableName(String(fields[1])),
              isAcceptableRepository(fields[2])
        else { return nil }
        return Entry(
            name: String(fields[1]), repository: String(fields[2]), lastActive: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Letters, digits, `.`, `_`, `-` and `/`; the Mac parses it further
    /// (`ProjectRemote(header:)`).
    private static func isAcceptableRepository(_ value: Substring) -> Bool {
        (1...maxRepositoryBytes).contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
                    || byte == UInt8(ascii: "/")
            }
    }
}
