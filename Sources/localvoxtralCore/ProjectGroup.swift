import ClaudeContextWire
import Foundation

/// Which side of the speaker's life a project belongs to (#1005): a work
/// repo's names must not reach a personal dictation, and the reverse. The
/// user picks it per project in Settings → Projects; a project in no group
/// behaves as before.
///
/// A dictation's group is its joined project's. Every read that crosses
/// projects (the project names polish carries, the second pass's confirmed
/// terms, quick capture's routing and polish) then sees only that group's
/// projects. A dictation with no join, or joined to a project in no group,
/// sees every project, as before.
///
/// A string, not a closed enum: a group a later build adds must not make
/// this build's decode of `learned-terms.json` fail and refuse the file.
package struct ProjectGroup: RawRepresentable, Codable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let work = ProjectGroup(rawValue: "work")
    package static let personal = ProjectGroup(rawValue: "personal")

    /// The groups Settings offers, in its order.
    package static let builtIn: [ProjectGroup] = [.work, .personal]

    package var displayName: String {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        default: rawValue.capitalized
        }
    }
}

extension LearnedTerms {
    /// Puts every record in `keys` in `group`, nil taking them out of any.
    /// A Projects row's keys are its checkouts and its repository's record,
    /// so a checkout that links to the repository later reads the group
    /// from that record (`group(ofProjectKey:)`).
    package mutating func setGroup(_ group: ProjectGroup?, keys: [String]) {
        let keys = Set(keys)
        for index in projects.indices where keys.contains(projects[index].key) {
            projects[index].group = group
        }
    }

    /// The group of the record keyed `key`: its own, else, for a repository
    /// and its checkouts, the first any of them holds.
    package func group(ofProjectKey key: String) -> ProjectGroup? {
        guard let record = projects.first(where: { $0.key == key }) else { return nil }
        if let group = record.group { return group }
        guard let repositoryKey = record.isRepositoryRecord ? record.key : record.repositoryRecordKey else {
            return nil
        }
        return projects.lazy
            .filter { $0.key == repositoryKey || $0.repositoryRecordKey == repositoryKey }
            .compactMap(\.group).first
    }

    /// The group of a dictation whose project resolved to `key`
    /// (`LearnedTermProjectResolver.resolve`). On the commit path the join
    /// gives the session's own directory, which may sit below its checkout's
    /// root, so a local key reads the deepest recorded checkout that holds
    /// it. Nil for no project.
    package func group(ofDictationProject key: String?) -> ProjectGroup? {
        guard let key else { return nil }
        if projects.contains(where: { $0.key == key }) { return group(ofProjectKey: key) }
        guard key.hasPrefix("/") else { return nil }
        let holder = projects
            .filter { $0.key.hasPrefix("/") && key.hasPrefix($0.key.hasSuffix("/") ? $0.key : $0.key + "/") }
            .max { $0.key.count < $1.key.count }
        return holder.flatMap { group(ofProjectKey: $0.key) }
    }

    /// The group of a dictation joined to a session in `workspace`
    /// (`ClaudeSessionSnapshot.learnedTermWorkspace`); nil with no join.
    package func group(ofJoinedWorkspace workspace: ClaudeWorkspaceReference?) -> ProjectGroup? {
        guard let workspace else { return nil }
        let project = LearnedTermProjectResolver.resolve(repositoryRoot: .unknown, workspace: workspace)
        return group(ofDictationProject: project?.key)
    }

    /// What a dictation in `group` may read across projects: the projects
    /// in that group, with the shared bucket and every project in no group
    /// left out. Nil reads everything, as before groups.
    package func inGroup(_ group: ProjectGroup?) -> LearnedTerms {
        guard let group else { return self }
        var copy = self
        copy.projects = projects.filter { self.group(ofProjectKey: $0.key) == group }
        return copy
    }
}
