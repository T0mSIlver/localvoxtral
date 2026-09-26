import Foundation

/// The coding agents whose user-level instructions file can carry the
/// dictation note.
public enum DictationNoteAgent: String, Sendable, CaseIterable, Hashable {
    case claudeCode
    case opencode
    case vibe

    /// The name the row's title uses.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .opencode: return "opencode"
        case .vibe: return "Mistral Vibe"
        }
    }

    /// The files the agent loads as user-level instructions, most preferred
    /// first; it loads only the first one that exists. Paths are relative to
    /// home. Probed on the installed versions (2026-09-26):
    ///
    /// - Claude Code 2.1: `~/.claude/CLAUDE.md`.
    /// - opencode 1.18: `~/.config/opencode/AGENTS.md`, and when that file is
    ///   absent, `~/.claude/CLAUDE.md` (its `Instruction.systemPaths` takes
    ///   the first that exists). Creating opencode's own file would therefore
    ///   silently hide the user's CLAUDE.md from opencode, so the note goes
    ///   into whichever file opencode reads today.
    /// - Mistral Vibe 2.25: `$VIBE_HOME/AGENTS.md`. A GUI app cannot see
    ///   `VIBE_HOME`, so this is `~/.vibe`, as for the hooks.
    public var instructionsFiles: [String] {
        switch self {
        case .claudeCode: return [".claude/CLAUDE.md"]
        case .opencode: return [".config/opencode/AGENTS.md", ".claude/CLAUDE.md"]
        case .vibe: return [".vibe/AGENTS.md"]
        }
    }
}

/// Adds and removes the dictation note: a short marked block in a coding
/// agent's user-level instructions file saying the user dictates, so the agent
/// fixes an obvious transcription error and asks about one that changes the
/// request.
///
/// The file is the user's. The block goes through `MarkedTextBlock`: appended
/// when absent, replaced in place when present, and a file whose markers do
/// not pair is refused. Nothing outside the markers changes. It writes only
/// when the user presses the row's button, refuses symlinks, keeps the file's
/// mode and writes atomically. The note stays a few lines: Codex truncates
/// AGENTS.md at 32 KiB without a warning.
public struct DictationNoteInstallService: Sendable {
    public static let block = MarkedTextBlock(
        markerBegin: "<!-- begin localvoxtral dictation note -->",
        markerEnd: "<!-- end localvoxtral dictation note -->"
    )

    /// This build's block, markers included, without a trailing newline.
    public static let snippet = """
        \(block.markerBegin)
        ## Dictation

        I dictate most prompts with a speech-to-text app, so they can hold \
        transcription errors: misheard names, homophones, a word split or merged. \
        Correct an obvious one yourself. When a likely error changes what I am \
        asking, ask me before acting.
        \(block.markerEnd)
        """

    public let agent: DictationNoteAgent
    private let fileSystem: (any DictationNoteFileSystem)?

    public init(agent: DictationNoteAgent, fileSystem: (any DictationNoteFileSystem)? = nil) {
        self.agent = agent
        self.fileSystem = fileSystem
    }

    // MARK: - Read-only status

    public enum Status: Sendable, Equatable {
        /// No block in the file the agent reads. Offers Add.
        case notAdded
        /// The block is there and matches this build's. Offers Remove only.
        case added(path: String)
        /// The block is there but differs: an older build's, edited by hand,
        /// or pasted twice. Offers Update and Remove.
        case differs(path: String)
        /// The file is in a shape this app will not write into.
        case needsManualFix(path: String, Refusal)
        /// No file system in this build.
        case unknown
    }

    public enum Refusal: Sendable, Equatable {
        case symlink
        case unreadable
        case notUTF8
        case unpairedMarkers
    }

    public static func addButtonTitle(for status: Status) -> String? {
        switch status {
        case .notAdded: return "Add"
        case .differs: return "Update"
        case .added, .needsManualFix, .unknown: return nil
        }
    }

    public static func offersRemove(for status: Status) -> Bool {
        switch status {
        case .added, .differs: return true
        case .notAdded, .needsManualFix, .unknown: return false
        }
    }

    public static func sentence(for status: Status) -> String {
        switch status {
        case .notAdded: return "Not added."
        case .added(let path): return "In \(displayPath(path))."
        case .differs(let path): return "\(displayPath(path)) holds another version."
        case .needsManualFix(let path, let refusal): return sentence(for: refusal, path: path)
        case .unknown: return "Not available in this build."
        }
    }

    package static func sentence(for refusal: Refusal, path: String) -> String {
        let shown = displayPath(path)
        switch refusal {
        case .symlink: return "\(shown) is a symlink; edit it by hand."
        case .unreadable: return "Could not read \(shown)."
        case .notUTF8: return "\(shown) is not UTF-8 text."
        case .unpairedMarkers: return "\(shown) has a broken localvoxtral block."
        }
    }

    package static func displayPath(_ relativePath: String) -> String { "~/" + relativePath }

    /// The file the agent reads today: the first of its candidates that
    /// exists, or the first candidate when none does.
    public func targetPath() -> String? {
        guard let fileSystem else { return nil }
        let candidates = agent.instructionsFiles
        return candidates.first { fileSystem.readFile(relativePath: $0).exists } ?? candidates.first
    }

    public func status() -> Status {
        guard let fileSystem, let path = targetPath() else { return .unknown }
        let file = fileSystem.readFile(relativePath: path)
        let text: String
        do {
            text = try Self.text(of: file)
        } catch let refusal as Refusal {
            return .needsManualFix(path: path, refusal)
        } catch {
            return .unknown
        }
        switch Self.block.locateBlock(in: Self.block.splitLines(text)) {
        case .absent: return .notAdded
        case .damaged: return .needsManualFix(path: path, .unpairedMarkers)
        case .present:
            return Self.block.containsCurrentBlock(text, snippet: Self.snippet)
                ? .added(path: path) : .differs(path: path)
        }
    }

    // MARK: - Mutations (only on the user's button press)

    public enum ServiceError: Error, Equatable, CustomStringConvertible {
        case notConfigured
        case refused(path: String, Refusal)
        /// The file changed between reading and writing.
        case changedOnDisk(path: String)

        public var description: String {
            switch self {
            case .notConfigured:
                return "Editing agent instructions is not available in this build."
            case .refused(let path, let refusal):
                return DictationNoteInstallService.sentence(for: refusal, path: path)
            case .changedOnDisk(let path):
                return "\(DictationNoteInstallService.displayPath(path)) changed while this was "
                    + "running. Nothing was written; try again."
            }
        }
    }

    /// Append the block, or replace the one already there.
    public func add() throws {
        guard let fileSystem, let path = targetPath() else { throw ServiceError.notConfigured }
        let file = fileSystem.readFile(relativePath: path)
        let existing = try refusing(path) { try Self.text(of: file) }
        guard let updated = Self.block.apply(to: existing, snippet: Self.snippet) else {
            throw ServiceError.refused(path: path, .unpairedMarkers)
        }
        guard updated != existing else { return }
        try refuseIfChanged(file, path: path, fileSystem)
        if !file.exists {
            try fileSystem.createParentDirectory(of: path, permissions: 0o700)
        }
        try fileSystem.atomicWrite(Data(updated.utf8), relativePath: path, permissions: file.permissions ?? 0o644)
        Log.claudeContext.info(
            "Dictation note added for \(agent.rawValue, privacy: .public) in \(path, privacy: .public)"
        )
    }

    /// Take the block out. A file left with nothing but whitespace is deleted:
    /// an empty `~/.config/opencode/AGENTS.md` would still hide the user's
    /// CLAUDE.md from opencode.
    public func remove() throws {
        guard let fileSystem, let path = targetPath() else { throw ServiceError.notConfigured }
        let file = fileSystem.readFile(relativePath: path)
        guard file.exists else { return }
        let existing = try refusing(path) { try Self.text(of: file) }
        guard let remaining = Self.block.remove(from: existing) else {
            throw ServiceError.refused(path: path, .unpairedMarkers)
        }
        guard remaining != existing else { return }
        try refuseIfChanged(file, path: path, fileSystem)
        if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try fileSystem.delete(relativePath: path)
        } else {
            try fileSystem.atomicWrite(
                Data(remaining.utf8), relativePath: path, permissions: file.permissions ?? 0o644
            )
        }
        Log.claudeContext.info(
            "Dictation note removed for \(agent.rawValue, privacy: .public) from \(path, privacy: .public)"
        )
    }

    /// Last look before writing, as `VibeHooksInstallService` does: an editor
    /// that saved since the read would otherwise lose its change to our rename.
    private func refuseIfChanged(
        _ file: DictationNoteFile, path: String, _ fileSystem: any DictationNoteFileSystem
    ) throws {
        let current = fileSystem.readFile(relativePath: path)
        guard current.exists == file.exists, current.data == file.data else {
            throw ServiceError.changedOnDisk(path: path)
        }
    }

    private func refusing<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let refusal as Refusal {
            Log.claudeContext.error(
                "Dictation note refused \(path, privacy: .public): \(String(describing: refusal), privacy: .public)"
            )
            throw ServiceError.refused(path: path, refusal)
        }
    }

    /// The file's text, "" when absent, or why it will not be edited.
    private static func text(of file: DictationNoteFile) throws -> String {
        guard file.exists else { return "" }
        guard !file.isSymlink else { throw Refusal.symlink }
        guard let data = file.data else { throw Refusal.unreadable }
        guard let text = String(data: data, encoding: .utf8) else { throw Refusal.notUTF8 }
        return text
    }
}

extension DictationNoteInstallService.Refusal: Error {}

/// One instructions file as the service sees it.
public struct DictationNoteFile: Sendable, Equatable {
    public var exists: Bool
    /// The file, or a directory between home and it, is a symlink.
    public var isSymlink: Bool
    /// Nil when absent, a symlink, or unreadable.
    public var data: Data?
    public var permissions: UInt16?

    public init(exists: Bool = false, isSymlink: Bool = false, data: Data? = nil, permissions: UInt16? = nil) {
        self.exists = exists
        self.isSymlink = isSymlink
        self.data = data
        self.permissions = permissions
    }
}

/// File operations relative to home, injected so every rule is testable
/// without a home directory.
public protocol DictationNoteFileSystem: Sendable {
    func readFile(relativePath: String) -> DictationNoteFile
    func createParentDirectory(of relativePath: String, permissions: UInt16) throws
    func atomicWrite(_ data: Data, relativePath: String, permissions: UInt16) throws
    func delete(relativePath: String) throws
}
