import Foundation

/// Where a record came from, decided ONLY by the broker from transport-level
/// evidence (peer credentials on an AF_UNIX socket), never from record content.
///
/// There is deliberately no `init(from decoder:)` and no wire key for this
/// type. A sender cannot describe itself as local: it either connects over a
/// peer-authenticated UNIX socket owned by our UID, or it does not.
public enum ClaudeTransportOrigin: Sendable, Equatable, Hashable {
    /// Delivered over a local AF_UNIX socket whose peer UID was verified to
    /// match this process's effective UID before a single byte was read.
    ///
    /// Records with this origin MAY later authorize local repository reads:
    /// the paths they carry name files this same user can already read.
    case localAuthenticated(peerUID: UInt32)

    /// Delivered over any other channel (a forwarded socket, an SSH tunnel, a
    /// future network relay). The peer is not this user's local process, so
    /// its paths name files in someone else's filesystem.
    ///
    /// Records with this origin carry OPAQUE CONTEXT ONLY. Nothing they say
    /// may reach a local filesystem API.
    case remote(channel: String)

    public var isLocalAuthenticated: Bool {
        if case .localAuthenticated = self { return true }
        return false
    }
}

/// A filesystem path that a local repository collector is permitted to touch.
///
/// This type is the compile-time half of the trust boundary. Its initializer is
/// internal to `ClaudeContextWire`, and the ONLY construction site in the whole
/// module is `ClaudeWorkspaceReference.make(rawCwd:origin:)`, which refuses to
/// build one for a remote origin. Downstream modules — including the app — can
/// therefore never mint a `LocalWorkspacePath` out of a remote record's cwd,
/// no matter what they do with the string.
///
/// Collector APIs take `LocalWorkspacePath`, not `String`. That makes
/// "remote cwd reaches the filesystem" a compiler error rather than a code
/// review item.
public struct LocalWorkspacePath: Sendable, Equatable, Hashable {
    public let path: String

    /// Internal by design — see the type doc. Do not widen this to `public`.
    init(verifiedLocal path: String) {
        self.path = path
    }

    public var fileURL: URL { URL(fileURLWithPath: path) }

    /// An ANCESTOR directory of this path, as a `LocalWorkspacePath`.
    ///
    /// A repo root is found by walking UP from the session's cwd, so the root
    /// is always an ancestor of a path we already verified as local. That makes
    /// this derivation total for the collector's needs while keeping the
    /// invariant intact: the result is provably inside the same locally
    /// authenticated filesystem the cwd came from, so it inherits its trust
    /// rather than laundering a fresh string into the type.
    ///
    /// Returns nil unless `candidate` really is self or a parent of self —
    /// a caller cannot pass an arbitrary path and get a usable one back.
    public func ancestor(atPath candidate: String) -> LocalWorkspacePath? {
        let normalized = LocalWorkspacePath.normalize(candidate)
        let mine = LocalWorkspacePath.normalize(path)
        guard normalized == mine || mine.hasPrefix(normalized + "/") else { return nil }
        return LocalWorkspacePath(verifiedLocal: normalized)
    }

    /// A path INSIDE this one, named by a repo-relative path.
    ///
    /// This is the only way the collector turns a hook-reported or
    /// `git ls-files`-reported relative path into something it may open, and it
    /// is deliberately strict: the result must lexically resolve to a strict
    /// descendant. `..` traversal, absolute paths, and empty components are all
    /// rejected rather than normalized into something surprising, so neither a
    /// crafted `files` entry on the wire nor a hostile filename in a repo can
    /// aim a read outside the workspace.
    ///
    /// Lexical containment is not a defense against symlinks — a tracked
    /// symlink can still point out of the tree. The collector handles that
    /// separately by refusing to follow links; this function's job is the
    /// lexical half.
    public func descendant(relativePath: String) -> LocalWorkspacePath? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        guard !relativePath.contains("\0") else { return nil }
        var components: [String] = []
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            let value = String(component)
            if value == "." { continue }
            // Never resolve `..` by popping: a path that climbs at all is a
            // path we decline to reason about.
            if value == ".." { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        let base = LocalWorkspacePath.normalize(path)
        return LocalWorkspacePath(verifiedLocal: base + "/" + components.joined(separator: "/"))
    }

    /// `relativePath`'s position under this path, or nil when it is not inside.
    /// Used to report paths repo-relative rather than leaking the user's home
    /// directory layout into a prompt.
    public func relativePath(of other: LocalWorkspacePath) -> String? {
        let base = LocalWorkspacePath.normalize(path)
        let candidate = LocalWorkspacePath.normalize(other.path)
        guard candidate.hasPrefix(base + "/") else { return nil }
        return String(candidate.dropFirst(base.count + 1))
    }

    /// Collapses duplicate and trailing separators so prefix comparisons above
    /// mean what they read as (`/a//b/` and `/a/b` are the same directory, and
    /// `/a/bc` must not count as a child of `/a/b`).
    static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }
}

/// A session's workspace, in whichever form its origin permits.
public enum ClaudeWorkspaceReference: Sendable, Equatable, Hashable {
    /// Locally authenticated: a real, usable path.
    case local(LocalWorkspacePath)
    /// Remote: a display-only label. There is no path accessor, on purpose.
    case remoteOpaque(label: String)

    /// The only way a `LocalWorkspacePath` is ever created.
    ///
    /// - For `.localAuthenticated`, an absolute path becomes `.local`. A
    ///   relative or empty cwd is rejected outright (nil): we will not resolve
    ///   it against our own process cwd, which has nothing to do with the
    ///   session's.
    /// - For `.remote`, the path is reduced to a sanitized last component and
    ///   returned as `.remoteOpaque`. The full path never survives.
    public static func make(rawCwd: String?, origin: ClaudeTransportOrigin) -> ClaudeWorkspaceReference? {
        guard let rawCwd, !rawCwd.isEmpty else { return nil }
        switch origin {
        case .localAuthenticated:
            guard rawCwd.hasPrefix("/") else { return nil }
            return .local(LocalWorkspacePath(verifiedLocal: rawCwd))
        case .remote:
            let label = opaqueLabel(for: rawCwd)
            guard !label.isEmpty else { return nil }
            return .remoteOpaque(label: label)
        }
    }

    /// The local path, or nil for remote. Collectors funnel through here.
    public var localPath: LocalWorkspacePath? {
        if case .local(let path) = self { return path }
        return nil
    }

    /// Human-readable name for either origin — safe to show, never to open.
    public var displayName: String {
        switch self {
        case .local(let path):
            return (path.path as NSString).lastPathComponent
        case .remoteOpaque(let label):
            return label
        }
    }

    /// Reduce a foreign path to a bare, separator-free name.
    ///
    /// Strips directories, then anything that could reconstitute a path or
    /// escape a component (`/`, `\`, `.` runs, NUL). What remains is a label,
    /// not a path — even if a caller ignored the type system and tried to open
    /// it, there is nothing meaningful to open.
    static func opaqueLabel(for rawCwd: String, maxLength: Int = 64) -> String {
        let lastComponent = rawCwd.split(separator: "/").last.map(String.init) ?? rawCwd
        let allowed = lastComponent.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "."
        }
        var label = String(String.UnicodeScalarView(allowed))
        // No leading dots: a label must never read as `.`, `..`, or a hidden
        // path component.
        while label.hasPrefix(".") { label.removeFirst() }
        if label.count > maxLength { label = String(label.prefix(maxLength)) }
        return label
    }
}

/// Read-only local filesystem access, gated on `LocalWorkspacePath`.
///
/// Implementations may touch the filesystem. They cannot be handed a remote
/// workspace: there is no way to construct the parameter type from one, and
/// `LocalWorkspacePath`'s only derivations (`ancestor`, `descendant`) preserve
/// that. This is the seam the repo collector's file reads go through, and the
/// reason `ClaudeRepoCollector` is testable against an in-memory tree.
///
/// Every method returns an Optional rather than throwing: an unreadable file is
/// a fact about the tree, not an error worth propagating through a best-effort
/// context path.
public protocol ClaudeLocalFileReading: Sendable {
    /// True when the path exists and is a directory (never following a final
    /// symlink — see `ClaudeRepoCollector` on why links are not traversed).
    func isDirectory(_ path: LocalWorkspacePath) -> Bool
    /// True when the path exists and is a regular file, again without
    /// following a final symlink.
    func isRegularFile(_ path: LocalWorkspacePath) -> Bool
    /// Size in bytes, used to skip an oversized file before reading it.
    func fileSize(_ path: LocalWorkspacePath) -> Int?
    /// At most `maxBytes` of the file's raw bytes. Raw, not `String`: binary
    /// detection has to happen on bytes, and decoding first would silently turn
    /// a PNG into replacement characters.
    func readFile(_ path: LocalWorkspacePath, maxBytes: Int) -> Data?
}
