import Foundation

/// One project the learned terms list (#891, #971), as the Projects pane and
/// the polish prompt see it: one per repository, named after it, whichever
/// checkouts it has on the Mac and on hosts.
/// Nothing here comes from the screen or the clipboard.
package struct ListedProject: Equatable, Sendable {
    /// `LearnedTermProject.key`: a main checkout's path, or `remote:<label>`.
    /// For a repository checked out in several places, the Mac's checkout
    /// when its folder is there.
    package let key: String
    /// Every checkout's key, `key` first, then the repository record's
    /// (`repo:<remote>`) when the project has a remote.
    package let keys: [String]
    package let name: String
    /// Confirmed terms and the agent's proposals of every checkout, each
    /// spelling once, capped at `ListedProjects.maxTerms`.
    package let terms: [String]
    /// `owner/name` from the project's `origin`.
    package let repository: String?
    /// The user's Work or Personal choice (#1005), nil in no group.
    package let group: ProjectGroup?

    package init(
        key: String, name: String, terms: [String],
        keys: [String]? = nil, repository: String? = nil, group: ProjectGroup? = nil
    ) {
        self.key = key
        self.keys = keys ?? [key]
        self.name = name
        self.terms = terms
        self.repository = repository
        self.group = group
    }

    func renamed(_ name: String) -> ListedProject {
        ListedProject(key: key, name: name, terms: terms, keys: keys, repository: repository, group: group)
    }
}

package enum ListedProjects {
    package static let maxTerms = 30

    /// Every listed project (`LearnedTerms.listedCheckouts`), most recent
    /// first. Projects that name one repository are one entry (#926): the
    /// Mac's checkout's key, else the most recent, with the terms of all of
    /// them. A Mac checkout whose folder is gone leads only when no host has
    /// the repository.
    ///
    /// - Parameter checkoutExists: whether a local project root is still a
    ///   folder.
    package static func projects(
        from learned: LearnedTerms,
        now: Date,
        checkoutExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> [ListedProject] {
        let listed = learned.listedCheckouts(now: now)
        var groups: [[LearnedTermProject]] = []
        var groupOfRepository: [String: Int] = [:]
        for project in listed {
            let repository = project.repositoryRecordKey ?? project.repository.map { "github:" + $0 }
            if let repository, let index = groupOfRepository[repository] {
                groups[index].append(project)
            } else {
                if let repository { groupOfRepository[repository] = groups.count }
                groups.append([project])
            }
        }
        let built = groups.map { group -> (project: ListedProject, remote: ProjectRemote?) in
            // A repository record is listed as its own entry, and leads only
            // when no checkout is listed.
            var members = group.filter { $0.key.hasPrefix("/") }
                + group.filter { !$0.key.hasPrefix("/") && !$0.isRepositoryRecord }
            let checkoutCount = members.count
            members += group.filter(\.isRepositoryRecord)
            if checkoutCount > 1,
               let lead = members.prefix(checkoutCount).firstIndex(where: { !$0.key.hasPrefix("/") || checkoutExists($0.key) })
            {
                members.insert(members.remove(at: lead), at: 0)
            }
            let primary = members[0]
            // The repository's own record holds a linked project's terms
            // (#971).
            let remote = primary.isLinkedCheckout || primary.isRepositoryRecord ? primary.projectRemote : nil
            let repositoryRecord = remote.flatMap { remote in
                members.contains { $0.key == remote.key } ? nil : learned.projects.first { $0.key == remote.key }
            }
            let records = members + (repositoryRecord.map { [$0] } ?? [])
            var seen = Set<String>()
            var terms: [String] = []
            for member in records {
                for term in learned.confirmedTerms(projectKey: member.key) + learned.unconfirmedProposals(projectKey: member.key)
                where seen.insert(term.caseFoldedForMatching).inserted {
                    terms.append(term)
                }
            }
            var keys = members.map(\.key)
            if let remote, !keys.contains(remote.key) { keys.append(remote.key) }
            let project = ListedProject(
                key: primary.key,
                name: remote?.name ?? primary.name,
                terms: Array(terms.prefix(maxTerms)),
                keys: keys,
                repository: primary.repository,
                group: keys.lazy.compactMap { learned.group(ofProjectKey: $0) }.first
            )
            return (project, remote)
        }
        return named(built)
    }

    /// Each project under its repository's name; `owner/repo` for those that
    /// share a name with another listed project and have a remote to tell
    /// them apart (#971).
    static func named(_ built: [(project: ListedProject, remote: ProjectRemote?)]) -> [ListedProject] {
        var counts: [String: Int] = [:]
        for entry in built { counts[entry.project.name.caseFoldedForMatching, default: 0] += 1 }
        return built.map { entry in
            guard counts[entry.project.name.caseFoldedForMatching, default: 0] > 1, let remote = entry.remote else {
                return entry.project
            }
            return entry.project.renamed(remote.path)
        }
    }
}
