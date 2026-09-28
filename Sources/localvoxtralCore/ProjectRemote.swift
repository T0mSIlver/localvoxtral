import Foundation

/// A project's repository, as its `origin` names it (#971): `host/owner/repo`,
/// the same for every checkout of it. A checkout on the Mac and one on a host
/// are one project when their remotes agree, whatever their folders are
/// called. Only ever a label: never a path, never run.
package struct ProjectRemote: Equatable, Hashable, Sendable {
    /// `github.com/T0mSIlver/localvoxtral`, in the case the remote spells it.
    package let value: String

    /// Nil unless `value` is a host, then at least two path segments, all of
    /// letters, digits, `.`, `_` and `-`. A host is whatever the remote
    /// names, an ssh alias included, so two aliases of one server are two
    /// repositories.
    package init?(_ value: String) {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard value.utf8.count <= Self.maxBytes, segments.count >= 3,
              segments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.allSatisfy(Self.isAllowed) })
        else { return nil }
        self.value = value
    }

    private static let maxBytes = 200

    private static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
    }

    /// The learned-terms key of the repository's record: case folded, since
    /// GitHub and GitLab resolve names regardless of case.
    package var key: String { Self.keyPrefix + value.lowercased() }
    package static let keyPrefix = "repo:"

    /// `owner/repo`, or `group/sub/repo`: the remote without its host.
    package var path: String { String(value.drop { $0 != "/" }.dropFirst()) }
    /// The repository's own name, what the user calls the project.
    package var name: String { String(value.split(separator: "/").last ?? "") }
    /// `owner/name` when the remote is on github.com, what `gh` takes.
    package var githubRepository: String? {
        guard value.lowercased().hasPrefix("github.com/") else { return nil }
        return QuickCaptureInbox.isRepository(path) ? path : nil
    }

    /// A GitHub repository's remote.
    package init?(githubRepository repository: String) {
        guard QuickCaptureInbox.isRepository(repository) else { return nil }
        self.init("github.com/" + repository)
    }

    /// What a host's shim sent as `X-Lvx-Env-Repository`: `owner/name` for
    /// GitHub (every shim), or `host/path` for another host (#971 shims).
    package init?(header: String) {
        if let github = ProjectRemote(githubRepository: header) {
            self = github
        } else {
            self.init(header)
        }
    }

    /// A git remote URL: `https://`, `http://`, `ssh://` or `git://` with an
    /// optional user and port, or scp-style `user@host:path`; `.git` and
    /// slashes at either end dropped. Nil for a local path, a `file://`
    /// remote or any other shape.
    package init?(remoteURL raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        var path: Substring
        if let scheme = url.range(of: "://") {
            guard ["https", "http", "ssh", "git"].contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            let rest = url[scheme.upperBound...]
            let authority = rest.prefix { $0 != "/" }
            path = rest.dropFirst(authority.count)
            host = (authority.split(separator: "@").last ?? "").split(separator: ":").first ?? ""
        } else {
            // scp-style: a colon before any slash. `./x:y` or `/srv/x` is a path.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            host = url[..<colon].split(separator: "@").last ?? ""
            path = url[url.index(after: colon)...]
        }
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        self.init(host.lowercased() + "/" + path)
    }
}

extension LearnedTermProject {
    /// The repository record's key for a checkout linked to one.
    package var projectRemote: ProjectRemote? { remote.flatMap { ProjectRemote($0) } }
    /// The repository record's key for a checkout linked to one.
    package var repositoryRecordKey: String? { projectRemote?.key }
    /// This record is a repository's own record, not a checkout.
    package var isRepositoryRecord: Bool { key.hasPrefix(ProjectRemote.keyPrefix) }
}

/// One project per repository (#971): a checkout linked to a remote keeps no
/// terms of its own; every read and write for its key goes to the
/// repository's record, which all its checkouts share, on the Mac and on
/// hosts alike.
extension LearnedTerms {
    /// The record holding `key`'s terms: its repository's for a linked
    /// checkout, else its own.
    package func termRecord(_ key: String) -> LearnedTermProject? {
        termRecordIndex(key).map { projects[$0] }
    }

    func termRecordIndex(_ key: String) -> Int? {
        guard let index = projects.firstIndex(where: { $0.key == key }) else { return nil }
        guard projects[index].isLinkedCheckout, let repositoryKey = projects[index].repositoryRecordKey else { return index }
        return projects.firstIndex { $0.key == repositoryKey }
    }

    /// The repository's record, made when missing.
    mutating func repositoryRecordIndex(for remote: ProjectRemote, lastSeen: Date) -> Int {
        if let index = projects.firstIndex(where: { $0.key == remote.key }) { return index }
        var record = LearnedTermProject(key: remote.key, name: remote.name, terms: [], lastSeen: lastSeen)
        record.remote = remote.value
        record.repository = remote.githubRepository
        projects.append(record)
        return projects.count - 1
    }

    /// Links the checkout at `index` to `remote` and moves its terms and its
    /// agent's answer onto the repository's record: the same spelling on
    /// both keeps the higher count, never the sum, as a worktree fold does.
    /// A checkout already linked elsewhere keeps what it gave that record.
    mutating func link(checkoutAt index: Int, to remote: ProjectRemote) {
        guard !projects[index].isRepositoryRecord else { return }
        projects[index].remote = remote.value
        let checkout = projects[index]
        let target = repositoryRecordIndex(for: remote, lastSeen: checkout.lastSeen)
        guard !checkout.terms.isEmpty || checkout.hasProposalStamp else { return }
        projects[target].lastSeen = max(projects[target].lastSeen, checkout.lastSeen)
        projects[target].carryProposalStamp(from: checkout)
        for term in checkout.terms {
            let match = term.term.caseFoldedForMatching
            if let existing = projects[target].terms.firstIndex(where: { $0.term.caseFoldedForMatching == match }) {
                projects[target].terms[existing] = LearnedTerms.merged(projects[target].terms[existing], term)
            } else {
                projects[target].terms.append(term)
            }
        }
        guard let source = projects.firstIndex(where: { $0.key == checkout.key }) else { return }
        projects[source].terms = []
        projects[source].proposedAt = nil
        projects[source].proposalAttemptedAt = nil
        projects[source].proposalRevision = nil
        projects[source].agentLine = nil
        projects[source].agentLineAt = nil
    }

    /// Links every checkout whose `origin` was recorded before #971 (its
    /// GitHub `repository`, not one the user typed), and folds any terms a
    /// linked checkout still holds. Runs at every load; running it again
    /// changes nothing. Returns how many checkouts it linked or folded.
    @discardableResult
    package mutating func linkCheckoutsToRepositories(now: Date) -> Int {
        var changed = 0
        for key in projects.map(\.key) {
            guard let index = projects.firstIndex(where: { $0.key == key }),
                  !projects[index].isRepositoryRecord
            else { continue }
            let project = projects[index]
            let remote = project.projectRemote
                ?? (project.repositoryTyped == true ? nil : project.repository.flatMap(ProjectRemote.init(githubRepository:)))
            guard let remote, project.remote == nil || !project.terms.isEmpty || project.hasProposalStamp else { continue }
            link(checkoutAt: index, to: remote)
            changed += 1
        }
        if changed > 0 { prune(now: now) }
        return changed
    }

    /// A checkout's `origin` names `remote`. Links it, and keeps GitHub's
    /// `owner/name` for filing. Returns false when the checkout is gone.
    @discardableResult
    package mutating func recordOrigin(_ remote: ProjectRemote, projectKey: String) -> Bool {
        if let repository = remote.githubRepository {
            return recordOriginRepository(repository, projectKey: projectKey)
        }
        guard let index = projects.firstIndex(where: { $0.key == projectKey }) else { return false }
        link(checkoutAt: index, to: remote)
        return true
    }

    /// Drops records with nothing left to keep. A repository's record stays
    /// while a checkout links to it.
    mutating func removeEmptyProjects() {
        let linked = Set(projects.compactMap { $0.isLinkedCheckout ? $0.repositoryRecordKey : nil })
        projects.removeAll { $0.terms.isEmpty && !$0.isKeptWithoutTerms && !linked.contains($0.key) }
    }

    /// The projects, most recent first: each repository once, as its own
    /// record, and each checkout with no remote. What the learned-terms sheet
    /// and quick capture list (#891, #971). A repository is listed while one
    /// of its checkouts is (`listedCheckouts`).
    package func listedProjects(now: Date) -> [LearnedTermProject] {
        var seen = Set<String>()
        return listedCheckouts(now: now).compactMap { checkout in
            guard checkout.isLinkedCheckout, let remote = checkout.projectRemote else {
                return checkout
            }
            guard seen.insert(remote.key).inserted else { return nil }
            if let record = projects.first(where: { $0.key == remote.key }) { return record }
            var record = LearnedTermProject(key: remote.key, name: remote.name, terms: [], lastSeen: checkout.lastSeen)
            record.remote = remote.value
            record.repository = remote.githubRepository
            return record
        }
    }

    /// Every checkout of `repositoryKey`, in `listedCheckouts` order.
    package func checkouts(ofRepository repositoryKey: String, now: Date) -> [LearnedTermProject] {
        listedCheckouts(now: now).filter { $0.repositoryRecordKey == repositoryKey }
    }
}
