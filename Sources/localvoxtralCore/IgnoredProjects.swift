import Foundation

/// A repository the user took out of Projects for good (#1006): nothing is
/// recorded, learned or proposed for it again, and no cross-project use
/// reads it. Dictation there goes on as anywhere else.
package struct IgnoredProject: Codable, Equatable, Sendable {
    /// The repository's record key (`repo:<remote>`), or the checkout's own
    /// key for a project with no remote.
    package var key: String
    /// What the Ignored list shows.
    package var name: String
    /// Every checkout key the project had when it was ignored. A checkout
    /// is ignored by its key before its `origin` is read again.
    package var checkouts: [String]
    package var ignoredAt: Date

    package init(key: String, name: String, checkouts: [String], ignoredAt: Date) {
        self.key = key
        self.name = name
        self.checkouts = checkouts
        self.ignoredAt = ignoredAt
    }
}

/// The ignore list, as `ignored-projects.json` holds it. Its own file, not a
/// field of `learned-terms.json`: a build from before the field would
/// decode that file and write it back without the list, and the opt-out
/// would be gone after one launch of an older build.
package struct IgnoredProjects: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int = IgnoredProjects.currentVersion
    package var projects: [IgnoredProject] = []
    /// The file could not be read (#989): any repo may be an ignored one, so
    /// `LearnedTerms.isIgnored` answers true for all of them. Never written.
    package var isUnreadable = false

    private enum CodingKeys: String, CodingKey {
        case version, projects
    }

    package init(projects: [IgnoredProject] = []) {
        self.projects = projects
    }

    /// Whether `key` (a checkout's or a repository's) belongs to an ignored
    /// project.
    package func contains(key: String) -> Bool {
        projects.contains { $0.key == key || $0.checkouts.contains(key) }
    }

    /// The checkouts `other` knows for entries this list holds: a sweep
    /// found them (`removeIgnoredProjects`). Entries are never added or
    /// removed here, so an un-ignore another copy wrote stays.
    package mutating func adoptCheckouts(from other: IgnoredProjects) {
        for index in projects.indices {
            guard let found = other.projects.first(where: { $0.key == projects[index].key }) else { continue }
            let merged = Array(Set(projects[index].checkouts + found.checkouts)).sorted()
            if merged != projects[index].checkouts { projects[index].checkouts = merged }
        }
    }

    /// Whether the record is an ignored project's: by its own key, or by the
    /// repository its checkout links to.
    package func contains(_ record: LearnedTermProject) -> Bool {
        contains(key: record.key) || record.repositoryRecordKey.map(contains(key:)) == true
    }
}

extension LearnedTerms {
    /// Whether a dictation in `projectKey`, or in a checkout whose `origin`
    /// is `remote`, belongs to an ignored project, or may, while the list
    /// is unreadable.
    package func isIgnored(projectKey: String, remote: ProjectRemote? = nil) -> Bool {
        if ignored.isUnreadable { return true }
        if ignored.contains(key: projectKey) { return true }
        if let remote, ignored.contains(key: remote.key) { return true }
        return projects.first { $0.key == projectKey }.map(ignored.contains) ?? false
    }

    /// Drops every record of an ignored project. Runs after every write and
    /// at load, so a write that just added one, or an older build's record,
    /// never stays. Returns how many records went.
    /// A checkout found through its `origin`, such as a new clone, joins
    /// its entry's checkouts, so its next dictation is known at once.
    @discardableResult
    package mutating func removeIgnoredProjects() -> Int {
        guard !ignored.projects.isEmpty else { return 0 }
        for record in projects where !record.isRepositoryRecord && !ignored.contains(key: record.key) {
            guard let repositoryKey = record.repositoryRecordKey,
                  let entry = ignored.projects.firstIndex(where: { $0.key == repositoryKey })
            else { continue }
            ignored.projects[entry].checkouts.append(record.key)
        }
        let before = projects.count
        projects.removeAll(where: ignored.contains)
        return before - projects.count
    }

    /// Forget Project in Settings → Projects: deletes the records of the
    /// project that `keys` names (a row's checkouts and its repository's
    /// record), every checkout linked to that repository, and their terms.
    /// Nothing else is touched. The next dictation there starts it again.
    /// Returns how many records went.
    @discardableResult
    package mutating func forgetProject(keys: [String]) -> Int {
        var doomed = Set(keys)
        for key in keys {
            if let repositoryKey = projects.first(where: { $0.key == key })?.repositoryRecordKey {
                doomed.insert(repositoryKey)
            }
        }
        let before = projects.count
        projects.removeAll { doomed.contains($0.key) || $0.repositoryRecordKey.map(doomed.contains) == true }
        return before - projects.count
    }

    /// Ignore Project: forgets it (`forgetProject`) and keeps it out from
    /// now on. `key` is the row's repository record key, or its checkout's
    /// when it has no remote.
    package mutating func ignoreProject(key: String, name: String, keys: [String], now: Date) {
        var checkouts = keys.filter { $0 != key }
        for record in projects where record.repositoryRecordKey == key && !checkouts.contains(record.key) {
            checkouts.append(record.key)
        }
        if let index = ignored.projects.firstIndex(where: { $0.key == key }) {
            ignored.projects[index].checkouts = Array(Set(ignored.projects[index].checkouts + checkouts)).sorted()
        } else {
            ignored.projects.append(IgnoredProject(key: key, name: name, checkouts: checkouts.sorted(), ignoredAt: now))
        }
        forgetProject(keys: [key] + checkouts)
    }

    /// Un-ignore: the project comes back the next time it is dictated in.
    package mutating func unignoreProject(key: String) {
        ignored.projects.removeAll { $0.key == key }
    }
}
