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
package struct LearnedTerm: Codable, Equatable, Sendable {
    /// The canonical spelling, exactly as it was pre-applied.
    package var term: String
    /// `PolishContextSource` raw values that have proposed this spelling, in
    /// first-seen order.
    ///
    /// Provenance only. A remembered term stays in the vocabulary whatever the
    /// context toggles say later (owner ruling, 2026-09-20): once the speaker
    /// keeps saying a name, it is their vocabulary, the way a name typed into
    /// Names and terms is. The field is here so a future setting can drop
    /// what one source taught without dropping the rest.
    package var sources: [String]
    /// Distinct dictations that resolved it. The confirmation counter.
    package var dictations: Int
    package var firstSeen: Date
    package var lastSeen: Date
    /// The user fixed a dictation to this spelling themselves
    /// (`CorrectionLearning`). That is confirmation enough on its own: the
    /// three-dictation bar exists because polish can repeat a mistake, and a
    /// hand fix is not polish. Optional so files written before it decode;
    /// nil reads as false.
    package var confirmedByCorrection: Bool? = nil
    /// Dictations the memory itself rewrote with this spelling: the merged
    /// `.learned` entries, which exist only where no live source already
    /// had the term. What Settings shows to audit over-application (#522).
    /// Optional, like every field added after version 1; nil reads as 0.
    package var applied: Int? = nil
    package var lastApplied: Date? = nil
    /// The user asked to keep it: confirmed whatever the count, never
    /// decayed, and the last thing a cap evicts. Nil reads as false.
    package var pinned: Bool? = nil

    /// The provenance a hand correction records in `sources`.
    package init(
        term: String,
        sources: [String],
        dictations: Int,
        firstSeen: Date,
        lastSeen: Date,
        confirmedByCorrection: Bool? = nil,
        applied: Int? = nil,
        lastApplied: Date? = nil,
        pinned: Bool? = nil
    ) {
        self.term = term
        self.sources = sources
        self.dictations = dictations
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.confirmedByCorrection = confirmedByCorrection
        self.applied = applied
        self.lastApplied = lastApplied
        self.pinned = pinned
    }

    package static let correctionSource = "correction"

    package var isConfirmedByCorrection: Bool { confirmedByCorrection == true }
    package var isPinned: Bool { pinned == true }
    package var appliedCount: Int { applied ?? 0 }

    package func isConfirmed(minimumDictations: Int) -> Bool {
        isPinned || isConfirmedByCorrection || dictations >= minimumDictations
    }
}

/// One project's remembered terms. A project is a git root, a remote session's
/// workspace label, or the shared bucket for dictations that belong to no
/// project at all (`LearnedTermProjectResolver`).
package struct LearnedTermProject: Codable, Equatable, Sendable {
    /// Stable identity — see `LearnedTermProjectResolver.Identity`.
    package var key: String
    /// What the speaker would call it: a directory name, never a full path.
    package var name: String
    package var terms: [LearnedTerm]
    /// Last dictation attributed to this project; the eviction order.
    package var lastSeen: Date

    package init(key: String, name: String, terms: [LearnedTerm], lastSeen: Date) {
        self.key = key
        self.name = name
        self.terms = terms
        self.lastSeen = lastSeen
    }
}

/// A project's stable key and the name a human would recognize
/// (`LearnedTermProjectResolver.Identity`).
package struct LearnedTermProjectIdentity: Equatable, Sendable {
    package let key: String
    package let name: String

    package init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// One term a dictation resolved, as the commit path observed it.
package struct LearnedTermObservation: Equatable, Sendable {
    package let term: String
    package let source: PolishContextSource

    package init(term: String, source: PolishContextSource) {
        self.term = term
        self.source = source
    }
}

/// Everything remembered, as a value. Every rule — merging an observation,
/// the caps, the decay — lives here and nowhere else, so the tests exercise
/// them without a disk (`LearnedTermStore` is only the file around this).
package struct LearnedTerms: Codable, Equatable, Sendable {
    /// Bumped only for a change old builds cannot read. A file from the
    /// future is discarded rather than guessed at.
    package static let currentVersion = 1

    /// Dictations a term must have been resolved in before it grounds a later
    /// one. Three is the same bar the hosted suggestion pass asks its model
    /// for ("at least 3 different texts"): twice can be one mistake repeated,
    /// three times is a habit.
    package static let confirmedDictations = 3

    /// A project keeps this many terms. Far above the 80 of the hand-written
    /// list because this one is not read by a human — it is the pool the
    /// matcher indexes — and far below a repo index, which is what makes the
    /// remembered list worth having at all.
    package static let maxTermsPerProject = 200

    /// Projects kept, least-recently-dictated evicted first. Forty is more
    /// repos than anyone touches in a decay window; the cap exists so an
    /// agent walking a tree of checkouts cannot grow the file without bound.
    package static let maxProjects = 40

    /// A term not resolved again within this many days is forgotten. Speech
    /// vocabulary follows the work: a name from a project finished last
    /// quarter should stop competing with the current one's.
    package static let staleAfterDays = 90

    /// Longest spelling remembered. Matches `SpeakerTerms.maxTermCharacters`,
    /// since both feed the same prompt slot.
    package static let maxTermCharacters = 60

    package var version: Int = LearnedTerms.currentVersion
    package var projects: [LearnedTermProject] = []

    package init(version: Int = LearnedTerms.currentVersion, projects: [LearnedTermProject] = []) {
        self.version = version
        self.projects = projects
    }

    // MARK: Reading

    package var termCount: Int { projects.reduce(0) { $0 + $1.terms.count } }

    /// The confirmed spellings for one project, most-confirmed first. Ordering
    /// is what the caller's own cap cuts against, so it is total and
    /// deterministic: dictations, then recency, then the term itself.
    package func confirmedTerms(
        projectKey: String,
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [String] {
        confirmed(projectKey: projectKey, minimumDictations: minimumDictations).map(\.term)
    }

    package func confirmed(
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
    package func confirmedEverywhere(
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
                        || term.isConfirmedByCorrection ? true : nil,
                    applied: existing.applied == nil && term.applied == nil
                        ? nil : existing.appliedCount + term.appliedCount,
                    lastApplied: [existing.lastApplied, term.lastApplied].compactMap { $0 }.max(),
                    pinned: existing.isPinned || term.isPinned ? true : nil
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
    package mutating func record(
        _ observations: [LearnedTermObservation],
        project: LearnedTermProjectIdentity,
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
                if observation.fromMemory {
                    projects[index].terms[existing].applied =
                        projects[index].terms[existing].appliedCount + 1
                    projects[index].terms[existing].lastApplied = now
                }
            } else {
                projects[index].terms.append(
                    LearnedTerm(
                        term: observation.term,
                        sources: observation.sources,
                        dictations: 1,
                        firstSeen: now,
                        lastSeen: now,
                        applied: observation.fromMemory ? 1 : nil,
                        lastApplied: observation.fromMemory ? now : nil
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
    package mutating func recordCorrection(
        _ raw: String,
        project: LearnedTermProjectIdentity,
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

    /// Pins or unpins one spelling in one project. Returns false when the
    /// project does not hold it.
    @discardableResult
    package mutating func setPinned(_ pinned: Bool, term raw: String, projectKey: String) -> Bool {
        let key = LearnedTerms.sanitized(raw).caseFoldedForMatching
        guard !key.isEmpty,
              let index = projects.firstIndex(where: { $0.key == projectKey }),
              let termIndex = projects[index].terms.firstIndex(where: {
                  $0.term.caseFoldedForMatching == key
              })
        else { return false }
        projects[index].terms[termIndex].pinned = pinned ? true : nil
        return true
    }

    /// Drops one spelling from one project, whatever taught it. Undo and a
    /// revert both come here: the constraint is that the term is gone, not
    /// kept at a lower count where three more dictations would bring it back
    /// unnoticed.
    package mutating func forget(_ raw: String, projectKey: String) {
        let key = LearnedTerms.sanitized(raw).caseFoldedForMatching
        guard !key.isEmpty,
              let index = projects.firstIndex(where: { $0.key == projectKey })
        else { return }
        projects[index].terms.removeAll { $0.term.caseFoldedForMatching == key }
        projects.removeAll { $0.terms.isEmpty }
    }

    private mutating func projectIndex(
        for project: LearnedTermProjectIdentity,
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
    package mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(LearnedTerms.staleAfterDays) * 86_400)
        for index in projects.indices {
            projects[index].terms.removeAll { !$0.isPinned && $0.lastSeen < cutoff }
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
            // A project holding a pinned term is evicted last.
            projects = Array(
                projects
                    .sorted { lhs, rhs in
                        let lhsPinned = lhs.terms.contains(where: \.isPinned)
                        let rhsPinned = rhs.terms.contains(where: \.isPinned)
                        if lhsPinned != rhsPinned { return lhsPinned }
                        return lhs.lastSeen == rhs.lastSeen
                            ? lhs.key < rhs.key
                            : lhs.lastSeen > rhs.lastSeen
                    }
                    .prefix(LearnedTerms.maxProjects)
            )
        }
    }

    // MARK: Rules

    /// Total order, strongest evidence first: a pin, then a hand correction,
    /// then confirmations, then recency, then the spelling. Nothing here may
    /// depend on dictionary iteration order — the same memory must always
    /// render the same list.
    package static func isStrongerEvidence(_ lhs: LearnedTerm, _ rhs: LearnedTerm) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.isConfirmedByCorrection != rhs.isConfirmedByCorrection {
            return lhs.isConfirmedByCorrection
        }
        if lhs.dictations != rhs.dictations { return lhs.dictations > rhs.dictations }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
        return lhs.term < rhs.term
    }

    /// One entry per spelling, its sources unioned, in first-seen order, and
    /// whether the memory itself applied it. A spelling that survives
    /// sanitizing to nothing is dropped here rather than stored as an empty
    /// term.
    package static func folded(
        _ observations: [LearnedTermObservation]
    ) -> [(term: String, sources: [String], fromMemory: Bool)] {
        var order: [String] = []
        var sources: [String: [String]] = [:]
        var fromMemory = Set<String>()
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
            if observation.source == .learned { fromMemory.insert(key) }
        }
        return order.compactMap { key in
            guard let term = spelling[key] else { return nil }
            return (term: term, sources: sources[key] ?? [], fromMemory: fromMemory.contains(key))
        }
    }

    /// The same shape `SpeakerTerms` stores: one line, no quotes, no control
    /// characters, and short enough to belong in a prompt.
    package static func sanitized(_ raw: String) -> String {
        let term = RepoVocabularyMatcher.sanitizedTerm(raw)
            .collapsingInternalWhitespace
            .trimmed
        guard term.count <= maxTermCharacters else { return "" }
        return term
    }

    package static func merging(_ existing: [String], _ incoming: [String]) -> [String] {
        var result = existing
        for source in incoming where !result.contains(source) {
            result.append(source)
        }
        return result
    }
}
