import Foundation

/// A project the user forgot in Settings → Projects (#1156): the agent-activity
/// listing (#1027) does not bring it back. A dictation or a hook does, and
/// that clears it.
package struct ForgottenProject: Codable, Equatable, Sendable {
    /// The repository's record key and every checkout key the project had.
    package var keys: [String]
    package var forgottenAt: Date

    package init(keys: [String], forgottenAt: Date) {
        self.keys = keys
        self.forgottenAt = forgottenAt
    }
}

/// The tombstones, as `forgotten-projects.json` holds them. Their own file,
/// for the reason `IgnoredProjects` has its own: a build from before them
/// would write either other file back without them.
package struct ForgottenProjects: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int = ForgottenProjects.currentVersion
    package var projects: [ForgottenProject] = []
    /// The file could not be read: any repo may be a forgotten one, so the
    /// agent-activity listing adds nothing. Never written.
    package var isUnreadable = false

    private enum CodingKeys: String, CodingKey {
        case version, projects
    }

    package init(projects: [ForgottenProject] = []) {
        self.projects = projects
    }

    package func contains(key: String) -> Bool {
        projects.contains { $0.keys.contains(key) }
    }

    /// Keeps `project` out, merged into any tombstone that shares a key.
    package mutating func add(_ project: ForgottenProject) {
        var keys = Set(project.keys)
        projects.removeAll { tombstone in
            guard !keys.isDisjoint(with: tombstone.keys) else { return false }
            keys.formUnion(tombstone.keys)
            return true
        }
        projects.append(ForgottenProject(keys: keys.sorted(), forgottenAt: project.forgottenAt))
    }

    /// Clears every tombstone that holds one of `keys`.
    package mutating func revive(keys: Set<String>) {
        projects.removeAll { !keys.isDisjoint(with: $0.keys) }
    }
}

extension LearnedTerms {
    /// Whether the agent-activity listing must leave `projectKey`, or a
    /// checkout whose `origin` is `remote`, alone.
    package func isForgotten(projectKey: String, remote: ProjectRemote) -> Bool {
        forgotten.isUnreadable || forgotten.contains(key: projectKey) || forgotten.contains(key: remote.key)
    }

    /// The keys `forgetProject(keys:)` deletes records under, and `keys`
    /// themselves: the project's tombstone.
    package func keysForgotten(by keys: [String]) -> [String] {
        var doomed = Set(keys)
        for key in keys {
            if let repositoryKey = projects.first(where: { $0.key == key })?.repositoryRecordKey {
                doomed.insert(repositoryKey)
            }
        }
        for record in projects where record.repositoryRecordKey.map(doomed.contains) == true {
            doomed.insert(record.key)
        }
        return doomed.sorted()
    }

    /// Clears the tombstone of every forgotten project a write brought back
    /// since `before`: a record it created, or one whose dictation
    /// (`lastSeen`) or hook (`reportedAt`) it advanced. The agent-activity
    /// listing never does either for a forgotten project, so only a
    /// dictation, a hook or the user's own action clears one. Returns the
    /// keys that cleared them, empty when none did.
    @discardableResult
    package mutating func reviveForgottenProjects(since before: LearnedTerms) -> Set<String> {
        guard !forgotten.projects.isEmpty else { return [] }
        var revived = Set<String>()
        for record in projects {
            let keys = [record.key] + (record.repositoryRecordKey.map { [$0] } ?? [])
            guard keys.contains(where: forgotten.contains(key:)) else { continue }
            if let old = before.projects.first(where: { $0.key == record.key }),
               record.lastSeen <= old.lastSeen, (record.reportedAt ?? .distantPast) <= (old.reportedAt ?? .distantPast)
            {
                continue
            }
            revived.formUnion(keys)
        }
        forgotten.revive(keys: revived)
        return revived
    }

    /// Finishes a forget that did not land: drops every record of a
    /// forgotten project with no dictation (`lastSeen`) or hook
    /// (`reportedAt`) since it was forgotten, such as one a crash between the
    /// tombstone and the terms left, or one an older build's agent listing
    /// added back. Runs after `reviveForgottenProjects`, so what a write just
    /// brought back stays. Returns how many records went.
    @discardableResult
    package mutating func removeForgottenLeftovers() -> Int {
        guard !forgotten.projects.isEmpty, !forgotten.isUnreadable else { return 0 }
        let before = projects.count
        projects.removeAll { record in
            let keys = [record.key] + (record.repositoryRecordKey.map { [$0] } ?? [])
            guard let tombstone = forgotten.projects.first(where: { !Set($0.keys).isDisjoint(with: keys) })
            else { return false }
            return record.lastSeen <= tombstone.forgottenAt
                && (record.reportedAt ?? .distantPast) <= tombstone.forgottenAt
        }
        return before - projects.count
    }
}
