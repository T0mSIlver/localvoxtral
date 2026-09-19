import Foundation

/// A symlink at a fixed path that the app points at its own hook publisher on
/// every launch.
///
/// The local plugin's shim tries this path before the `publisher_path` pinned
/// at install time. The pin records where the app was when the plugin was
/// installed. After the app moves, the pin names a missing binary or, worse,
/// an older copy of the app left at the old path. The link always names the
/// app that last launched, so the shim never needs a reinstall to follow the
/// app.
///
/// The link lives in the app's own Application Support folder: refreshing it
/// writes nothing in Claude Code's configuration.
public enum ClaudePublisherPointer {
    /// Where the link lives. The shim hardcodes the same path relative to
    /// `$HOME` (`hooks/publish.sh`); a test pins the two together.
    public static let homeRelativePath = "Library/Application Support/localvoxtral/claude/publisher"

    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(homeRelativePath)
    }

    static let stagingPrefix = ".publisher-"

    public enum Outcome: Sendable, Equatable {
        /// The link already named this publisher.
        case unchanged
        case updated(previous: String?)
    }

    /// Point the link at `publisher`, replacing whatever it named before.
    ///
    /// The new link is created beside the old one and renamed over it, so a
    /// hook running at the same moment sees the old target or the new one,
    /// never a missing link.
    @discardableResult
    public static func refresh(
        publisher: URL,
        linkURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let previous = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
        if previous == publisher.path { return .unchanged }

        let directory = linkURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Staging links a crash left between create and rename. A second app
        // launching at the same instant could lose its in-flight one; its
        // rename then fails and logs, and its next launch repairs the link.
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(stagingPrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        let staging = directory.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)")
        try fileManager.createSymbolicLink(
            atPath: staging.path,
            withDestinationPath: publisher.path
        )
        guard rename(staging.path, linkURL.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)]
            )
        }
        return .updated(previous: previous)
    }
}
