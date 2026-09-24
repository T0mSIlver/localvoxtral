import Foundation

/// A spelling the polish pipeline has already resolved out of this speaker's
/// own words, kept so a later dictation in the same project gets it right even
/// when nothing on screen mentions it that time.
///
/// Only spellings that CORRECTED a heard span are remembered — the entries
/// `PolishContextGrounding` pre-applied, never the terms a source merely
/// harvested. That is the whole reason a remembered list stays small enough to
/// be worth sending: it holds the terms the recognizer demonstrably gets
/// wrong, not an index of everything in the repo.
struct LearnedTerm: Codable, Equatable, Sendable {
    /// The canonical spelling, exactly as it was pre-applied.
    var term: String
    /// `PolishContextSource` raw values that have proposed this spelling, in
    /// first-seen order.
    ///
    /// Provenance only. A remembered term stays in the vocabulary whatever the
    /// context toggles say later (owner ruling, 2026-09-20): once the speaker
    /// keeps saying a name, it is their vocabulary, the way a name typed into
    /// Names and terms is. The field is here so a future setting can drop
    /// what one source taught without dropping the rest.
    var sources: [String]
    /// Distinct dictations that resolved it. The confirmation counter.
    var dictations: Int
    var firstSeen: Date
    var lastSeen: Date
    /// The user fixed a dictation to this spelling themselves
    /// (`CorrectionLearning`). That is confirmation enough on its own: the
    /// three-dictation bar exists because polish can repeat a mistake, and a
    /// hand fix is not polish. Optional so files written before it decode;
    /// nil reads as false.
    var confirmedByCorrection: Bool? = nil

    /// The provenance a hand correction records in `sources`.
    static let correctionSource = "correction"

    var isConfirmedByCorrection: Bool { confirmedByCorrection == true }

    func isConfirmed(minimumDictations: Int) -> Bool {
        isConfirmedByCorrection || dictations >= minimumDictations
    }
}

/// One project's remembered terms. A project is a git root, a remote session's
/// workspace label, or the shared bucket for dictations that belong to no
/// project at all (`LearnedTermProjectResolver`).
struct LearnedTermProject: Codable, Equatable, Sendable {
    /// Stable identity — see `LearnedTermProjectResolver.Identity`.
    var key: String
    /// What the speaker would call it: a directory name, never a full path.
    var name: String
    var terms: [LearnedTerm]
    /// Last dictation attributed to this project; the eviction order.
    var lastSeen: Date
}

/// One term a dictation resolved, as the commit path observed it.
struct LearnedTermObservation: Equatable, Sendable {
    let term: String
    let source: PolishContextSource
}

/// Everything remembered, as a value. Every rule — merging an observation,
/// the caps, the decay — lives here and nowhere else, so the tests exercise
/// them without a disk (`LearnedTermStore` is only the file around this).
struct LearnedTerms: Codable, Equatable, Sendable {
    /// Bumped only for a change old builds cannot read. A file from the
    /// future is discarded rather than guessed at.
    static let currentVersion = 1

    /// Dictations a term must have been resolved in before it grounds a later
    /// one. Three is the same bar the hosted suggestion pass asks its model
    /// for ("at least 3 different texts"): twice can be one mistake repeated,
    /// three times is a habit.
    static let confirmedDictations = 3

    /// A project keeps this many terms. Far above the 80 of the hand-written
    /// list because this one is not read by a human — it is the pool the
    /// matcher indexes — and far below a repo index, which is what makes the
    /// remembered list worth having at all.
    static let maxTermsPerProject = 200

    /// Projects kept, least-recently-dictated evicted first. Forty is more
    /// repos than anyone touches in a decay window; the cap exists so an
    /// agent walking a tree of checkouts cannot grow the file without bound.
    static let maxProjects = 40

    /// A term not resolved again within this many days is forgotten. Speech
    /// vocabulary follows the work: a name from a project finished last
    /// quarter should stop competing with the current one's.
    static let staleAfterDays = 90

    /// Longest spelling remembered. Matches `SpeakerTerms.maxTermCharacters`,
    /// since both feed the same prompt slot.
    static let maxTermCharacters = 60

    var version: Int = LearnedTerms.currentVersion
    var projects: [LearnedTermProject] = []

    init(version: Int = LearnedTerms.currentVersion, projects: [LearnedTermProject] = []) {
        self.version = version
        self.projects = projects
    }

    // MARK: Reading

    var termCount: Int { projects.reduce(0) { $0 + $1.terms.count } }

    /// The confirmed spellings for one project, most-confirmed first. Ordering
    /// is what the caller's own cap cuts against, so it is total and
    /// deterministic: dictations, then recency, then the term itself.
    func confirmedTerms(
        projectKey: String,
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [String] {
        confirmed(projectKey: projectKey, minimumDictations: minimumDictations).map(\.term)
    }

    func confirmed(
        projectKey: String,
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [LearnedTerm] {
        guard let project = projects.first(where: { $0.key == projectKey }) else { return [] }
        return project.terms
            .filter { $0.isConfirmed(minimumDictations: minimumDictations) }
            .sorted(by: LearnedTerms.isStrongerEvidence)
    }

    /// Strongest evidence first across EVERY project: what the Settings pane
    /// offers for the hand-written list, which is global.
    func confirmedEverywhere(
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [LearnedTerm] {
        var strongest: [String: LearnedTerm] = [:]
        for project in projects {
            for term in project.terms where term.isConfirmed(minimumDictations: minimumDictations) {
                let key = term.term.caseFoldedForMatching
                guard let existing = strongest[key] else {
                    strongest[key] = term
                    continue
                }
                // One name said in two projects is one name: keep the earlier
                // first sight and the later last sight, and add the counts —
                // otherwise a term the speaker uses everywhere would rank
                // below one they use in a single repo.
                strongest[key] = LearnedTerm(
                    term: existing.term,
                    sources: LearnedTerms.merging(existing.sources, term.sources),
                    dictations: existing.dictations + term.dictations,
                    firstSeen: min(existing.firstSeen, term.firstSeen),
                    lastSeen: max(existing.lastSeen, term.lastSeen),
                    confirmedByCorrection: existing.isConfirmedByCorrection
                        || term.isConfirmedByCorrection ? true : nil
                )
            }
        }
        return strongest.values.sorted(by: LearnedTerms.isStrongerEvidence)
    }

    // MARK: Writing

    /// Folds one dictation's resolved terms into the project's memory.
    ///
    /// One call per dictation, whatever the observations: a term resolved from
    /// three sources in the same sentence is one confirmation, not three — the
    /// counter has to mean "distinct dictations" for `confirmedDictations` to
    /// mean what it says.
    mutating func record(
        _ observations: [LearnedTermObservation],
        project: LearnedTermProjectResolver.Identity,
        now: Date
    ) {
        let folded = LearnedTerms.folded(observations)
        guard !folded.isEmpty else { return }

        var index = projects.firstIndex { $0.key == project.key }
        if index == nil {
            projects.append(
                LearnedTermProject(key: project.key, name: project.name, terms: [], lastSeen: now)
            )
            index = projects.count - 1
        }
        guard let index else { return }
        projects[index].name = project.name
        projects[index].lastSeen = now

        for observation in folded {
            if let existing = projects[index].terms.firstIndex(where: {
                $0.term.caseFoldedForMatching == observation.term.caseFoldedForMatching
            }) {
                projects[index].terms[existing].dictations += 1
                projects[index].terms[existing].lastSeen = now
                projects[index].terms[existing].sources = LearnedTerms.merging(
                    projects[index].terms[existing].sources, observation.sources
                )
            } else {
                projects[index].terms.append(
                    LearnedTerm(
                        term: observation.term,
                        sources: observation.sources,
                        dictations: 1,
                        firstSeen: now,
                        lastSeen: now
                    )
                )
            }
        }
        prune(now: now)
    }

    /// The user fixed a dictation in this project to `term` by hand. The term
    /// is confirmed at once and counts one more dictation. Returns false when
    /// there was nothing new to tell the user: the spelling was already
    /// confirmed by an earlier correction, or it sanitizes to nothing.
    @discardableResult
    mutating func recordCorrection(
        _ raw: String,
        project: LearnedTermProjectResolver.Identity,
        now: Date
    ) -> Bool {
        let term = LearnedTerms.sanitized(raw)
        guard !term.isEmpty else { return false }
        let index = projectIndex(for: project, now: now)
        var isNew = true
        if let existing = projects[index].terms.firstIndex(where: {
            $0.term.caseFoldedForMatching == term.caseFoldedForMatching
        }) {
            isNew = !projects[index].terms[existing].isConfirmedByCorrection
            // The user's spelling wins over the one polish settled on.
            projects[index].terms[existing].term = term
            projects[index].terms[existing].dictations += 1
            projects[index].terms[existing].lastSeen = now
            projects[index].terms[existing].confirmedByCorrection = true
            projects[index].terms[existing].sources = LearnedTerms.merging(
                projects[index].terms[existing].sources, [LearnedTerm.correctionSource]
            )
        } else {
            projects[index].terms.append(
                LearnedTerm(
                    term: term,
                    sources: [LearnedTerm.correctionSource],
                    dictations: 1,
                    firstSeen: now,
                    lastSeen: now,
                    confirmedByCorrection: true
                )
            )
        }
        prune(now: now)
        return isNew
    }

    /// Drops one spelling from one project, whatever taught it. Undo and a
    /// revert both come here: the constraint is that the term is gone, not
    /// kept at a lower count where three more dictations would bring it back
    /// unnoticed.
    mutating func forget(_ raw: String, projectKey: String) {
        let key = LearnedTerms.sanitized(raw).caseFoldedForMatching
        guard !key.isEmpty,
              let index = projects.firstIndex(where: { $0.key == projectKey })
        else { return }
        projects[index].terms.removeAll { $0.term.caseFoldedForMatching == key }
        projects.removeAll { $0.terms.isEmpty }
    }

    private mutating func projectIndex(
        for project: LearnedTermProjectResolver.Identity,
        now: Date
    ) -> Int {
        if let index = projects.firstIndex(where: { $0.key == project.key }) {
            projects[index].name = project.name
            projects[index].lastSeen = now
            return index
        }
        projects.append(
            LearnedTermProject(key: project.key, name: project.name, terms: [], lastSeen: now)
        )
        return projects.count - 1
    }

    /// Decay and caps, applied after every write and after every load: a file
    /// that has sat on disk for a season must not come back larger than the
    /// caps allow just because nothing has been dictated since.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(LearnedTerms.staleAfterDays) * 86_400)
        for index in projects.indices {
            projects[index].terms.removeAll { $0.lastSeen < cutoff }
            if projects[index].terms.count > LearnedTerms.maxTermsPerProject {
                projects[index].terms = Array(
                    projects[index].terms
                        .sorted(by: LearnedTerms.isStrongerEvidence)
                        .prefix(LearnedTerms.maxTermsPerProject)
                )
            }
        }
        projects.removeAll { $0.terms.isEmpty }
        if projects.count > LearnedTerms.maxProjects {
            projects = Array(
                projects
                    .sorted { lhs, rhs in
                        lhs.lastSeen == rhs.lastSeen
                            ? lhs.key < rhs.key
                            : lhs.lastSeen > rhs.lastSeen
                    }
                    .prefix(LearnedTerms.maxProjects)
            )
        }
    }

    // MARK: Rules

    /// Total order, strongest evidence first: a hand correction, then
    /// confirmations, then recency, then the spelling. Nothing here may
    /// depend on dictionary iteration order — the same memory must always
    /// render the same list.
    static func isStrongerEvidence(_ lhs: LearnedTerm, _ rhs: LearnedTerm) -> Bool {
        if lhs.isConfirmedByCorrection != rhs.isConfirmedByCorrection {
            return lhs.isConfirmedByCorrection
        }
        if lhs.dictations != rhs.dictations { return lhs.dictations > rhs.dictations }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
        return lhs.term < rhs.term
    }

    /// One entry per spelling, its sources unioned, in first-seen order.
    /// A spelling that survives sanitizing to nothing is dropped here rather
    /// than stored as an empty term.
    static func folded(
        _ observations: [LearnedTermObservation]
    ) -> [(term: String, sources: [String])] {
        var order: [String] = []
        var sources: [String: [String]] = [:]
        var spelling: [String: String] = [:]
        for observation in observations {
            let term = sanitized(observation.term)
            guard !term.isEmpty else { continue }
            let key = term.caseFoldedForMatching
            if spelling[key] == nil {
                spelling[key] = term
                order.append(key)
            }
            // A match against the memory itself is a sighting, not a new
            // provenance: it refreshes the counters without claiming the
            // memory as the place the spelling came from.
            sources[key] = merging(
                sources[key] ?? [],
                observation.source == .learned ? [] : [observation.source.rawValue]
            )
        }
        return order.compactMap { key in
            guard let term = spelling[key] else { return nil }
            return (term: term, sources: sources[key] ?? [])
        }
    }

    /// The same shape `SpeakerTerms` stores: one line, no quotes, no control
    /// characters, and short enough to belong in a prompt.
    static func sanitized(_ raw: String) -> String {
        let term = RepoVocabularyMatcher.sanitizedTerm(raw)
            .collapsingInternalWhitespace
            .trimmed
        guard term.count <= maxTermCharacters else { return "" }
        return term
    }

    static func merging(_ existing: [String], _ incoming: [String]) -> [String] {
        var result = existing
        for source in incoming where !result.contains(source) {
            result.append(source)
        }
        return result
    }
}
