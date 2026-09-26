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
        // must not match each other by name.
        let localNames = Dictionary(grouping: projects, by: \.name).mapValues(\.count)
        var imported: [(projectKey: String, term: String)] = []

        for project in incoming {
            let key = project.key.trimmed
            guard !key.isEmpty else { continue }
            let index = importTarget(for: project, key: key, localNames: localNames)
            projects[index].lastSeen = max(projects[index].lastSeen, project.lastSeen)
            for raw in project.terms {
                let term = LearnedTerms.sanitized(raw.term)
                guard !term.isEmpty else { continue }
                var clean = raw
                clean.term = term
                clean.dictations = max(0, raw.dictations)
                clean.applied = raw.applied.map { max(0, $0) }
                let match = term.caseFoldedForMatching
                if let existing = projects[index].terms.firstIndex(where: {
                    $0.term.caseFoldedForMatching == match
                }) {
                    projects[index].terms[existing] = LearnedTerms.merged(
                        projects[index].terms[existing], clean
                    )
                } else {
                    projects[index].terms.append(clean)
                }
                imported.append((projects[index].key, match))
            }
        }
        prune(now: now)

        var kept = Set<String>()
        var keptProjects = Set<String>()
        for entry in imported where !kept.contains(entry.projectKey + "\n" + entry.term) {
            guard let project = projects.first(where: { $0.key == entry.projectKey }),
                  project.terms.contains(where: { $0.term.caseFoldedForMatching == entry.term })
            else { continue }
            kept.insert(entry.projectKey + "\n" + entry.term)
            keptProjects.insert(entry.projectKey)
        }
        return LearnedTermsExport.ImportSummary(terms: kept.count, projects: keptProjects.count)
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
        if localNames[project.name] == 1,
           let index = projects.firstIndex(where: { $0.name == project.name })
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
    /// in `recordCorrection`.
    static func merged(_ local: LearnedTerm, _ imported: LearnedTerm) -> LearnedTerm {
        let spelling = imported.isConfirmedByCorrection && !local.isConfirmedByCorrection
            ? imported.term : local.term
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
