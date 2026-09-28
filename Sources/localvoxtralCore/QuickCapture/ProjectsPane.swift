import ClaudeContextWire
import Foundation

/// One row of the Projects pane (#939): a project quick capture lists, where
/// its issues go, where it is checked out, and what waits on it. Built from
/// the same projects the router sees (`QuickCaptureProjects.projects`), so a
/// repository checked out on the Mac and on a host is one row.
package struct ProjectsPaneRow: Equatable, Sendable, Identifiable {
    package enum Filing: Equatable, Sendable {
        /// File sends its issues to this repository.
        case repository(String)
        /// A fork whose owner has not picked between it and its upstream;
        /// File sends to the fork meanwhile.
        case forkUnpicked(fork: String, upstream: String)
        /// No GitHub repository: File asks for one.
        case noRepository
    }

    /// Who wrote the line the router reads for the project.
    package enum DescriptionSource: Equatable, Sendable {
        case user, github, agent, readme, none
    }

    package struct Sessions: Equatable, Sendable {
        package var running: Int
        /// The agents running, each once, in `ClaudeHookAgent` order.
        package var agents: [ClaudeHookAgent]
    }

    package var id: String { key }
    package let key: String
    package let keys: [String]
    package let name: String
    package let filing: Filing
    /// `owner/name` from `origin`, a host's report or the user's answer.
    package let repository: String?
    /// The user typed `repository` (no GitHub `origin`), so the pane may
    /// change it; an `origin` is changed in git.
    package let repositoryTyped: Bool
    /// GitHub's `parent` when the repository is a fork.
    package let upstream: String?
    package let issueRepository: String?
    package let checkedOutOnMac: Bool
    /// The hosts' names, in the order the hosts registry lists them.
    package let hostNames: [String]
    /// A remote checkout with no enrolled host to name: no hook named one
    /// since hosts were recorded, or its host was removed.
    package let hasUnnamedHost: Bool
    package let lastUsed: Date
    package let draftsWaiting: Int
    package let filed: Int
    package let description: String?
    package let descriptionSource: DescriptionSource
    /// The project's terms, strongest evidence first, each spelling once:
    /// a pinned copy wins over the other checkouts' copies.
    package let terms: [LearnedTerm]
    package let sessions: Sessions
    package let dictationsThisWeek: Int

    /// "Mac · devbox", as the table shows it; "This Mac · devbox" in the
    /// project's sheet.
    package func checkouts(macName: String = "Mac") -> String {
        var names: [String] = checkedOutOnMac ? [macName] : []
        names += hostNames
        if hasUnnamedHost { names.append("A remote host") }
        return names.joined(separator: " · ")
    }
}

/// The terms outside every row: the buckets no listed project holds, such
/// as a worktree name from before #652, a remote label no host named, or
/// the shared bucket. The last entry of the Projects table, "No project".
package struct ProjectsPaneUnlisted: Equatable, Sendable {
    /// The buckets, most recent first and the shared bucket last.
    package let keys: [String]
    package let terms: [LearnedTerm]
    package let lastUsed: Date
}

package enum ProjectsPane {
    /// Every row, most recently used first.
    ///
    /// - Parameters:
    ///   - projects: `QuickCaptureProjects.projects`, the router's list.
    ///   - hostNames: an enrolled host's name by its id, in the registry's
    ///     order; a host no longer enrolled is left out.
    ///   - dictationProjectKeys: the project key of each dictation in the
    ///     last seven days, nil for one outside any project.
    package static func rows(
        projects: [QuickCaptureProject],
        learned: LearnedTerms,
        captures: [QuickCaptureItem],
        hostNames: [(id: String, name: String)],
        liveSessions: [ClaudeSessionSnapshot],
        dictationProjectKeys: [String?]
    ) -> [ProjectsPaneRow] {
        let byKey = Dictionary(learned.projects.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionKeys = liveSessions.map { (projectKey(of: $0, localKeys: projects.flatMap(\.keys)), $0.agent) }
        let rows = projects.map { project -> ProjectsPaneRow in
            let members = project.keys.compactMap { byKey[$0] }
            let keys = Set(project.keys)
            let primary = byKey[project.key]
            let recordedHosts = Set(members.flatMap { $0.hostIDs ?? [] })
            let named = hostNames.filter { recordedHosts.contains($0.id) }.map(\.name)
            let isRemote = project.keys.contains { $0.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) }
            let mine = captures.filter { $0.projectKey.map(keys.contains) ?? false }
            let running: [ClaudeHookAgent] = sessionKeys.filter { $0.0.map(keys.contains) ?? false }.map(\.1)
            let sessions = ProjectsPaneRow.Sessions(
                running: running.count, agents: ClaudeHookAgent.allCases.filter(running.contains)
            )
            let lastUsed: Date = members.map { max($0.lastSeen, $0.reportedAt ?? $0.lastSeen) }.max() ?? .distantPast
            let dictations = dictationProjectKeys.filter { $0.map(keys.contains) ?? false }.count
            return ProjectsPaneRow(
                key: project.key,
                keys: project.keys,
                name: project.name,
                filing: filing(of: project, choice: primary?.filesUpstream),
                repository: project.repository,
                repositoryTyped: primary?.repositoryTyped == true,
                upstream: project.github?.parent,
                issueRepository: project.issueRepository,
                checkedOutOnMac: project.keys.contains { $0.hasPrefix("/") },
                hostNames: named,
                hasUnnamedHost: isRemote && named.isEmpty,
                lastUsed: lastUsed,
                draftsWaiting: mine.filter { $0.state != .filed }.count,
                filed: mine.filter { $0.state == .filed }.count,
                description: project.userLine ?? project.automaticLine,
                descriptionSource: descriptionSource(of: project),
                terms: terms(of: members),
                sessions: sessions,
                dictationsThisWeek: dictations
            )
        }
        return rows.sorted { lhs, rhs in
            lhs.lastUsed != rhs.lastUsed ? lhs.lastUsed > rhs.lastUsed : lhs.name < rhs.name
        }
    }

    static func filing(of project: QuickCaptureProject, choice: Bool?) -> ProjectsPaneRow.Filing {
        guard let repository = project.repository else { return .noRepository }
        if let upstream = project.github?.parent, choice == nil {
            return .forkUnpicked(fork: repository, upstream: upstream)
        }
        return .repository(project.issueRepository ?? repository)
    }

    static func descriptionSource(of project: QuickCaptureProject) -> ProjectsPaneRow.DescriptionSource {
        if project.userLine != nil { return .user }
        if project.githubLine != nil { return .github }
        if project.agentLine != nil { return .agent }
        if project.summary != nil { return .readme }
        return .none
    }

    static func terms(of members: [LearnedTermProject]) -> [LearnedTerm] {
        var seen = Set<String>()
        return members.flatMap(\.terms)
            .sorted(by: LearnedTerms.isStrongerEvidence)
            .filter { seen.insert($0.term.caseFoldedForMatching).inserted }
    }

    /// The "No project" entry: every bucket that holds terms and that no
    /// row's keys name, so each stored term shows under exactly one entry.
    /// Nil when there is none.
    package static func unlisted(learned: LearnedTerms, rows: [ProjectsPaneRow]) -> ProjectsPaneUnlisted? {
        let listed = Set(rows.flatMap(\.keys))
        let shared = LearnedTermProjectResolver.shared.key
        let buckets = learned.projects
            .filter { !listed.contains($0.key) && !$0.terms.isEmpty }
            .sorted { lhs, rhs in
                if (lhs.key == shared) != (rhs.key == shared) { return rhs.key == shared }
                return lhs.lastSeen != rhs.lastSeen ? lhs.lastSeen > rhs.lastSeen : lhs.key < rhs.key
            }
        guard let latest = buckets.map(\.lastSeen).max() else { return nil }
        return ProjectsPaneUnlisted(keys: buckets.map(\.key), terms: terms(of: buckets), lastUsed: latest)
    }

    /// The sheet's search: the terms whose spelling holds `query`, ignoring
    /// case; every term for an empty query.
    package static func matching(_ terms: [LearnedTerm], query: String) -> [LearnedTerm] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).caseFoldedForMatching
        guard !needle.isEmpty else { return terms }
        return terms.filter { $0.term.caseFoldedForMatching.contains(needle) }
    }

    /// The line under a term in the sheet. A term below the bar is still
    /// being learned, or was proposed by the project's coding agent (#609),
    /// so it says how far along it is instead.
    package static func detail(for term: LearnedTerm) -> (text: String, lastApplied: Date?) {
        guard term.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) else {
            let progress = "heard in \(term.dictations) of \(LearnedTerms.confirmedDictations) dictations"
            if let proposer = term.proposerDisplayName {
                return ("Proposed by \(proposer): \(progress)", nil)
            }
            return ("Learning: \(progress)", nil)
        }
        switch term.appliedCount {
        case 0: return ("Not applied yet", nil)
        case 1: return ("Applied once,", term.lastApplied)
        case let count: return ("Applied \(count) times, last", term.lastApplied)
        }
    }

    /// The project a live session works in: a remote one's label key, a
    /// local one's checkout that holds its directory (worktrees inside the
    /// checkout included). Nil for a session outside every listed checkout.
    static func projectKey(of session: ClaudeSessionSnapshot, localKeys: [String]) -> String? {
        switch session.learnedTermWorkspace {
        case .remoteOpaque(let label)?:
            return LearnedTermProjectResolver.remoteKeyPrefix + label
        case .local(let path)?:
            let directory = path.path
            return localKeys
                .filter { $0.hasPrefix("/") && (directory == $0 || directory.hasPrefix($0 + "/")) }
                .max { $0.count < $1.count }
        case nil:
            return nil
        }
    }

    /// "now", "2 h", "yesterday", "3 days": the table's Last used column.
    package static func lastUsed(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 3_600 { return "now" }
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return "\(Int(seconds / 3_600)) h" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        return days <= 1 ? "yesterday" : "\(days) days"
    }
}
