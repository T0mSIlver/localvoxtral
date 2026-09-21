import Foundation

/// Installs the Mistral Vibe hooks: copies the bundled shim to
/// `~/.vibe/localvoxtral/publish.sh` and adds a marked block of two `[[hooks]]`
/// tables to `~/.vibe/hooks.toml`.
///
/// `hooks.toml` is Vibe's documented hook file and the user's own, so the
/// block goes through `MarkedTextBlock`: replaced in place when present,
/// appended otherwise, refused when the markers do not pair. A `[[hooks]]`
/// header opens a new table wherever it appears, so an appended block is
/// valid after any content EXCEPT a `hooks` defined as a plain array or
/// table, which is refused. The shim is a fixed path this app owns.
///
/// File discipline is `OpencodePluginInstallService`'s: write only on explicit
/// consent, refuse symlinks at every path component, refuse unreadable files,
/// keep an existing file's mode, write atomically, stay idempotent.
///
/// `VIBE_HOME` moves Vibe's directory, and a GUI app cannot see the variable
/// the user's shell exports. This service always uses `~/.vibe`; the README
/// covers the manual install for anyone who moved it.
public struct VibeHooksInstallService: Sendable {
    public static let consentSentence =
        "localvoxtral will edit ~/.vibe/localvoxtral/publish.sh and "
        + "~/.vibe/hooks.toml on this Mac."

    /// The text rules, shared with the remote-host block.
    static let editor = VibeHooksBlockEditor.local
    public static var block: MarkedTextBlock { editor.block }
    public static var hookNames: Set<String> { editor.hookNames }

    private let bundledShimData: @Sendable () -> Data?
    private let bundledHooksBlock: @Sendable () -> String?
    private let fileSystem: (any VibeHooksFileSystem)?

    public init(
        bundledShimData: @escaping @Sendable () -> Data? = { nil },
        bundledHooksBlock: @escaping @Sendable () -> String? = { nil },
        fileSystem: (any VibeHooksFileSystem)? = nil
    ) {
        self.bundledShimData = bundledShimData
        self.bundledHooksBlock = bundledHooksBlock
        self.fileSystem = fileSystem
    }

    // MARK: - Read-only status

    public enum Status: Sendable, Equatable {
        /// No shim and no block. Offers Set up.
        case notInstalled
        /// The block is in `hooks.toml` but the shim is gone: every hook run
        /// fails to start, and Vibe warns on each turn.
        case hooksWithoutShim
        /// The shim is there but `hooks.toml` does not run it.
        case shimWithoutHooks
        /// Both present and matching this build. Offers Remove only.
        case installed
        /// Both present, but the shim or the block differs from this build's.
        case updateAvailable
        /// `hooks.toml` declares one of our hook names outside the block, or
        /// puts a key right after it. Vibe would run one of the two hooks and
        /// not say which, and removing the block would hand that key to
        /// another hook. The user has to resolve it; nothing is written.
        case conflictingHooks
        /// A file cannot be read, is not UTF-8, or carries unpaired markers.
        case unknown
    }

    public static func setupButtonTitle(for status: Status) -> String? {
        switch status {
        case .notInstalled, .hooksWithoutShim, .shimWithoutHooks, .unknown: return "Set up…"
        case .updateAvailable: return "Update…"
        case .installed, .conflictingHooks: return nil
        }
    }

    /// Not while `hooks.toml` conflicts: Remove would refuse for the same
    /// reason Set up does.
    public static func offersRemove(for status: Status) -> Bool {
        status != .notInstalled && status != .conflictingHooks
    }

    public static func sentence(for status: Status) -> String {
        switch status {
        case .notInstalled: return "Not installed."
        case .hooksWithoutShim: return "Listed in hooks.toml, hook script missing."
        case .shimWithoutHooks: return "Installed, not listed in hooks.toml."
        case .installed: return "Installed."
        case .updateAvailable: return "Update available."
        case .conflictingHooks: return "hooks.toml needs a manual fix."
        case .unknown: return "Could not read your Vibe config."
        }
    }

    public func status() -> Status {
        guard let fileSystem, let state = try? fileSystem.readState() else { return .unknown }
        if state.shimFileExists, state.shimData == nil { return .unknown }
        if state.hooksFileExists, state.hooksData == nil { return .unknown }

        let hooksText: String
        if let data = state.hooksData {
            guard let text = String(data: data, encoding: .utf8) else { return .unknown }
            hooksText = text
        } else {
            hooksText = ""
        }
        let reading = Self.editor.reading(of: hooksText, snippet: bundledSnippet())
        switch (state.shimFileExists, reading) {
        case (_, .unreadable): return .unknown
        case (_, .conflicting): return .conflictingHooks
        case (false, .absent): return .notInstalled
        case (false, _): return .hooksWithoutShim
        case (true, .absent): return .shimWithoutHooks
        case (true, .outdated): return .updateAvailable
        case (true, .current):
            // A shipped fix must surface: compare the shim with this build too.
            if let shim = bundledShimData(), state.shimData != shim { return .updateAvailable }
            return .installed
        }
    }

    // MARK: - Mutations (consent-gated by the caller)

    public enum ServiceError: Error, Equatable, CustomStringConvertible {
        case notConfigured
        case bundledFilesUnavailable
        case isSymlink
        case unreadable
        /// `hooks.toml` is in a shape this app will not write into.
        case refused(Refusal)
        /// `hooks.toml` or the shim changed between reading and writing.
        case changedOnDisk

        /// The sentence the alert shows: the model keeps `String(describing:)`.
        public var description: String {
            switch self {
            case .notConfigured: return "Editing Vibe's files is not available in this build."
            case .bundledFilesUnavailable: return "This build's Vibe hook files are missing."
            case .isSymlink:
                return "~/.vibe, or a file this app writes under it, is a symlink. See the README for "
                    + "the manual install."
            case .unreadable: return "A file under ~/.vibe could not be read."
            case .refused(let refusal): return Self.sentence(for: refusal)
            case .changedOnDisk:
                return "~/.vibe/hooks.toml changed while this was running. Nothing was written; try again."
            }
        }

        static func sentence(for refusal: Refusal) -> String {
            switch refusal {
            case .notUTF8:
                return "~/.vibe/hooks.toml is not UTF-8 text."
            case .unpairedMarkers:
                return "~/.vibe/hooks.toml has a localvoxtral marker line without its pair. Delete the "
                    + "leftover marker, or the whole block, and try again."
            case .unclosedString:
                return "~/.vibe/hooks.toml has a multi-line string that is not closed, or that contains "
                    + "a localvoxtral marker line."
            case .conflictingHookName:
                return "~/.vibe/hooks.toml already has a hook named localvoxtral-files or "
                    + "localvoxtral-turn outside the localvoxtral block. Vibe keeps one hook per name."
            case .keyAfterBlock:
                return "~/.vibe/hooks.toml has a key right after the localvoxtral block. It belongs to "
                    + "the block's last hook; move it above the block or under its own [[hooks]] table."
            case .hooksIsNotAnArrayOfTables:
                return "~/.vibe/hooks.toml defines hooks as `hooks = [...]` or `[hooks]`. TOML cannot add "
                    + "[[hooks]] tables to that. Rewrite those hooks as [[hooks]] tables first."
            }
        }
    }

    /// Why `hooks.toml` was left alone: the shared editor's reasons.
    public typealias Refusal = VibeHooksBlockEditor.Refusal

    public func install() throws {
        guard let shim = bundledShimData(), let snippet = bundledSnippet() else {
            throw ServiceError.bundledFilesUnavailable
        }
        guard let fileSystem else { throw ServiceError.notConfigured }
        let state = try readStateOrThrow(fileSystem)
        try Self.refuseUnsafe(state)

        let existing = try Self.hooksText(in: state)
        let updated = try Self.refusing { try Self.editor.hooksByInstalling(snippet: snippet, into: existing) }
        try Self.refuseIfChanged(since: state, fileSystem)
        if !state.shimDirExists {
            try fileSystem.createShimDirectory(permissions: 0o700)
        }
        // 0700: Vibe runs it through `sh <path>`, which needs read only, but an
        // executable script is what a user inspecting the directory expects.
        try fileSystem.atomicWriteShim(shim, permissions: state.shimPermissions ?? 0o700)
        try fileSystem.atomicWriteHooks(Data(updated.utf8), permissions: state.hooksPermissions ?? 0o600)
        Log.claudeContext.info("Vibe hooks install completed")
    }

    /// Remove the block and the shim. A `hooks.toml` left with nothing but
    /// whitespace is deleted; one with other hooks keeps every byte of them.
    public func remove() throws {
        guard let fileSystem else { throw ServiceError.notConfigured }
        let state = try readStateOrThrow(fileSystem)
        try Self.refuseUnsafe(state)

        if state.hooksFileExists {
            let existing = try Self.hooksText(in: state)
            let remaining = try Self.refusing { try Self.editor.hooksByRemoving(from: existing) }
            try Self.refuseIfChanged(since: state, fileSystem)
            if remaining != existing {
                if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try fileSystem.deleteHooks()
                } else {
                    try fileSystem.atomicWriteHooks(
                        Data(remaining.utf8), permissions: state.hooksPermissions ?? 0o600
                    )
                }
            }
        }
        // Block first, shim second: the reverse order would leave hooks.toml
        // naming a script that is gone if the second step failed.
        if state.shimFileExists {
            try fileSystem.deleteShim()
        }
        Log.claudeContext.info("Vibe hooks remove completed")
    }

    /// Last look before writing. The edit was computed from `state`; if
    /// `hooks.toml` or the shim changed since (an editor saved, Vibe wrote),
    /// renaming our version over it would drop that change. This narrows the
    /// read-modify-write window to the two calls below it and does not close
    /// it: there is no lock an editor would honor.
    private static func refuseIfChanged(
        since state: VibeHooksState, _ fileSystem: any VibeHooksFileSystem
    ) throws {
        let current = try fileSystem.readState()
        guard current.hooksData == state.hooksData, current.hooksFileExists == state.hooksFileExists,
              current.shimData == state.shimData
        else { throw ServiceError.changedOnDisk }
    }

    /// The editor throws its bare reason; callers of this service get it as a
    /// `ServiceError`, which is what carries the sentence.
    private static func refusing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let refusal as Refusal {
            throw ServiceError.refused(refusal)
        }
    }

    private func bundledSnippet() -> String? {
        bundledHooksBlock().flatMap(Self.editor.snippet(fromBundled:))
    }

    private static func refuseUnsafe(_ state: VibeHooksState) throws {
        guard !state.shimFileIsSymlink, !state.shimDirIsSymlink,
              !state.hooksFileIsSymlink, !state.vibeDirIsSymlink
        else { throw ServiceError.isSymlink }
        if state.shimFileExists, state.shimData == nil { throw ServiceError.unreadable }
        if state.hooksFileExists, state.hooksData == nil { throw ServiceError.unreadable }
    }

    private static func hooksText(in state: VibeHooksState) throws -> String {
        guard let data = state.hooksData else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { throw ServiceError.refused(.notUTF8) }
        return text
    }

    private func readStateOrThrow(_ fileSystem: any VibeHooksFileSystem) throws -> VibeHooksState {
        do {
            return try fileSystem.readState()
        } catch {
            Log.claudeContext.error(
                "Vibe hooks edit failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }
}

/// What the service can see under `~/.vibe` before deciding.
public struct VibeHooksState: Sendable, Equatable {
    public var shimFileExists: Bool
    public var shimFileIsSymlink: Bool
    public var shimData: Data?
    public var shimPermissions: UInt16?
    public var shimDirExists: Bool
    public var shimDirIsSymlink: Bool
    public var hooksFileExists: Bool
    public var hooksFileIsSymlink: Bool
    public var hooksData: Data?
    public var hooksPermissions: UInt16?
    /// `~/.vibe` or any component above `hooks.toml` is a symlink.
    public var vibeDirIsSymlink: Bool

    public init(
        shimFileExists: Bool = false,
        shimFileIsSymlink: Bool = false,
        shimData: Data? = nil,
        shimPermissions: UInt16? = nil,
        shimDirExists: Bool = true,
        shimDirIsSymlink: Bool = false,
        hooksFileExists: Bool = false,
        hooksFileIsSymlink: Bool = false,
        hooksData: Data? = nil,
        hooksPermissions: UInt16? = nil,
        vibeDirIsSymlink: Bool = false
    ) {
        self.shimFileExists = shimFileExists
        self.shimFileIsSymlink = shimFileIsSymlink
        self.shimData = shimData
        self.shimPermissions = shimPermissions
        self.shimDirExists = shimDirExists
        self.shimDirIsSymlink = shimDirIsSymlink
        self.hooksFileExists = hooksFileExists
        self.hooksFileIsSymlink = hooksFileIsSymlink
        self.hooksData = hooksData
        self.hooksPermissions = hooksPermissions
        self.vibeDirIsSymlink = vibeDirIsSymlink
    }
}

/// File operations the service needs, injected so every rule is testable
/// without a home directory.
public protocol VibeHooksFileSystem: Sendable {
    func readState() throws -> VibeHooksState
    /// Creates `~/.vibe/localvoxtral`, and `~/.vibe` above it when absent.
    func createShimDirectory(permissions: UInt16) throws
    func atomicWriteShim(_ data: Data, permissions: UInt16) throws
    func atomicWriteHooks(_ data: Data, permissions: UInt16) throws
    func deleteShim() throws
    func deleteHooks() throws
}
