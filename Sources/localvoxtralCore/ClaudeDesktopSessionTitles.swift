import ClaudeContextWire
import Foundation
import Synchronization

/// The title Claude Desktop shows for a Code-tab session (#1013), read from
/// the file Desktop keeps for it on this Mac:
/// `claude-code-sessions/<account>/<org>/local_<uuid>.json`, key `title`.
/// Desktop keeps the file on the Mac whichever machine runs the session, so
/// an ssh-host session's title is read here too and nothing crosses the wire.
///
/// Read from Desktop 2.9939.2's files (2026-09-28): `title` is the sidebar's
/// title, `titleSource` says who set it (`auto`: Desktop, from the first
/// prompt; `user`; `tool`: the session itself). UNDOCUMENTED: a Desktop
/// update that moves the file or renames the key leaves the session named
/// by its folder, never by another session's title.
///
/// A title is a name for the user to read and say, never join evidence, and
/// it is never persisted or logged.
package final class ClaudeDesktopSessionTitles: @unchecked Sendable {
    /// Longer titles are cut here; the views truncate further.
    package static let maxLength = 80

    private struct Cached {
        var modified: Date?
        var size: Int?
        var title: String?
    }

    private let directory: URL
    private let fileManager: FileManager
    private let cache = Mutex<[String: Cached]>([:])

    /// - Parameter directory: Desktop's `claude-code-sessions` directory.
    package init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/Claude/claude-code-sessions`.
    package static func live() -> ClaudeDesktopSessionTitles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ClaudeDesktopSessionTitles(
            directory: support.appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
        )
    }

    /// The session's title, or nil when the id is not Desktop's shape, no
    /// file holds it, or the file has no usable title. Re-reads a file only
    /// when its size or modification date moved.
    package func title(of session: ClaudeSessionSnapshot) -> String? {
        guard let id = session.desktopSessionID else { return nil }
        return title(desktopSessionID: id)
    }

    package func title(desktopSessionID id: String) -> String? {
        // The id becomes a file name: Desktop's shape only, so no separator
        // or dot can reach the path.
        guard ClaudeDesktopSessionURL.isSessionID(id), let file = file(named: id + ".json") else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        if let cached = cache.withLock({ $0[id] }), cached.modified == modified, cached.size == size {
            return cached.title
        }
        let title = (try? Data(contentsOf: file)).flatMap(Self.title(inSessionFile:))
        cache.withLock { $0[id] = Cached(modified: modified, size: size, title: title) }
        return title
    }

    /// `title` from a session file's JSON, made one clean line.
    package static func title(inSessionFile data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["title"] as? String
        else { return nil }
        return SessionTitleText.clean(raw, maxLength: maxLength)
    }

    private func file(named name: String) -> URL? {
        let accounts = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for account in accounts {
            let orgs = (try? fileManager.contentsOfDirectory(
                at: account, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            for org in orgs {
                let candidate = org.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

/// A harness's title as a name: one line, no controls or bidi overrides,
/// bounded.
package enum SessionTitleText {
    package static func clean(_ raw: String, maxLength: Int) -> String? {
        let line = ClaudeTextSanitizer.sanitize(raw, maxBytes: maxLength * 4)
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !SessionNameMatching.key(line).isEmpty else { return nil }
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
