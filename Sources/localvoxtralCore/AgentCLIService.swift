import ClaudeContextWire
import Foundation

/// What the `localvoxtral` command reads and writes in the app (#721). The
/// app's implementation reads the history store, the learned terms and
/// Settings; tests pass a fixture.
package protocol AgentCLIDataSource: Sendable {
    /// False under History's "Don't keep".
    func historyKept() async -> Bool
    /// Newest first: dictations whose transcript or final text contains
    /// `text` (all of them when empty), started at or after `since`.
    func dictations(matching text: String, since: Date?, limit: Int) async -> [AgentCLIDictation]
    /// The last dictation, inserted or not, whether or not History holds it.
    func lastDictation() async -> AgentCLIDictation?
    /// Settings' Names and terms.
    func userTerms() async -> [String]
    /// Term suggestions the user refused; a proposal never repeats them.
    func refusedTerms() async -> [String]
    func learnedTerms() async -> LearnedTerms
    /// Adds proposed terms (`LearnedTerms.recordCommandProposal`) and returns
    /// the ones added.
    func recordProposal(
        _ terms: [String],
        proposer: String,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    ) async -> [String]
    func status() async -> AgentCLIStatus
}

/// Answers the command's requests. Everything here is the part that does not
/// need the app: argument checks, the project filter, what each state of a
/// term is called, which proposed terms are refused and why.
package struct AgentCLIService: Sendable {
    /// With `--project`, history is filtered after the store's own query, so
    /// the store is asked for this many to have enough left after it.
    package static let projectFilterFetchLimit = 5_000

    private let source: any AgentCLIDataSource
    private let resolveLocalProject: @Sendable (String) -> LearnedTermProjectIdentity?

    /// - Parameter resolveLocalProject: the project a local directory belongs
    ///   to, nil when there is no such directory.
    package init(
        source: any AgentCLIDataSource,
        resolveLocalProject: @escaping @Sendable (String) -> LearnedTermProjectIdentity? = AgentCLIService.resolveOnDisk
    ) {
        self.source = source
        self.resolveLocalProject = resolveLocalProject
    }

    package static let resolveOnDisk: @Sendable (String) -> LearnedTermProjectIdentity? = { path in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return LearnedTermProjectResolver.resolveLocal(directory: path).identity
    }

    package func respond(to request: AgentCLIRequest) async -> AgentCLIResponse {
        guard let command = request.knownCommand else {
            Log.backends.error("CLI: unknown command")
            return .failure(.unknownCommand, "unknown command: \(request.command)")
        }
        let response: AgentCLIResponse
        switch command {
        case .historySearch: response = await historySearch(request)
        case .historyLast: response = await historyLast(request)
        case .termsList: response = await termsList(request)
        case .termsPropose: response = await termsPropose(request)
        case .status: response = AgentCLIResponse(status: await source.status())
        }
        if let error = response.error {
            Log.backends.error(
                "CLI: \(command.rawValue, privacy: .public) failed: \(error.code.rawValue, privacy: .public)"
            )
        } else {
            Log.backends.info("CLI: answered \(command.rawValue, privacy: .public)")
        }
        return response
    }

    // MARK: History

    private func historySearch(_ request: AgentCLIRequest) async -> AgentCLIResponse {
        let limit = request.limit ?? AgentCLIWire.defaultHistoryLimit
        guard (1...AgentCLIWire.maxHistoryLimit).contains(limit) else {
            return .failure(.badRequest, "--limit must be between 1 and \(AgentCLIWire.maxHistoryLimit)")
        }
        guard await source.historyKept() else {
            return AgentCLIResponse(history: AgentCLIHistory(historyKept: false, dictations: []))
        }
        let filter: ProjectFilter?
        switch projectFilter(request.project) {
        case .success(let value): filter = value
        case .failure(let error): return AgentCLIResponse(error: error)
        }
        let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var dictations = await source.dictations(
            matching: text,
            since: request.since,
            limit: filter == nil ? limit : Self.projectFilterFetchLimit
        )
        if let filter {
            var cache: [String: String] = [:]
            dictations = dictations.filter { filter.matches($0.project, cache: &cache) }
        }
        return AgentCLIResponse(
            history: AgentCLIHistory(historyKept: true, dictations: Array(dictations.prefix(limit)))
        )
    }

    private func historyLast(_ request: AgentCLIRequest) async -> AgentCLIResponse {
        guard await source.historyKept() else {
            return AgentCLIResponse(history: AgentCLIHistory(historyKept: false, dictations: []))
        }
        let last = await source.lastDictation()
        return AgentCLIResponse(history: AgentCLIHistory(historyKept: true, dictations: last.map { [$0] } ?? []))
    }

    // MARK: Terms

    private func termsList(_ request: AgentCLIRequest) async -> AgentCLIResponse {
        let filter: ProjectFilter?
        switch projectFilter(request.project) {
        case .success(let value): filter = value
        case .failure(let error): return AgentCLIResponse(error: error)
        }
        let memory = await source.learnedTerms()
        var cache: [String: String] = [:]
        let projects = memory.projects
            .filter { project in
                filter?.matches(AgentCLIProject(key: project.key, name: project.name), cache: &cache) ?? true
            }
            .sorted { lhs, rhs in
                let lhsShared = lhs.key == LearnedTermProjectResolver.shared.key
                let rhsShared = rhs.key == LearnedTermProjectResolver.shared.key
                if lhsShared != rhsShared { return rhsShared }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.key < rhs.key
            }
            .map { project in
                AgentCLITermProject(
                    project: AgentCLIProject(key: project.key, name: project.name),
                    terms: project.terms.sorted(by: LearnedTerms.isStrongerEvidence).map(Self.term)
                )
            }
        return AgentCLIResponse(terms: AgentCLITerms(userTerms: await source.userTerms(), projects: projects))
    }

    package static func term(_ term: LearnedTerm) -> AgentCLITerm {
        let state: AgentCLITerm.State
        if term.isPinned {
            state = .pinned
        } else if term.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) {
            state = .confirmed
        } else if term.isUnconfirmedProposal {
            state = .proposed
        } else {
            state = .learning
        }
        return AgentCLITerm(
            term: term.term,
            state: state,
            dictations: term.dictations,
            proposedBy: term.proposerName,
            lastSeen: term.lastSeen
        )
    }

    private func termsPropose(_ request: AgentCLIRequest) async -> AgentCLIResponse {
        let raw = request.terms ?? []
        guard !raw.isEmpty else { return .failure(.badRequest, "no terms to propose") }
        guard let argument = request.project?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argument.isEmpty
        else { return .failure(.badRequest, "--project is required") }

        let memory = await source.learnedTerms()
        let project: LearnedTermProjectIdentity
        if argument.hasPrefix("/") {
            guard let resolved = resolveLocalProject(argument) else {
                return .failure(.unknownProject, "no such directory: \(argument)")
            }
            project = resolved
        } else {
            // A name can only reach a project the terms already hold: a
            // name alone says nothing about where it is.
            guard let existing = memory.projects.first(where: {
                $0.name.caseInsensitiveCompare(argument) == .orderedSame
            }) else {
                return .failure(.unknownProject, "no project named \(argument); pass its directory")
            }
            project = LearnedTermProjectIdentity(key: existing.key, name: existing.name)
        }

        let userList = await source.userTerms() + source.refusedTerms()
        let userKeys = Set(userList.map(\.caseFoldedForMatching))
        var known = Set(
            memory.projects.first { $0.key == project.key }?.terms.map(\.term.caseFoldedForMatching) ?? []
        )
        var accepted: [String] = []
        var skipped: [AgentCLIProposal.Skipped] = []
        for candidate in raw {
            guard accepted.count < AgentCLIWire.maxProposedTerms else {
                skipped.append(.init(term: candidate, reason: .overLimit))
                continue
            }
            guard let term = ProjectTermProposal.acceptedTerms([candidate]).first else {
                skipped.append(.init(term: candidate, reason: .notTermShaped))
                continue
            }
            let key = term.caseFoldedForMatching
            if userKeys.contains(key) {
                skipped.append(.init(term: term, reason: .userList))
            } else if !known.insert(key).inserted {
                skipped.append(.init(term: term, reason: .known))
            } else {
                accepted.append(term)
            }
        }

        let caller = request.caller ?? .unknown
        let added = accepted.isEmpty
            ? []
            : await source.recordProposal(accepted, proposer: caller.rawValue, project: project, excluding: userList)
        let addedKeys = Set(added.map(\.caseFoldedForMatching))
        // Accepted here but not added there: the store already held it by
        // the time the write ran.
        for term in accepted where !addedKeys.contains(term.caseFoldedForMatching) {
            skipped.append(.init(term: term, reason: .known))
        }
        Log.backends.info(
            "CLI: \(caller.rawValue, privacy: .public) proposed \(raw.count, privacy: .public) terms, \(added.count, privacy: .public) added"
        )
        return AgentCLIResponse(
            proposal: AgentCLIProposal(
                project: AgentCLIProject(key: project.key, name: project.name),
                added: added,
                skipped: skipped
            )
        )
    }

    // MARK: Project filter

    /// `--project` as a filter: an absolute path matches every project in
    /// the same repository, a name matches by name.
    private struct ProjectFilter {
        let key: String?
        let name: String?
        let resolveLocalProject: @Sendable (String) -> LearnedTermProjectIdentity?

        /// A history entry keeps the joined session's directory, which may be
        /// a subdirectory or a worktree; resolving it (once per directory)
        /// puts it in its repository.
        func matches(_ project: AgentCLIProject?, cache: inout [String: String]) -> Bool {
            guard let project else { return false }
            if let name {
                return project.name.caseInsensitiveCompare(name) == .orderedSame
            }
            guard let key else { return false }
            if project.key == key { return true }
            guard project.key.hasPrefix("/") else { return false }
            if let resolved = cache[project.key] { return resolved == key }
            let resolved = resolveLocalProject(project.key)?.key ?? project.key
            cache[project.key] = resolved
            return resolved == key
        }
    }

    private func projectFilter(_ argument: String?) -> Result<ProjectFilter?, AgentCLIError> {
        guard let argument = argument?.trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty else {
            return .success(nil)
        }
        guard argument.hasPrefix("/") else {
            return .success(ProjectFilter(key: nil, name: argument, resolveLocalProject: resolveLocalProject))
        }
        guard let project = resolveLocalProject(argument) else {
            return .failure(AgentCLIError(.unknownProject, "no such directory: \(argument)"))
        }
        return .success(ProjectFilter(key: project.key, name: nil, resolveLocalProject: resolveLocalProject))
    }
}

extension AgentCLIJoin {
    /// What `status` reports about a join. The project is the session's own
    /// directory or remote label, as the history records it; nothing is read
    /// from disk.
    package init(_ join: ClaudeSessionJoin) {
        self.init(
            agent: join.snapshot.agent.rawValue,
            project: AgentCLIProject(joinedWorkspace: join.snapshot.learnedTermWorkspace),
            mechanism: ClaudeSessionJoinSummary.armName(join.mechanism),
            remote: !join.snapshot.origin.isLocalAuthenticated
        )
    }
}

extension AgentCLIProject {
    /// The joined session's directory, or its remote label. Nil without a
    /// workspace.
    package init?(joinedWorkspace workspace: ClaudeWorkspaceReference?) {
        guard let identity = LearnedTermProjectResolver.resolve(repositoryRoot: .unknown, workspace: workspace) else {
            return nil
        }
        self.init(key: identity.key, name: identity.name)
    }
}
