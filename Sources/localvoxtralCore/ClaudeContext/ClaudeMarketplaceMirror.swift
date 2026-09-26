import Foundation

/// A copy of the bundled Claude Code marketplace at a fixed path, refreshed
/// from the running app on every launch.
///
/// Claude Code stores the marketplace as the DIRECTORY PATH it was registered
/// with and re-reads it at every session start. Registering the app bundle's
/// own copy therefore pins the user's Claude Code to wherever that app happened
/// to live: a `try-pr.sh` build under `/private/tmp/localvoxtral-try.XXXX`, a
/// disk image, a folder they later renamed. When that path goes away the
/// plugin stops loading entirely — `Marketplace localvoxtral failed to load:
/// cache-miss`, no hooks, no session in the registry, and the only visible
/// trace is a half-filled status line (field failure, 2026-09-21).
///
/// The publisher binary already had this problem and solved it with a link the
/// app repoints on launch (`ClaudePublisherPointer`). A link is not enough
/// here: it would still resolve to the vanished bundle until an app launches
/// again, and the plugin loads at SESSION start, not at app start. So this is a
/// copy — self-contained, always readable, and owned by us rather than by
/// whichever bundle was running the day the plugin was installed.
public enum ClaudeMarketplaceMirror {
    /// Beside the publisher link, in the app's own Application Support folder:
    /// refreshing it writes nothing in Claude Code's configuration.
    public static let homeRelativePath = "Library/Application Support/localvoxtral/claude/marketplace"

    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(homeRelativePath)
    }

    package static let stagingPrefix = ".marketplace-"

    public enum Outcome: Sendable, Equatable {
        /// The mirror already held exactly these bytes.
        case unchanged
        case created
        case updated
    }

    /// Copy `source` over the mirror unless it is already identical.
    ///
    /// The copy is staged beside the mirror and swapped in, so a session
    /// starting at that moment reads the old tree or the new one, never a
    /// half-copied one.
    @discardableResult
    public static func refresh(
        source: URL,
        mirrorURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let sourceDigest = try digest(of: source, fileManager: fileManager)
        // A FILE at the mirror path (or a link to one) would make every later
        // step fail the same way on every launch, leaving `usableURL()` nil
        // forever and the registration back on a bundle path. This tree is the
        // app's own, so the shape is ours to correct.
        var isDirectory: ObjCBool = false
        var existed = fileManager.fileExists(atPath: mirrorURL.path, isDirectory: &isDirectory)
        if existed, !isDirectory.boolValue {
            try fileManager.removeItem(at: mirrorURL)
            existed = false
        }
        if existed, let current = try? digest(of: mirrorURL, fileManager: fileManager),
           current == sourceDigest {
            return .unchanged
        }

        let directory = mirrorURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Staging trees a crash left between copy and swap. A second app
        // launching at the same instant can lose its in-flight one; its swap
        // then fails and logs, and its next launch repairs the mirror.
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(stagingPrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        do {
            if existed {
                _ = try fileManager.replaceItemAt(mirrorURL, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: mirrorURL)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return existed ? .updated : .created
    }

    /// The mirror, but only when it holds a marketplace Claude Code can read.
    /// A half-written or hand-deleted mirror is no marketplace, and the caller
    /// falls back to the bundle rather than registering a path that will fail
    /// at session start.
    public static func usableURL(
        mirrorURL: URL = defaultURL()
    ) -> URL? {
        ClaudePluginAssets.isMarketplace(mirrorURL) ? mirrorURL : nil
    }

    /// Content identity of a directory tree: every relative path and every
    /// file's bytes, in sorted order. Names matter as much as contents — a
    /// renamed hook script changes what Claude Code runs while leaving every
    /// byte of every file the same.
    ///
    /// Every element is FRAMED — kind, then name length, then name, then byte
    /// count — because concatenating unframed fields makes different trees
    /// collide: a file `a` holding `bc` would hash exactly like a file `ab`
    /// holding `c`, and an empty file like a directory of the same name. This
    /// digest is the only thing deciding whether a stale mirror gets refreshed
    /// (review, 2026-09-21).
    package static func digest(of directory: URL, fileManager: FileManager = .default) throws -> String {
        var hasher = SHA256Hasher()
        let base = directory.standardizedFileURL.path
        let contents = try fileManager.subpathsOfDirectory(atPath: base).sorted()
        for relative in contents {
            let absolute = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: absolute.path, isDirectory: &isDirectory)
            let name = Data(relative.utf8)
            // A name `subpathsOfDirectory` listed but that does not resolve is
            // a dangling symlink: it still names something Claude Code can
            // read a directory entry for, so it belongs in the identity.
            let kind: String = !exists ? "l" : (isDirectory.boolValue ? "d" : "f")
            hasher.update(data: Data("\(kind):\(name.count):".utf8))
            hasher.update(data: name)
            guard exists, !isDirectory.boolValue else { continue }
            let bytes = try Data(contentsOf: absolute)
            hasher.update(data: Data(":\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
