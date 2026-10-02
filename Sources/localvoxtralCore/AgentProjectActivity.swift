import Foundation
import Synchronization

/// The repositories the user's coding agents worked in (#1027), read from
/// Claude Code's transcripts, so a project is listed, and its name reaches
/// every polish (#1024), before a dictation ever joins a session in it.
///
/// Claude Code keeps one folder per working directory under
/// `~/.claude/projects`, each holding a `<session>.jsonl` transcript per
/// session. The folder's name is the directory with every `/` and `.`
/// turned into `-`, which cannot be undone, so the directory is the `cwd`
/// the newest transcript records. Only that field is read: the scan stops
/// at the first `"cwd"` key, and nothing else in a transcript is decoded or
/// kept.
package enum AgentTranscripts {
    package static let projectsFolder = ".claude/projects"
    /// How much of a transcript is searched for its `cwd`. Its first lines
    /// can carry a whole queued prompt before the first entry that records
    /// one.
    package static let maxBytesSearched = 4 * 1024 * 1024
    private static let chunkBytes = 64 * 1024

    package struct WorkingDirectory: Equatable, Sendable {
        package let path: String
        /// The newest transcript's modification time.
        package let lastActive: Date
    }

    /// Each project folder's newest transcript within
    /// `LearnedTerms.agentActivityListedDays`, with the directory it
    /// records. Nil when `projectsRoot` cannot be listed.
    package static func recentWorkingDirectories(
        projectsRoot: URL, now: Date, fileManager: FileManager = .default
    ) -> [WorkingDirectory]? {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        let cutoff = now.addingTimeInterval(-Double(LearnedTerms.agentActivityListedDays) * 86_400)
        var result: [WorkingDirectory] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let transcripts = try? fileManager.contentsOfDirectory(
                      at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
                  )
            else { continue }
            let newest = transcripts
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true, let modified = values.contentModificationDate
                    else { return nil }
                    return (url, modified)
                }
                .max { $0.1 < $1.1 }
            guard let (transcript, modified) = newest, modified >= cutoff,
                  let path = workingDirectory(ofTranscript: transcript)
            else { continue }
            result.append(WorkingDirectory(path: path, lastActive: modified))
        }
        return result.sorted { $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.path < $1.path }
    }

    /// The first `"cwd"` key's value in a transcript, when it is an absolute
    /// path. A JSON string never holds an unescaped quote, so `"cwd"` with
    /// both quotes bare is a key, never text inside a message.
    package static func workingDirectory(ofTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer: [UInt8] = []
        var searchFrom = 0
        while buffer.count < maxBytesSearched {
            guard let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            buffer.append(contentsOf: chunk)
            switch cwdValue(in: buffer, from: searchFrom) {
            case .found(let path): return path.hasPrefix("/") ? path : nil
            case .incomplete(let keyStart): searchFrom = keyStart
            case .absent: searchFrom = max(0, buffer.count - 16)
            }
        }
        return nil
    }

    private enum Search {
        case found(String)
        /// A key whose value runs past the bytes read so far.
        case incomplete(Int)
        case absent
    }

    private static let key = Array(#""cwd""#.utf8)

    private static func cwdValue(in bytes: [UInt8], from start: Int) -> Search {
        var index = start
        while index + key.count <= bytes.count {
            guard bytes[index..<(index + key.count)].elementsEqual(key) else {
                index += 1
                continue
            }
            var cursor = index + key.count
            func skipSpaces() {
                while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
            }
            skipSpaces()
            guard cursor < bytes.count else { return .incomplete(index) }
            guard bytes[cursor] == UInt8(ascii: ":") else {
                index += 1
                continue
            }
            cursor += 1
            skipSpaces()
            guard cursor < bytes.count else { return .incomplete(index) }
            guard bytes[cursor] == UInt8(ascii: "\"") else { return .absent }
            let open = cursor
            cursor += 1
            while cursor < bytes.count {
                if bytes[cursor] == UInt8(ascii: "\\") {
                    cursor += 2
                    continue
                }
                if bytes[cursor] == UInt8(ascii: "\"") {
                    let token = Data(bytes[open...cursor])
                    guard token.count <= 4098,
                          let value = try? JSONDecoder().decode(String.self, from: token)
                    else { return .absent }
                    return .found(value)
                }
                if bytes[cursor] < 0x20 { return .absent }
                cursor += 1
            }
            return cursor - open > 4098 ? .absent : .incomplete(index)
        }
        return .absent
    }
}

/// A repository an agent worked in, resolved on the Mac.
package struct AgentWorkedRepository: Equatable, Sendable {
    package let project: LearnedTermProjectIdentity
    package let remote: ProjectRemote
    package let lastActive: Date
}

package enum AgentWorkedRepositories {
    /// The repositories `directories` belong to: each one's main checkout
    /// (`LearnedTermProjectResolver.resolveLocal`), the newest work in any
    /// of its worktrees, and its `origin`. A directory that is gone, outside
    /// git, or in a repository with no `origin` gives none. Newest first.
    package static func resolve(
        _ directories: [AgentTranscripts.WorkingDirectory], fileManager: FileManager = .default
    ) -> [AgentWorkedRepository] {
        var byKey: [String: AgentWorkedRepository] = [:]
        var origins: [String: ProjectRemote?] = [:]
        for directory in directories {
            let resolved = LearnedTermProjectResolver.resolveLocal(directory: directory.path, fileManager: fileManager)
            guard resolved.gitRoot != nil else { continue }
            let key = resolved.identity.key
            if let existing = byKey[key], existing.lastActive >= directory.lastActive { continue }
            let remote: ProjectRemote?
            if let known = origins[key] {
                remote = known
            } else {
                remote = origin(ofMainCheckout: key, fileManager: fileManager)
                origins[key] = remote
            }
            guard let remote else { continue }
            byKey[key] = AgentWorkedRepository(project: resolved.identity, remote: remote, lastActive: directory.lastActive)
        }
        return byKey.values.sorted {
            $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.project.key < $1.project.key
        }
    }

    /// The `url` of `[remote "origin"]` in the repository's config, read
    /// from the file rather than by running git: the scan resolves dozens of
    /// checkouts, and `QuickCaptureProjectLinker` reads it with git later.
    static func origin(ofMainCheckout checkout: String, fileManager: FileManager = .default) -> ProjectRemote? {
        let gitDirectory = RepoIndexing.resolveGitDirectory(root: checkout, fileManager: fileManager) ?? checkout
        let config = URL(fileURLWithPath: gitDirectory).appendingPathComponent("config")
        guard let data = fileManager.contents(atPath: config.path), data.count <= 1_048_576 else { return nil }
        var inOrigin = false
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let section = line.replacingOccurrences(of: " ", with: "").lowercased()
                inOrigin = section == #"[remote"origin"]"#
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return ProjectRemote(remoteURL: value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return nil
    }
}

/// Where agent activity is kept (`LearnedTermStore`).
package protocol AgentActivityRecording: Sendable {
    func recordAgentActivity(_ repositories: [AgentWorkedRepository], hostID: String?)
}

/// Reads this Mac's transcripts at launch and again at most every
/// `refreshInterval`, off the caller's thread, and records the
/// repositories found. Each polish asks for a refresh, like the skill
/// folders' (`AgentSkillStore.refreshLocalIfStale`).
package final class AgentProjectActivityScanner: Sendable {
    package static let refreshInterval: TimeInterval = 3600

    private let store: any AgentActivityRecording
    private let projectsRoot: URL
    private let now: @Sendable () -> Date
    private let lastScan = Mutex<Date?>(nil)
    private let queue = DispatchQueue(label: "localvoxtral.agent-activity", qos: .utility)

    package init(
        store: any AgentActivityRecording,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.projectsRoot = home.appendingPathComponent(AgentTranscripts.projectsFolder, isDirectory: true)
        self.now = now
    }

    package func refreshIfStale() {
        let moment = now()
        let due = lastScan.withLock { last -> Bool in
            if let last, moment.timeIntervalSince(last) < Self.refreshInterval { return false }
            last = moment
            return true
        }
        guard due else { return }
        queue.async { [self] in scan(now: moment) }
    }

    /// Returns once every scan asked for so far has recorded. For tests.
    package func waitForPendingWork() {
        queue.sync {}
    }

    private func scan(now moment: Date) {
        guard let directories = AgentTranscripts.recentWorkingDirectories(projectsRoot: projectsRoot, now: moment)
        else {
            // Missing or unreadable lists nothing, and never prunes: the
            // projects already listed age out on their own.
            Log.backends.info("Agent activity: no readable Claude Code transcripts folder; nothing listed")
            return
        }
        let repositories = Array(AgentWorkedRepositories.resolve(directories).prefix(PolishProjectNames.maxProjects))
        Log.backends.info(
            "Agent activity: \(directories.count, privacy: .public) recent transcript folders, \(repositories.count, privacy: .public) repositories"
        )
        guard !repositories.isEmpty else { return }
        store.recordAgentActivity(repositories, hostID: nil)
    }
}
