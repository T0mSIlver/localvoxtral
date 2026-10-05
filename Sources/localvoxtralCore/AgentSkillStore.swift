import Foundation
import ClaudeContextWire
import Synchronization
#if canImport(os)
import os
#endif

/// The skill names polishing is told about (#1024): the skills and commands
/// the user's coding agents can run, on this Mac and on every host whose
/// shim reported them. Skill names are what a user says to an agent and the
/// recognizer has never heard ("unslop", "gh-stack").
///
/// All of them, not the joined session's: the list rides the system prompt,
/// which must not change from one dictation to the next, and the #1024 eval
/// found no cost in sending 43 names where 11 were used (no wrong insertion,
/// the same names right).
package struct AgentSkillNames: Codable, Equatable, Sendable {
    package struct HostReport: Codable, Equatable, Sendable {
        package var names: [String]
        package var reportedAt: Date
    }

    package static let currentVersion = 1
    /// A host no session has reported from in this long drops out.
    package static let staleAfterDays = 30
    package static let maxNames = 80

    package var version = currentVersion
    /// Keyed by the host registry's id.
    package var hosts: [String: HostReport] = [:]

    package init(hosts: [String: HostReport] = [:]) {
        self.hosts = hosts
    }

    /// Every name, sorted so the prompt does not change with the order hosts
    /// reported in; the most recently reporting hosts win the cap.
    package func names(local: [String], now: Date) -> [String] {
        let fresh = hosts.values
            .filter { now.timeIntervalSince($0.reportedAt) < Double(Self.staleAfterDays) * 86_400 }
            .sorted { $0.reportedAt > $1.reportedAt }
        // Which names make the cap follows recency; which spelling of a name
        // does not, or a host re-reporting would flip it in the prompt.
        var spelling: [String: String] = [:]
        var kept: [String] = []
        for name in local + fresh.flatMap(\.names) {
            let key = name.lowercased()
            if let current = spelling[key] {
                spelling[key] = min(current, name)
            } else if kept.count < Self.maxNames {
                spelling[key] = name
                kept.append(key)
            }
        }
        return kept.compactMap { spelling[$0] }.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// `AgentSkillNames` on disk (`agent-skills.json`), and the Mac's own skill
/// folders, read off the main actor.
package final class AgentSkillStore: @unchecked Sendable {
    private struct State {
        var stored = AgentSkillNames()
        var local: [String] = []
        var localReadAt: Date?
        /// The file exists but could not be read: never overwrite it.
        var readOnly = false
    }

    package let fileURL: URL?
    private let home: URL
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "localvoxtral.agent-skills", qos: .utility)
    private let now: @Sendable () -> Date

    /// A report whose names did not change rewrites the file at most this
    /// often: every SessionStart sends the list.
    package static let restampInterval: TimeInterval = 86_400

    package init(
        fileURL: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.home = home
        self.now = now
        queue.async { [self] in
            let loaded = load()
            let local = AgentSkillDirectories.names(home: home)
            state.withLock { state in
                // A report that arrived before the file was read is newer.
                state.stored.hosts.merge(loaded.names.hosts) { reported, _ in reported }
                state.readOnly = loaded.readOnly
                state.local = local
                state.localReadAt = now()
            }
            Log.polishing.info(
                "Agent skills: \(local.count, privacy: .public) on this Mac, \(loaded.names.hosts.count, privacy: .public) hosts"
            )
        }
    }

    package static func defaultFileURL(in directory: URL = LocalvoxtralDataDirectory.url()) -> URL {
        directory.appendingPathComponent("agent-skills.json")
    }

    package func names() -> [String] {
        let moment = now()
        return state.withLock { $0.stored.names(local: $0.local, now: moment) }
    }

    /// Returns once the file and the Mac's folders were read and every
    /// write so far is on disk. For tests.
    package func waitForPendingWork() {
        queue.sync {}
    }

    /// The Mac's folders are read again at most this often.
    package static let localRefreshInterval: TimeInterval = 600

    /// Reads the Mac's skill folders again, off the caller's thread, when
    /// the last read is older than `localRefreshInterval`: a skill installed
    /// while the app runs reaches the prompts after that. Each polish calls
    /// this, and the new list serves the ones after it.
    package func refreshLocalIfStale() {
        let moment = now()
        let due = state.withLock { state -> Bool in
            guard let read = state.localReadAt, moment.timeIntervalSince(read) >= Self.localRefreshInterval
            else { return false }
            state.localReadAt = moment
            return true
        }
        guard due else { return }
        queue.async { [self] in
            let local = AgentSkillDirectories.names(home: home)
            state.withLock { $0.local = local }
        }
    }

    /// A host's shim reported `names` (already accepted by
    /// `AgentSkillNamesCodec`).
    package func record(hostID: String, names: [String]) {
        let moment = now()
        let names = AgentSkillNamesCodec.accepted(names)
        let changed = state.withLock { state -> Bool in
            if let last = state.stored.hosts[hostID], last.names == names,
               moment.timeIntervalSince(last.reportedAt) < Self.restampInterval
            {
                return false
            }
            state.stored.hosts[hostID] = .init(names: names, reportedAt: moment)
            return true
        }
        guard changed, let fileURL else { return }
        // Read on the queue, after the file's load: writing earlier would
        // replace the other hosts on disk with this one.
        queue.async { [self] in
            guard let snapshot = state.withLock({ $0.readOnly ? nil : $0.stored }) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            } catch {
                Log.polishing.error("Agent skills: write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.polishing.info("Agent skills: a host reported \(names.count, privacy: .public)")
    }

    private func load() -> (names: AgentSkillNames, readOnly: Bool) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return (AgentSkillNames(), false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(AgentSkillNames.self, from: data),
              decoded.version <= AgentSkillNames.currentVersion
        else {
            Log.polishing.error("Agent skills: \(fileURL.lastPathComponent, privacy: .public) is unreadable; left as it is")
            return (AgentSkillNames(), true)
        }
        return (decoded, false)
    }
}

/// Where coding agents keep their skills and commands under a home folder:
/// a skill is a folder holding `SKILL.md`, a command a Markdown file. The
/// remote shims list the same places (`lvx_skills` in both `post.sh`).
package enum AgentSkillDirectories {
    /// Folders whose subfolders are skills.
    package static let skillFolders = [
        ".claude/skills", ".codex/skills", ".config/opencode/skills", ".config/opencode/skill",
        ".vibe/skills", ".agents/skills",
    ]
    /// Folders whose Markdown files are commands.
    package static let commandFolders = [
        ".claude/commands", ".codex/prompts", ".config/opencode/commands", ".config/opencode/command",
    ]
    /// Claude Code's installed plugins: `<marketplace>/<plugin>/<version>/skills/<name>`.
    package static let pluginCache = ".claude/plugins/cache"

    package static func names(home: URL, fileManager: FileManager = .default) -> [String] {
        func children(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func skills(in folder: URL) -> [String] {
            children(folder).filter { fileManager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
                .map(\.lastPathComponent)
        }
        var names: [String] = []
        for folder in skillFolders {
            names += skills(in: home.appendingPathComponent(folder))
        }
        for marketplace in children(home.appendingPathComponent(pluginCache)) {
            for plugin in children(marketplace) {
                for version in children(plugin) {
                    names += skills(in: version.appendingPathComponent("skills"))
                }
            }
        }
        for folder in commandFolders {
            names += children(home.appendingPathComponent(folder))
                .filter { $0.pathExtension == "md" && $0.lastPathComponent.lowercased() != "readme.md" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        return AgentSkillNamesCodec.accepted(names)
    }
}
