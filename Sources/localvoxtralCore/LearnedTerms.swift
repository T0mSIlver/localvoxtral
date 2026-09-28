import Foundation

/// A spelling kept for one project, so a later dictation there gets it right
/// even when nothing on screen mentions it that time.
///
/// Three things add one. The polish pipeline, when a spelling CORRECTED a
/// heard span: the entries `PolishContextGrounding` pre-applied, never the
/// terms a source merely harvested. The user, fixing a dictation by hand
/// (`recordCorrection`). And the project's coding agent, which proposes the
/// project's names once (`recordProposal`, #609): a proposal starts at zero
/// dictations and is a suggestion until use or a pin confirms it. The list
/// stays small enough to be worth sending because nothing below the bar is
/// sent: it holds the terms the recognizer demonstrably gets wrong, not an
/// index of everything in the repo.
package struct LearnedTerm: Codable, Equatable, Sendable {
    /// The canonical spelling, exactly as it was pre-applied.
    package var term: String
    /// What taught this spelling, in first-seen order: `PolishContextSource`
    /// raw values, `correction`, or `agent:<name>` for a coding agent's
    /// proposal.
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
    /// `agent:claude`, `agent:vibe`, `agent:opencode`: the coding agent that
    /// proposed the term
    /// (`ProjectTermProposal.Agent.source`).
    package static let agentSourcePrefix = "agent:"

    package var isConfirmedByCorrection: Bool { confirmedByCorrection == true }
    package var isPinned: Bool { pinned == true }
    package var appliedCount: Int { applied ?? 0 }

    package func isConfirmed(minimumDictations: Int) -> Bool {
        isPinned || isConfirmedByCorrection || dictations >= minimumDictations
    }

    /// The agent that proposed this term, if one did.
    package var proposingAgent: ProjectTermProposal.Agent? {
        sources.lazy.compactMap { source -> ProjectTermProposal.Agent? in
            guard source.hasPrefix(LearnedTerm.agentSourcePrefix) else { return nil }
            return ProjectTermProposal.Agent(rawValue: String(source.dropFirst(LearnedTerm.agentSourcePrefix.count)))
        }.first
    }

    /// The name after `agent:` in the first agent source: a headless run's
    /// agent, or the caller of `localvoxtral terms propose` (#721), which may
    /// be an agent that has no headless run (`AgentCLICaller`).
    package var proposerName: String? {
        sources.first { $0.hasPrefix(LearnedTerm.agentSourcePrefix) }
            .map { String($0.dropFirst(LearnedTerm.agentSourcePrefix.count)) }
    }

    /// Who proposed it, as Settings names them.
    package var proposerDisplayName: String? {
        if let proposingAgent { return proposingAgent.displayName }
        switch proposerName {
        case nil: return nil
        case "codex": return "Codex"
        case "opencode": return "opencode"
        default: return "a coding agent"
        }
    }

    /// An agent proposed it and neither use nor a pin has confirmed it yet.
    package var isUnconfirmedProposal: Bool {
        proposerName != nil && !isConfirmed(minimumDictations: LearnedTerms.confirmedDictations)
    }

    /// Only agents taught it, and the user has not used, pinned or corrected
    /// to it: dropping it loses nothing they did.
    var isUntouchedProposal: Bool {
        !sources.isEmpty && sources.allSatisfy { $0.hasPrefix(LearnedTerm.agentSourcePrefix) }
            && dictations == 0 && !isPinned && !isConfirmedByCorrection
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
    /// When the project's coding agent answered the terms request (#609).
    /// Set, the project is never asked again, even when the answer was empty.
    /// Optional like every field added after version 1.
    package var proposedAt: Date? = nil
    /// When a terms request last failed (timeout, not logged in, budget). The
    /// next joined dictation asks again once `ProjectTermProposal.retryAfter`
    /// has passed.
    package var proposalAttemptedAt: Date? = nil
    /// A remote project's README summary, as its host reported it (#745),
    /// for quick capture's router. A local checkout's is read from disk.
    package var summary: String? = nil
    /// When the host last reported it, a README with no prose included.
    package var summaryAt: Date? = nil
    /// When a hook from a remote session last named this project (#819).
    /// Nil for a project no hook has named since, like a pre-#652 worktree
    /// label no session will report again.
    package var reportedAt: Date? = nil
    /// True once a host named it through `X-Lvx-Env-Project`: the name of a
    /// repository, not of the directory a session happened to run in.
    package var reportedAsRepository: Bool? = nil
    /// The project's agent's one sentence about it (#891), asked with its
    /// terms: what the project is and what it has. Quick capture's router
    /// reads it when the user wrote no line.
    package var agentLine: String? = nil
    /// When an answer to the prompt that asks for that sentence landed,
    /// with or without one. Nil on a project answered before #891, which
    /// is asked once more.
    package var agentLineAt: Date? = nil
    /// The `ProjectTermProposal.promptRevision` the last answer was asked
    /// with. Nil on an answer from before the field: see `answeredRevision`.
    package var proposalRevision: Int? = nil
    /// The project's GitHub repository, `owner/name` (#926): its `origin`,
    /// read on the Mac for a local checkout and sent by the host's shim as
    /// `X-Lvx-Env-Repository` for a remote one, else the user's answer when
    /// the Inbox asked (`repositoryTyped`). A host's value is a label like
    /// its project name: only ever a `gh --repo` argument.
    package var repository: String? = nil
    /// The user typed `repository` because the project had no GitHub
    /// `origin`. An `origin` read later replaces it; a missing one does not.
    package var repositoryTyped: Bool? = nil
    /// What GitHub says about `repository`, for quick capture's router.
    package var github: GitHubRepositoryFacts? = nil
    /// When `github` was fetched; asked again after `githubRefreshDays`.
    package var githubAt: Date? = nil
    /// The user files this fork's issues in its upstream (GitHub's
    /// `parent`), not in the fork. Nil until the user picks; it files in
    /// the fork meanwhile.
    package var filesUpstream: Bool? = nil
    /// The enrolled hosts (`ClaudeRemoteHost.id`) whose hooks named this
    /// remote project, so the Projects pane can say where it is checked
    /// out. Nil on a local project and on one no hook named since.
    package var hostIDs: [String]? = nil
    /// The repository this checkout's `origin` names, `host/owner/repo`
    /// (`ProjectRemote`, #971). Set, the checkout holds no terms: they live
    /// on the repository's record (`repo:<remote>`), which every checkout
    /// of it shares. The repository's record carries it too.
    package var remote: String? = nil

    package init(
        key: String,
        name: String,
        terms: [LearnedTerm],
        lastSeen: Date,
        proposedAt: Date? = nil,
        proposalAttemptedAt: Date? = nil
    ) {
        self.key = key
        self.name = name
        self.terms = terms
        self.lastSeen = lastSeen
        self.proposedAt = proposedAt
        self.proposalAttemptedAt = proposalAttemptedAt
    }

    /// Where File sends this project's issues: the fork's upstream when the
    /// user chose it and GitHub named one, else `repository`.
    package var issueRepository: String? {
        if filesUpstream == true, let parent = github?.parent { return parent }
        return repository
    }

    /// A project kept for its stamp alone: an agent answered with nothing
    /// new, or failed, and emptying it would ask again.
    package var hasProposalStamp: Bool { proposedAt != nil || proposalAttemptedAt != nil }

    /// The prompt revision the project's answer came from, nil when it has
    /// none. An answer older than `proposalRevision` is revision 2 when it
    /// carried the sentence (#891), else 1.
    package var answeredRevision: Int? {
        guard proposedAt != nil else { return nil }
        return proposalRevision ?? (agentLineAt != nil ? 2 : 1)
    }

    /// Kept with no terms: a proposal stamp, or a hook that named it. A
    /// project holding neither is dropped once its last term goes.
    var isKeptWithoutTerms: Bool { hasProposalStamp || reportedAt != nil || isLinkedCheckout }

    /// The user made a choice here: a pinned term, a typed repository, the
    /// fork's filing choice. The caps never evict it (#989).
    package var isExplicit: Bool {
        terms.contains(where: \.isPinned) || repositoryTyped == true || filesUpstream != nil
    }

    /// A checkout whose terms live on its repository's record.
    package var isLinkedCheckout: Bool { !isRepositoryRecord && repositoryRecordKey != nil }
}

/// A repository's description and topics as GitHub reports them
/// (`gh api repos/<owner>/<name>`, #926), and the repository it was forked
/// from.
package struct GitHubRepositoryFacts: Codable, Equatable, Sendable {
    package var description: String?
    package var topics: [String]
    /// `owner/name` of the repository this one is a fork of.
    package var parent: String?

    package init(description: String?, topics: [String], parent: String?) {
        self.description = description
        self.topics = topics
        self.parent = parent
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
    /// A remote README summary is asked for again after this long.
    package static let summaryRefreshDays = 7
    /// GitHub's description and topics are fetched again after this long,
    /// or when the Projects pane opens.
    package static let githubRefreshDays = 7

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
        guard let project = termRecord(projectKey) else { return [] }
        return project.terms
            .filter { $0.isConfirmed(minimumDictations: minimumDictations) }
            .sorted(by: LearnedTerms.isStrongerEvidence)
    }

    /// The project's agent proposals no use has confirmed yet, strongest
    /// evidence first. They take part in matching only where repo vocabulary
    /// may (`LearnedTermGrounding`), and never in `confirmed`.
    package func unconfirmedProposals(projectKey: String) -> [String] {
        guard let project = termRecord(projectKey) else { return [] }
        return project.terms
            .filter(\.isUnconfirmedProposal)
            .sorted(by: LearnedTerms.isStrongerEvidence)
            .map(\.term)
    }

    /// Whether a remote project's host should be asked for its README
    /// (#745): a project a dictation has shown the app, with no report or
    /// one older than `LearnedTerms.summaryRefreshDays`.
    package func needsSummary(projectKey: String, now: Date) -> Bool {
        guard projectKey.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix),
              let project = projects.first(where: { $0.key == projectKey })
        else { return false }
        guard let reported = project.summaryAt else { return true }
        return now.timeIntervalSince(reported) >= Double(LearnedTerms.summaryRefreshDays) * 86_400
    }

    /// Keeps a host's README summary on an existing project; nil records a
    /// README with no prose. Returns false when the project is gone.
    @discardableResult
    package mutating func recordSummary(_ summary: String?, projectKey: String, now: Date) -> Bool {
        guard let index = projects.firstIndex(where: { $0.key == projectKey }) else { return false }
        projects[index].summary = summary
        projects[index].summaryAt = now
        return true
    }

    /// A hook from a remote session named `project` (#819). A repository's
    /// name adds the project when it is missing, so quick capture lists
    /// every repository a session runs in, learned terms or not. A cwd label
    /// only stamps a project a dictation already added: every worktree has
    /// its own label, and none of them is a project. Returns true when it
    /// added the project.
    /// `repository` is the host's `origin` (`X-Lvx-Env-Repository`: GitHub's
    /// `owner/name`, or `host/path` elsewhere), kept only with a repository's
    /// name. It links the project to that repository's record (#971).
    @discardableResult
    package mutating func recordRemoteReport(
        project: LearnedTermProjectIdentity,
        asRepository: Bool,
        repository: String? = nil,
        hostID: String? = nil,
        now: Date
    ) -> Bool {
        guard project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) else { return false }
        let added = !projects.contains { $0.key == project.key }
        let index: Int
        if let existing = projects.firstIndex(where: { $0.key == project.key }) {
            index = existing
        } else {
            guard asRepository else { return false }
            projects.append(LearnedTermProject(key: project.key, name: project.name, terms: [], lastSeen: now))
            index = projects.count - 1
        }
        projects[index].reportedAt = now
        if let hostID, !(projects[index].hostIDs ?? []).contains(hostID) {
            projects[index].hostIDs = (projects[index].hostIDs ?? []) + [hostID]
        }
        if asRepository {
            projects[index].reportedAsRepository = true
            if let remote = repository.flatMap(ProjectRemote.init(header:)) {
                if let github = remote.githubRepository { setOriginRepository(github, at: index) }
                link(checkoutAt: index, to: remote)
            }
        }
        prune(now: now)
        return added
    }

    /// A local checkout's `origin` names `repository`. Returns false when
    /// the project is gone or the value is no `owner/name`.
    @discardableResult
    package mutating func recordOriginRepository(_ repository: String, projectKey: String) -> Bool {
        guard let index = projects.firstIndex(where: { $0.key == projectKey }),
              setOriginRepository(repository, at: index),
              let remote = ProjectRemote(githubRepository: repository)
        else { return false }
        link(checkoutAt: index, to: remote)
        return true
    }

    @discardableResult
    private mutating func setOriginRepository(_ repository: String, at index: Int) -> Bool {
        guard QuickCaptureInbox.isRepository(repository) else { return false }
        if projects[index].repository != repository {
            projects[index].repository = repository
            projects[index].github = nil
            projects[index].githubAt = nil
            projects[index].filesUpstream = nil
        }
        projects[index].repositoryTyped = nil
        return true
    }

    /// The user answered the Inbox's `owner/name` for a project with no
    /// GitHub `origin`; kept so the next capture there does not ask. An
    /// `origin` the project already has wins. Returns whether it was kept.
    @discardableResult
    package mutating func recordTypedRepository(_ repository: String, projectKey: String) -> Bool {
        guard QuickCaptureInbox.isRepository(repository),
              let index = projects.firstIndex(where: { $0.key == projectKey }),
              projects[index].repository == nil || projects[index].repositoryTyped == true,
              // Like a pin, a typed repository keeps the project past the cap.
              projects[index].isExplicit || projects.filter(\.isExplicit).count < LearnedTerms.maxProjects
        else { return false }
        if projects[index].repository != repository {
            projects[index].github = nil
            projects[index].githubAt = nil
            projects[index].filesUpstream = nil
        }
        projects[index].repository = repository
        projects[index].repositoryTyped = true
        return true
    }

    /// GitHub answered for `repository`. Kept on every project that still
    /// names it: a checkout on the Mac and one on a host share one answer.
    package mutating func recordGitHub(_ facts: GitHubRepositoryFacts, repository: String, now: Date) {
        for index in projects.indices where projects[index].repository == repository {
            projects[index].github = facts
            projects[index].githubAt = now
        }
    }

    /// The "File issues here" choice, on every project that names
    /// `repository`. Kept either way: a fork with no choice yet is one the
    /// Projects pane asks about.
    package mutating func setFilesUpstream(_ upstream: Bool, repository: String) {
        for index in projects.indices where projects[index].repository == repository {
            projects[index].filesUpstream = upstream
        }
    }

    /// The repositories a listed project names whose GitHub facts are
    /// missing or older than `githubRefreshDays`, or all of them with
    /// `force`. Each once.
    package func repositoriesNeedingGitHub(now: Date, force: Bool = false) -> [String] {
        var seen = Set<String>()
        return listedProjects(now: now).compactMap { project -> String? in
            guard let repository = project.repository, seen.insert(repository).inserted else { return nil }
            if force { return repository }
            guard let fetched = project.githubAt else { return repository }
            return now.timeIntervalSince(fetched) >= Double(Self.githubRefreshDays) * 86_400 ? repository : nil
        }
    }

    /// Whether a joined dictation in this project should ask its agent:
    /// never answered, or answered with an older prompt revision than
    /// `revision`, the one this ask would carry (#891, #914). A failed
    /// attempt waits `ProjectTermProposal.retryAfter`.
    /// A remote working-directory name is listed this long after a hook
    /// last named it. Only a host older than plugin 1.13.0 (#652) sends one
    /// for a session in a repository, and there each worktree has its own:
    /// listed while its sessions run, gone a week after.
    package static let remoteLabelListedDays = 7

    /// The checkouts, most recent first (#891; `listedProjects` groups them
    /// by repository, #971). A local main
    /// checkout; a remote project a hook named as a repository, or whose
    /// host sent its README in the last 90 days (only a 1.17.0 shim does,
    /// and it names the repository); an old shim's working-directory name within
    /// `remoteLabelListedDays` of its last hook (#819). A remote name no
    /// hook has named, such as a worktree's from before #652, is no project,
    /// and neither is the shared bucket; their terms still apply.
    package func listedCheckouts(now: Date) -> [LearnedTermProject] {
        func recency(_ project: LearnedTermProject) -> Date {
            max(project.lastSeen, project.reportedAt ?? project.lastSeen)
        }
        return projects
            .filter { !$0.key.isEmpty && !$0.name.isEmpty && Self.isListed($0, now: now) }
            .sorted { recency($0) != recency($1) ? recency($0) > recency($1) : $0.key < $1.key }
    }

    private static func isListed(_ project: LearnedTermProject, now: Date) -> Bool {
        if project.key.hasPrefix("/") { return true }
        guard project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) else { return false }
        if project.reportedAsRepository == true { return true }
        if let summaryAt = project.summaryAt,
           now.timeIntervalSince(summaryAt) < Double(staleAfterDays) * 86_400
        {
            return true
        }
        guard let reported = project.reportedAt else { return false }
        return now.timeIntervalSince(reported) < Double(remoteLabelListedDays) * 86_400
    }

    package func needsProposal(projectKey: String, now: Date, revision: Int = 1) -> Bool {
        guard let project = termRecord(projectKey) else { return true }
        if let answered = project.answeredRevision, answered >= revision { return false }
        guard let attempted = project.proposalAttemptedAt else { return true }
        return now.timeIntervalSince(attempted) >= ProjectTermProposal.retryAfter
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

        let index = projectIndex(for: project, now: now)
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

    /// The project's agent answered (#609). Its term-shaped answers join the
    /// project unconfirmed, with the agent as their source and zero
    /// dictations: they sort below every term use has earned, so a cap
    /// evicts them first, and they decay like any unpinned term. A term the
    /// project already holds, in any state, or one in `excluding` (the
    /// user's own list and the suggestions they refused) is dropped. The
    /// project is stamped even when nothing is added, so it is not asked
    /// again. `line` is the answer's sentence (#891), empty when the prompt
    /// asked for one and none came, nil when the answer is from a runner
    /// that did not ask. `revision` is the prompt revision the answer was
    /// asked with, nil when the caller does not know it. An answer from a
    /// newer revision replaces the older answer's terms that nothing has
    /// confirmed or used since (#914). Returns how many terms were added.
    @discardableResult
    package mutating func recordProposal(
        _ raw: [String],
        line: String? = nil,
        revision: Int? = nil,
        agent: ProjectTermProposal.Agent,
        project: LearnedTermProjectIdentity,
        excluding: [String] = [],
        now: Date
    ) -> Int {
        let index = projectIndex(for: project, now: now)
        let previousRevision = projects[index].answeredRevision
        if let revision, let answered = previousRevision, answered < revision,
           let answeredAt = projects[index].proposedAt
        {
            projects[index].terms.removeAll { $0.isUntouchedProposal && $0.firstSeen == answeredAt }
        }
        var known = Set(projects[index].terms.map(\.term.caseFoldedForMatching))
        known.formUnion(excluding.map(\.caseFoldedForMatching))
        var added = 0
        for term in ProjectTermProposal.acceptedTerms(raw) where known.insert(term.caseFoldedForMatching).inserted {
            projects[index].terms.append(
                LearnedTerm(term: term, sources: [agent.source], dictations: 0, firstSeen: now, lastSeen: now)
            )
            added += 1
        }
        projects[index].proposedAt = now
        projects[index].proposalAttemptedAt = nil
        // A late answer from an older runner never lowers the revision, or
        // every newer runner would ask again.
        if let revision { projects[index].proposalRevision = max(revision, previousRevision ?? revision) }
        if let line {
            projects[index].agentLine = ProjectTermProposal.acceptedLine(line)
            projects[index].agentLineAt = now
        }
        prune(now: now)
        return added
    }

    /// Terms a coding agent proposed through `localvoxtral terms propose`
    /// (#721). They join unconfirmed, exactly as `recordProposal`'s do, with
    /// `agent:<proposer>` as their source. Unlike that answer, a proposal from
    /// the command does not stamp the project: it is a few names an agent
    /// just met, not the project's list, so the headless run still asks once.
    /// `terms` must already be term-shaped (`ProjectTermProposal.acceptedTerms`);
    /// a term the project holds or `excluding` names is dropped. Returns the
    /// terms added.
    @discardableResult
    package mutating func recordCommandProposal(
        _ terms: [String],
        proposer: String,
        project: LearnedTermProjectIdentity,
        excluding: [String] = [],
        now: Date
    ) -> [String] {
        let index = projectIndex(for: project, now: now)
        var known = Set(projects[index].terms.map(\.term.caseFoldedForMatching))
        known.formUnion(excluding.map(\.caseFoldedForMatching))
        var added: [String] = []
        for term in terms where known.insert(term.caseFoldedForMatching).inserted {
            projects[index].terms.append(
                LearnedTerm(
                    term: term,
                    sources: [LearnedTerm.agentSourcePrefix + proposer],
                    dictations: 0,
                    firstSeen: now,
                    lastSeen: now
                )
            )
            added.append(term)
        }
        prune(now: now)
        // A full project evicts proposals first, so the cap can take back
        // what was just added.
        let kept = Set(termRecord(project.key)?.terms.map(\.term.caseFoldedForMatching) ?? [])
        return added.filter { kept.contains($0.caseFoldedForMatching) }
    }

    /// A terms request for this project failed; the next joined dictation
    /// after `ProjectTermProposal.retryAfter` asks again.
    package mutating func recordProposalFailure(project: LearnedTermProjectIdentity, now: Date) {
        let index = projectIndex(for: project, now: now)
        projects[index].proposalAttemptedAt = now
        prune(now: now)
    }

    /// Pins or unpins one spelling in one project. Returns false when the
    /// project does not hold it.
    @discardableResult
    package mutating func setPinned(_ pinned: Bool, term raw: String, projectKey: String) -> Bool {
        let key = LearnedTerms.sanitized(raw).caseFoldedForMatching
        guard !key.isEmpty,
              let index = termRecordIndex(projectKey),
              let termIndex = projects[index].terms.firstIndex(where: {
                  $0.term.caseFoldedForMatching == key
              })
        else { return false }
        guard !pinned || canPin(projectKey: projectKey) else { return false }
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
              let index = termRecordIndex(projectKey)
        else { return }
        projects[index].terms.removeAll { $0.term.caseFoldedForMatching == key }
        removeEmptyProjects()
    }

    /// Drops every term of these buckets: a project's Forget All in
    /// Settings → Projects. A bucket kept for its proposal stamp or its
    /// host's report stays, empty.
    package mutating func forgetTerms(projectKeys: [String]) {
        // A linked checkout's terms are its repository's (#971).
        let keys = Set(projectKeys + projectKeys.compactMap { termRecord($0)?.key })
        for index in projects.indices where keys.contains(projects[index].key) {
            projects[index].terms = []
        }
        let linked = Set(projects.compactMap { $0.isLinkedCheckout ? $0.repositoryRecordKey : nil })
        projects.removeAll { keys.contains($0.key) && !$0.isKeptWithoutTerms && !linked.contains($0.key) }
    }

    /// The record `project`'s terms go to, made when missing: the
    /// checkout's own, or its repository's once it is linked (#971).
    private mutating func projectIndex(
        for project: LearnedTermProjectIdentity,
        now: Date
    ) -> Int {
        guard let index = projects.firstIndex(where: { $0.key == project.key }) else {
            projects.append(
                LearnedTermProject(key: project.key, name: project.name, terms: [], lastSeen: now)
            )
            return projects.count - 1
        }
        if !projects[index].isRepositoryRecord { projects[index].name = project.name }
        projects[index].lastSeen = now
        guard projects[index].isLinkedCheckout, let remote = projects[index].projectRemote
        else { return index }
        let repositoryIndex = repositoryRecordIndex(for: remote, lastSeen: now)
        projects[repositoryIndex].lastSeen = max(projects[repositoryIndex].lastSeen, now)
        return repositoryIndex
    }

    /// Drops the proposals shaped like code (`SpokenTermShape`) that the user
    /// has not used, pinned or corrected to: what agents proposed before
    /// answers were filtered (#914). A project emptied by it keeps its stamp.
    /// Returns how many were dropped.
    @discardableResult
    package mutating func dropIdentifierProposals() -> Int {
        var dropped = 0
        for index in projects.indices {
            let before = projects[index].terms.count
            projects[index].terms.removeAll {
                $0.isUntouchedProposal && SpokenTermShape.identifier(in: $0.term) != nil
            }
            dropped += before - projects[index].terms.count
        }
        removeEmptyProjects()
        return dropped
    }

    /// Decay and caps, applied after every write and after every load: a file
    /// that has sat on disk for a season must not come back larger than the
    /// caps allow just because nothing has been dictated since.
    package mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(LearnedTerms.staleAfterDays) * 86_400)
        for index in projects.indices {
            projects[index].terms.removeAll { !$0.isPinned && $0.lastSeen < cutoff }
            if let reported = projects[index].reportedAt, reported < cutoff {
                projects[index].reportedAt = nil
            }
            if projects[index].terms.count > LearnedTerms.maxTermsPerProject {
                // A pin is the user's word that the term stays (#989): only
                // the unpinned share what room the pins leave.
                let pinned = projects[index].terms.filter(\.isPinned)
                let room = max(0, LearnedTerms.maxTermsPerProject - pinned.count)
                projects[index].terms = (pinned + projects[index].terms.filter { !$0.isPinned }
                    .sorted(by: LearnedTerms.isStrongerEvidence)
                    .prefix(room))
                    .sorted(by: LearnedTerms.isStrongerEvidence)
            }
        }
        // A linked checkout no dictation or hook has touched for as long as a
        // term lasts goes once its repository has no terms left either:
        // while it has, the checkout must keep pointing there, or its next
        // dictation would start an empty record of its own.
        let repositoriesWithTerms = Set(projects.filter { $0.isRepositoryRecord && !$0.terms.isEmpty }.map(\.key))
        projects.removeAll {
            $0.isLinkedCheckout && $0.terms.isEmpty
                && max($0.lastSeen, $0.reportedAt ?? $0.lastSeen) < cutoff
                && !repositoriesWithTerms.contains($0.repositoryRecordKey ?? "")
        }
        // A stamped project stays with no terms: dropping it would ask its
        // agent again at the next dictation. A reported one stays until its
        // report is as old as a stale term.
        removeEmptyProjects()
        if projects.count > LearnedTerms.maxProjects {
            // A project the user made a choice in is never evicted (#989);
            // the rest share the room left, one kept only for a hook's
            // report going first.
            var room = max(0, LearnedTerms.maxProjects - projects.filter(\.isExplicit).count)
            projects = projects
                .sorted { lhs, rhs in
                    if lhs.isExplicit != rhs.isExplicit { return lhs.isExplicit }
                    let lhsReportOnly = lhs.terms.isEmpty && !lhs.hasProposalStamp
                    let rhsReportOnly = rhs.terms.isEmpty && !rhs.hasProposalStamp
                    if lhsReportOnly != rhsReportOnly { return rhsReportOnly }
                    return lhs.lastSeen == rhs.lastSeen
                        ? lhs.key < rhs.key
                        : lhs.lastSeen > rhs.lastSeen
                }
                .filter { project in
                    guard !project.isExplicit else { return true }
                    guard room > 0 else { return false }
                    room -= 1
                    return true
                }
        }
    }

    /// Whether pinning a term in this project keeps within `maxProjects`
    /// projects the user made a choice in: a project already one always
    /// can. Settings disables the pin when not (#989).
    package func canPin(projectKey: String) -> Bool {
        guard let index = termRecordIndex(projectKey) else { return false }
        return projects[index].isExplicit
            || projects.filter(\.isExplicit).count < LearnedTerms.maxProjects
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
