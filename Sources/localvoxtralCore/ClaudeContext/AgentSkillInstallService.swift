import Foundation

extension DictationNoteAgent {
    /// The directory, relative to home, the agent loads user-level skills
    /// from. Each agent gets its own, never the shared `~/.agents/skills`:
    /// Codex lists a skill found in both its directories twice. Probed on the
    /// installed versions (2026-10-01):
    ///
    /// - Claude Code 2.1: `~/.claude/skills`.
    /// - opencode 1.18: its own `skills` and `skill`, `~/.claude/skills` and
    ///   `~/.agents/skills`. Its own directory wins a name clash, so a copy
    ///   there and Claude Code's copy load as one skill.
    /// - Mistral Vibe 2.25: `$VIBE_HOME/skills` and `~/.agents/skills`.
    ///   A GUI app cannot see `VIBE_HOME`, so this is `~/.vibe`.
    /// - Codex 0.159: `$CODEX_HOME/skills` and `~/.agents/skills`.
    public var skillsDirectory: String {
        switch self {
        case .claudeCode: return ".claude/skills"
        case .opencode: return ".config/opencode/skills"
        case .vibe: return ".vibe/skills"
        case .codex: return ".codex/skills"
        }
    }
}

/// Adds and removes the localvoxtral doctor skill: a `SKILL.md` naming the
/// commands that diagnose dictation, in a coding agent's user-level skills
/// directory. The agent keeps only the skill's description in context until
/// a task matches it.
///
/// The skill's directory is the app's; a file the user adds next to
/// `SKILL.md` keeps it on Remove. It writes only when the user presses the
/// row's button, refuses symlinks and writes atomically. The text is the
/// remote plugin's copy, so an agent on a remote host learns the same.
public struct AgentSkillInstallService: Sendable {
    /// The skill's name, which is also its directory's: Vibe skips a skill
    /// whose name differs from its directory.
    public static let skillName = "localvoxtral-doctor"

    public typealias Status = DictationNoteInstallService.Status
    public typealias Refusal = DictationNoteInstallService.Refusal

    public let agent: DictationNoteAgent
    private let bundledSkill: @Sendable () -> Data?
    private let fileSystem: (any DictationNoteFileSystem)?

    /// - Parameter bundledSkill: The remote plugin's `SKILL.md`. Nil makes
    ///   the row read "Not available in this build."
    public init(
        agent: DictationNoteAgent,
        bundledSkill: @escaping @Sendable () -> Data?,
        fileSystem: (any DictationNoteFileSystem)? = nil
    ) {
        self.agent = agent
        self.bundledSkill = bundledSkill
        self.fileSystem = fileSystem
    }

    /// The skill's directory, relative to home.
    public var skillDirectory: String { agent.skillsDirectory + "/" + Self.skillName }
    /// The skill's file, relative to home.
    public var skillPath: String { skillDirectory + "/SKILL.md" }

    // MARK: - Read-only status

    public func status() -> Status {
        guard let fileSystem, let skill = bundledSkill() else { return .unknown }
        let file = fileSystem.readFile(relativePath: skillPath)
        guard file.exists else { return .notAdded }
        guard !file.isSymlink else { return .needsManualFix(path: skillPath, .symlink) }
        guard let data = file.data else { return .needsManualFix(path: skillPath, .unreadable) }
        return data == skill ? .added(path: skillPath) : .differs(path: skillPath)
    }

    public static func sentence(for status: Status, agent: DictationNoteAgent) -> String {
        let directory = DictationNoteInstallService.displayPath(agent.skillsDirectory)
        switch status {
        case .notAdded: return "Not added."
        case .added: return "In \(directory)."
        case .differs: return "\(directory) holds another version."
        case .needsManualFix(let path, let refusal):
            return DictationNoteInstallService.sentence(for: refusal, path: path)
        case .unknown: return "Not available in this build."
        }
    }

    // MARK: - Mutations (only on the user's button press)

    /// Write this build's skill, over another version if one is there.
    public func add() throws {
        guard let fileSystem, let skill = bundledSkill() else {
            throw DictationNoteInstallService.ServiceError.notConfigured
        }
        let file = fileSystem.readFile(relativePath: skillPath)
        try refuseUnwritable(file)
        guard file.data != skill else { return }
        try refuseIfChanged(file, fileSystem)
        if !file.exists {
            try fileSystem.createParentDirectory(of: skillPath, permissions: 0o755)
        }
        try fileSystem.atomicWrite(skill, relativePath: skillPath, permissions: file.permissions ?? 0o644)
        Log.claudeContext.info(
            "Doctor skill added for \(agent.rawValue, privacy: .public) in \(skillPath, privacy: .public)"
        )
    }

    /// Delete `SKILL.md`, then its directory if nothing else is in it.
    public func remove() throws {
        guard let fileSystem else { throw DictationNoteInstallService.ServiceError.notConfigured }
        let file = fileSystem.readFile(relativePath: skillPath)
        guard file.exists else { return }
        try refuseUnwritable(file)
        try refuseIfChanged(file, fileSystem)
        try fileSystem.delete(relativePath: skillPath)
        fileSystem.removeDirectoryIfEmpty(relativePath: skillDirectory)
        Log.claudeContext.info(
            "Doctor skill removed for \(agent.rawValue, privacy: .public) from \(skillPath, privacy: .public)"
        )
    }

    private func refuseUnwritable(_ file: DictationNoteFile) throws {
        guard file.exists else { return }
        let refusal: Refusal
        if file.isSymlink {
            refusal = .symlink
        } else if file.data == nil {
            refusal = .unreadable
        } else {
            return
        }
        Log.claudeContext.error(
            "Doctor skill refused \(skillPath, privacy: .public): \(String(describing: refusal), privacy: .public)"
        )
        throw DictationNoteInstallService.ServiceError.refused(path: skillPath, refusal)
    }

    /// Last look before writing: an editor that saved since the read would
    /// otherwise lose its change.
    private func refuseIfChanged(_ file: DictationNoteFile, _ fileSystem: any DictationNoteFileSystem) throws {
        let current = fileSystem.readFile(relativePath: skillPath)
        guard current.exists == file.exists, current.data == file.data else {
            throw DictationNoteInstallService.ServiceError.changedOnDisk(path: skillPath)
        }
    }
}
