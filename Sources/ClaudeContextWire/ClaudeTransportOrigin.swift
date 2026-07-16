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

/// Read-only local repository collection, gated on `LocalWorkspacePath`.
///
/// Implementations may touch the filesystem. They cannot be handed a remote
/// workspace: there is no way to construct the parameter type from one.
public protocol ClaudeLocalRepoCollecting: Sendable {
    func collectRepositoryContext(for workspace: LocalWorkspacePath) -> [String]
}
