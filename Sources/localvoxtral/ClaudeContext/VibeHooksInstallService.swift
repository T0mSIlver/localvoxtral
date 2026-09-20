import Foundation

/// Installs the Mistral Vibe hooks: copies the bundled shim to
/// `~/.vibe/localvoxtral/publish.sh` and adds a marked block of two `[[hooks]]`
/// tables to `~/.vibe/hooks.toml`.
///
/// `hooks.toml` is Vibe's documented hook file and the user's own, so the
/// block goes through `MarkedTextBlock`: replaced in place when present,
/// appended otherwise, refused when the markers do not pair. A `[[hooks]]`
/// header opens a new table wherever it appears, so an appended block is
/// valid after any existing content. The shim is a fixed path this app owns.
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

    public static let block = MarkedTextBlock(
        markerBegin: "# >>> localvoxtral >>>",
        markerEnd: "# <<< localvoxtral <<<"
    )
    /// The hook names the shipped block declares. Vibe deduplicates hooks by
    /// exact `name`, so a hand-written hook with one of these names outside
    /// the block would shadow or be shadowed by ours.
    public static let hookNames: Set<String> = ["localvoxtral-files", "localvoxtral-turn"]

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
        if Self.block.hasDamagedBlock(hooksText) || Self.markerIsInsideMultilineString(hooksText) {
            return .unknown
        }
        if Self.declaresOurHookOutsideBlock(hooksText) || Self.keyFollowsBlock(hooksText) {
            return .conflictingHooks
        }
        let hasBlock = Self.block.containsBlock(hooksText)

        switch (state.shimFileExists, hasBlock) {
        case (false, false): return .notInstalled
        case (false, true): return .hooksWithoutShim
        case (true, false): return .shimWithoutHooks
        case (true, true):
            // A shipped fix must surface: compare both halves with this build.
            if let shim = bundledShimData(), state.shimData != shim { return .updateAvailable }
            if let snippet = bundledSnippet(),
               !Self.block.containsCurrentBlock(hooksText, snippet: snippet) {
                return .updateAvailable
            }
            return .installed
        }
    }

    // MARK: - Mutations (consent-gated by the caller)

    public enum ServiceError: Error, Equatable {
        case notConfigured
        case bundledFilesUnavailable
        case isSymlink
        case unreadable
        /// Unpaired markers, a marker inside a multi-line string, a non-UTF-8
        /// file, a hook of ours declared outside the block, or a key right
        /// after the block.
        case refused
        /// `hooks.toml` or the shim changed between reading and writing.
        case changedOnDisk
    }

    public func install() throws {
        guard let shim = bundledShimData(), let snippet = bundledSnippet() else {
            throw ServiceError.bundledFilesUnavailable
        }
        guard let fileSystem else { throw ServiceError.notConfigured }
        let state = try readStateOrThrow(fileSystem)
        try Self.refuseUnsafe(state)

        let existing = try Self.hooksText(in: state)
        guard let updated = Self.hooksByInstalling(snippet: snippet, into: existing) else {
            throw ServiceError.refused
        }
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
            guard !Self.markerIsInsideMultilineString(existing), !Self.keyFollowsBlock(existing),
                  let remaining = Self.block.remove(from: existing)
            else { throw ServiceError.refused }
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

    // MARK: - Pure text rules

    /// `hooks.toml` text with this build's block in it, or nil to refuse.
    static func hooksByInstalling(snippet: String, into existing: String) -> String? {
        guard !markerIsInsideMultilineString(existing),
              !declaresOurHookOutsideBlock(existing),
              !keyFollowsBlock(existing)
        else { return nil }
        return block.apply(to: existing, snippet: snippet)
    }

    /// These three checks read TOML line by line instead of parsing it: the
    /// app has no TOML parser, and each check only has to be right about the
    /// few shapes that make a marker-based edit unsafe. Each errs toward
    /// refusing.

    /// Does the text, with our block taken out, declare a hook with one of our
    /// exact names? `name` may be written bare or quoted, and the value in
    /// either TOML string style. Unpaired markers count as "yes": there is no
    /// telling what is outside a block that does not close.
    static func declaresOurHookOutsideBlock(_ existing: String) -> Bool {
        guard let outside = block.remove(from: existing) else { return true }
        return block.splitLines(outside).contains { line in
            guard let (key, value) = keyValue(in: line), key == "name" else { return false }
            return hookNames.contains { value.hasPrefix("\"\($0)\"") || value.hasPrefix("'\($0)'") }
        }
    }

    /// Is the first meaningful line after a block a key rather than a table
    /// header? Such a key belongs to OUR last `[[hooks]]` table; removing or
    /// replacing the block would silently hand it to the table before.
    static func keyFollowsBlock(_ existing: String) -> Bool {
        let lines = block.splitLines(existing)
        guard case .present(let ranges) = block.locateBlock(in: lines) else { return false }
        return ranges.contains { range in
            let next = lines[(range.upperBound + 1)...].first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            guard let next else { return false }
            return !next.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
    }

    /// Does a marker line sit inside a TOML multi-line string? Then it is the
    /// user's data, not a delimiter. Counted as an odd number of `"""` or
    /// `'''` delimiters before the line; a file this cannot classify is
    /// refused, which is the safe direction.
    static func markerIsInsideMultilineString(_ existing: String) -> Bool {
        var openBasic = false
        var openLiteral = false
        for line in block.splitLines(existing) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == block.markerBegin || trimmed == block.markerEnd {
                if openBasic || openLiteral { return true }
                continue
            }
            if !openLiteral, line.components(separatedBy: "\"\"\"").count % 2 == 0 { openBasic.toggle() }
            if !openBasic, line.components(separatedBy: "'''").count % 2 == 0 { openLiteral.toggle() }
        }
        return false
    }

    /// `key = value` of one line, the key unquoted. Nil for anything else.
    private static func keyValue(in line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
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

    /// The bundled block without its trailing newline: `MarkedTextBlock`
    /// compares and splices whole lines.
    private func bundledSnippet() -> String? {
        guard let text = bundledHooksBlock() else { return nil }
        let snippet = text.trimmingCharacters(in: .newlines)
        let lines = Self.block.splitLines(snippet)
        guard case .present(let ranges) = Self.block.locateBlock(in: lines),
              ranges == [0...(lines.count - 1)]
        else { return nil }
        return snippet
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
        guard let text = String(data: data, encoding: .utf8) else { throw ServiceError.refused }
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
