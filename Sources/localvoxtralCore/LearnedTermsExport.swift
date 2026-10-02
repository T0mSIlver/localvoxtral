import Foundation

/// The file a user moves learned terms between machines with (#523): the
/// whole memory, terms still being learned included, so a term heard twice
/// here does not start again at zero there.
///
/// Import accepts the app's own `learned-terms.json` too: `projects` has the
/// same shape, and only the `format` tag is missing.
package enum LearnedTermsExport {
    package static let format = "localvoxtral.learned-terms"
    package static let defaultFileName = "localvoxtral-learned-terms.json"

    package enum ImportError: Error, Equatable {
        /// Not JSON, not this shape, or another app's file.
        case unreadable
        /// Written by a build newer than this one. Guessing at it could drop
        /// what the newer build added, so nothing is imported.
        case newerVersion
    }

    /// Terms from the file that are in the memory after the merge, and the
    /// projects holding them.
    package struct ImportSummary: Equatable, Sendable {
        package let terms: Int
        package let projects: Int

        package init(terms: Int, projects: Int) {
            self.terms = terms
            self.projects = projects
        }
    }

    private struct File: Codable {
        var format: String?
        var version: Int
        var exportedAt: Date?
        var projects: [LearnedTermProject]
    }

    package static func data(for terms: LearnedTerms, exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            File(
                format: format,
                version: LearnedTerms.currentVersion,
                exportedAt: exportedAt,
                projects: terms.projects
            )
        )
    }

    /// The projects in an export, or in the app's own file.
    package static func projects(from data: Data) throws(ImportError) -> [LearnedTermProject] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data),
              file.format == nil || file.format == format
        else { throw .unreadable }
        guard file.version <= LearnedTerms.currentVersion else { throw .newerVersion }
        return file.projects
    }
}

extension LearnedTerms {
    /// Folds imported projects into the memory. Every rule is one that holds
    /// when the same file is imported twice, or a file goes A→B→A: counts
    /// take the max, never the sum; flags are OR'ed; sources are unioned.
    ///
    /// Import never confirms anything by itself. A term is confirmed by what
    /// the file says it earned — three dictations, a hand correction, a pin —
    /// read by the same `isConfirmed` as a local term; a term still being
    /// learned stays that way until dictation here confirms it. The file is
    /// trusted as the user's own: a pin already confirms any term in one
    /// click, so an edited file can do nothing a pin cannot.
    @discardableResult
    package mutating func merge(
        importing incoming: [LearnedTermProject],
        now: Date
    ) -> LearnedTermsExport.ImportSummary {
        // Name matching reads the memory as it was: two projects in the file
        // must not match each other by name. A repository's record matches
        // by its key alone.
        let localNames = Dictionary(
            grouping: projects.filter { !$0.isRepositoryRecord }, by: \.name
        ).mapValues(\.count)
        var imported: [(projectKey: String, term: String)] = []

        for project in incoming {
            let key = project.key.trimmed
            guard !key.isEmpty else { continue }
            let index = importTarget(for: project, key: key, localNames: localNames)
            projects[index].lastSeen = max(projects[index].lastSeen, project.lastSeen)
            // A checkout the file links to its repository (#971) keeps the
            // link, or its terms, already on the `repo:` record, would be
            // out of its reach. A link this memory already has stays.
            if let remote = project.projectRemote, !projects[index].isRepositoryRecord,
               projects[index].remote == nil
            {
                link(checkoutAt: index, to: remote)
            }
            // A linked checkout's terms and answer go to its repository's
            // record, as a dictation's do (`projectIndex`).
            var record = index
            if projects[index].isLinkedCheckout, let remote = projects[index].projectRemote {
                record = repositoryRecordIndex(for: remote, lastSeen: project.lastSeen)
            }
            projects[record].lastSeen = max(projects[record].lastSeen, project.lastSeen)
            projects[record].carryProposalStamp(from: project)
            for raw in project.terms {
                let term = LearnedTerms.sanitized(raw.term)
                guard !term.isEmpty else { continue }
                var clean = raw
                clean.term = term
                clean.dictations = max(0, raw.dictations)
                clean.applied = raw.applied.map { max(0, $0) }
                let match = term.caseFoldedForMatching
                if let existing = projects[record].terms.firstIndex(where: {
                    $0.term.caseFoldedForMatching == match
                }) {
                    projects[record].terms[existing] = LearnedTerms.merged(
                        projects[record].terms[existing], clean
                    )
                } else {
                    projects[record].terms.append(clean)
                }
                imported.append((projects[record].key, match))
            }
        }
        prune(now: now)

        var kept = Set<String>()
        var keptProjects = Set<String>()
        for entry in imported {
            // A linked checkout's terms are on its repository's record.
            guard let project = termRecord(entry.projectKey),
                  !kept.contains(project.key + "\n" + entry.term),
                  project.terms.contains(where: { $0.term.caseFoldedForMatching == entry.term })
            else { continue }
            kept.insert(project.key + "\n" + entry.term)
            keptProjects.insert(project.key)
        }
        return LearnedTermsExport.ImportSummary(terms: kept.count, projects: keptProjects.count)
    }

    /// Folds each project that `destination` sends to another key into that
    /// key's project, then drops the old key (#652: a worktree's bucket goes
    /// to its main checkout). Terms fold with the import rule, `merged`: two
    /// worktrees that each confirmed a spelling confirm it once, never twice.
    /// A project whose destination is nil or its own key stays. Running it
    /// again changes nothing. Returns how many projects were folded away.
    @discardableResult
    package mutating func fold(
        into destination: (LearnedTermProject) -> LearnedTermProjectIdentity?,
        now: Date
    ) -> Int {
        let moves: [(key: String, to: LearnedTermProjectIdentity)] = projects.compactMap { project in
            guard let target = destination(project), target.key != project.key else { return nil }
            return (project.key, target)
        }
        guard !moves.isEmpty else { return 0 }
        for move in moves {
            guard let sourceIndex = projects.firstIndex(where: { $0.key == move.key }) else { continue }
            let source = projects.remove(at: sourceIndex)
            let index: Int
            if let existing = projects.firstIndex(where: { $0.key == move.to.key }) {
                index = existing
                projects[index].lastSeen = max(projects[index].lastSeen, source.lastSeen)
            } else {
                projects.append(LearnedTermProject(
                    key: move.to.key, name: move.to.name, terms: [], lastSeen: source.lastSeen
                ))
                index = projects.count - 1
            }
            projects[index].carryProposalStamp(from: source)
            for term in source.terms {
                let match = term.term.caseFoldedForMatching
                if let existing = projects[index].terms.firstIndex(where: {
                    $0.term.caseFoldedForMatching == match
                }) {
                    projects[index].terms[existing] = LearnedTerms.merged(
                        projects[index].terms[existing], term
                    )
                } else {
                    projects[index].terms.append(term)
                }
            }
        }
        prune(now: now)
        return moves.count
    }

    /// Moves what worktrees learned under their own key, before #652 or
    /// through a hand fix keyed by the joined session's directory, into their
    /// main checkout's project. Reads each local key's `.git` entry, so it
    /// runs where the store loads its file, never on the commit path. Remote
    /// and shared keys are not paths and stay: a remote worktree's label says
    /// nothing about which repository it belongs to.
    @discardableResult
    package mutating func foldWorktreesIntoMainCheckouts(
        fileManager: FileManager = .default,
        now: Date
    ) -> Int {
        fold(into: { project in
            guard project.key.hasPrefix("/") else { return nil }
            let main = RepoIndexing.mainCheckout(ofRoot: project.key, fileManager: fileManager)
            guard main != project.key else { return nil }
            return LearnedTermProjectResolver.resolve(repositoryRoot: .root(main), workspace: nil)
        }, now: now)
    }

    /// The same key; else the one local project with the same name — the
    /// same checkout at another path on the new machine; else a new project
    /// under the file's key.
    private mutating func importTarget(
        for project: LearnedTermProject,
        key: String,
        localNames: [String: Int]
    ) -> Int {
        if let index = projects.firstIndex(where: { $0.key == key }) { return index }
        if project.isRepositoryRecord {
            // Made as a link makes it, remote included, so the checkouts
            // that point at it find it.
            if let remote = project.projectRemote, remote.key == key {
                return repositoryRecordIndex(for: remote, lastSeen: project.lastSeen)
            }
        } else if localNames[project.name] == 1,
                  let index = projects.firstIndex(where: { !$0.isRepositoryRecord && $0.name == project.name })
        {
            return index
        }
        projects.append(
            LearnedTermProject(key: key, name: project.name, terms: [], lastSeen: project.lastSeen)
        )
        return projects.count - 1
    }

    /// One spelling seen on two machines. The local spelling stays unless
    /// only the imported one was fixed by hand: a hand fix wins, as it does
    /// in `recordCorrection`. Two checkouts of one repository folding
    /// together (#971) pass `pinWins`: neither fixed, a pinned spelling is
    /// the user's choice and wins too.
    static func merged(_ local: LearnedTerm, _ imported: LearnedTerm, pinWins: Bool = false) -> LearnedTerm {
        let spelling: String
        if local.isConfirmedByCorrection != imported.isConfirmedByCorrection {
            spelling = imported.isConfirmedByCorrection ? imported.term : local.term
        } else if pinWins, local.isPinned != imported.isPinned {
            spelling = imported.isPinned ? imported.term : local.term
        } else {
            spelling = local.term
        }
        return LearnedTerm(
            term: spelling,
            sources: merging(local.sources, imported.sources),
            dictations: max(local.dictations, imported.dictations),
            firstSeen: min(local.firstSeen, imported.firstSeen),
            lastSeen: max(local.lastSeen, imported.lastSeen),
            confirmedByCorrection: local.isConfirmedByCorrection
                || imported.isConfirmedByCorrection ? true : nil,
            applied: local.applied == nil && imported.applied == nil
                ? nil : max(local.appliedCount, imported.appliedCount),
            lastApplied: [local.lastApplied, imported.lastApplied].compactMap { $0 }.max(),
            pinned: local.isPinned || imported.isPinned ? true : nil
        )
    }
}

extension LearnedTermProject {
    /// An agent's answer on either side is an answer: a project asked on one
    /// machine, or in one worktree, is not asked again after an import or a
    /// fold. A failed attempt carries only when neither side has an answer.
    /// The project's sentence (#891) is the newer answer's, and the prompt
    /// revision the newer of the two (#914).
    mutating func carryProposalStamp(from other: LearnedTermProject) {
        let revision = [answeredRevision, other.answeredRevision].compactMap { $0 }.max()
        proposedAt = [proposedAt, other.proposedAt].compactMap { $0 }.max()
        if let revision { proposalRevision = revision }
        proposalAttemptedAt = proposedAt == nil
            ? [proposalAttemptedAt, other.proposalAttemptedAt].compactMap { $0 }.max()
            : nil
        if let theirs = other.agentLineAt, theirs > (agentLineAt ?? .distantPast) {
            agentLine = other.agentLine
            agentLineAt = theirs
        }
    }
}
