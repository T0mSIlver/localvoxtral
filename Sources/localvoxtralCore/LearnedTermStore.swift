import Foundation
import Synchronization
#if canImport(os)
import os
#endif

/// The file around `LearnedTerms`: one small JSON document under Application
/// Support, held in memory so that NOTHING on the dictation commit path or in
/// Settings ever touches the disk. Reads answer from memory or answer empty;
/// writes are folded in on the store's own queue. The file is loaded there
/// once at launch, so the only window where a reader sees an empty memory is
/// between launch and that first load.
///
/// Never holds dictated text. A remembered term is a spelling the polish
/// pipeline already resolved — a file name, a product, a model — and the
/// counters beside it, which is exactly what `SpeakerTerms` keeps for the
/// hand-written list.
///
/// A file this build cannot read, or one a newer build wrote, is kept as it
/// is: the store answers empty, refuses every write and says why in
/// `problem` until the user moves the file aside (#989). It also holds the
/// project and repository records, which an empty rewrite would lose.
///
/// Another running copy of the app may write the same file (#990). Every
/// write re-reads it under their shared lock and applies its change to what
/// the other copy wrote (`StoredFile.update`), and Settings' Projects pane
/// reads it again when it appears (`reloadIfChanged`, #1126).
package final class LearnedTermStore: ProjectTermProposalStoring, RemoteProjectSummaryStoring, QuickCaptureProjectLinkStoring, @unchecked Sendable {
    private struct State {
        var terms: LearnedTerms?
        /// Set, the file on disk is left alone.
        var problem: StoredFileProblem?
        /// Set, `ignored-projects.json` is left alone, and nothing is
        /// learned: without the list, any repo could be an ignored one.
        var ignoredListProblem: StoredFileProblem?
        /// The last ignore-list write failed: memory holds a change the file
        /// lacks, and every write tries it again before the terms' file.
        var ignoredListUnsaved = false
    }

    package let fileURL: URL?
    /// `ignored-projects.json`, beside `fileURL` (#1006).
    package var ignoredFileURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent(Self.ignoredFileName)
    }
    package static let ignoredFileName = "ignored-projects.json"
    private let state = Mutex(State())
    private let writeQueue = DispatchQueue(label: "localvoxtral.learned-terms", qos: .utility)
    private let now: @Sendable () -> Date
    private let onChange: (@Sendable () -> Void)?
    /// The file as this copy last read or wrote it. Write queue only.
    private var seen = StoredFileSeen()
    /// The last write failed, so memory holds a change the file does not.
    /// Write queue only.
    private var hasUnsavedChanges = false
    /// The same as `seen`, for `ignored-projects.json`. Write queue only.
    private var seenIgnored = StoredFileSeen()
    /// Ignore-list changes whose write failed, replayed by the next one.
    /// Write queue only.
    private var pendingListChanges: [(inout IgnoredProjects) -> Void] = []
    /// Writes `ignored-projects.json`; tests make it fail.
    private let writeIgnoredList: (Data, URL) throws -> Void
    /// Runs on the write queue between the ignore list and the terms'
    /// update; tests write as another running copy there.
    private let beforeTermsUpdate: (@Sendable () -> Void)?

    /// `fileURL` nil keeps everything in memory (tests, previews). The file is
    /// read on the write queue right away, and every later read and write is
    /// ordered behind that, so nothing else ever has to load it.
    /// `beforeLaunchLoad` runs on that queue first: tests hold the load there
    /// to see what a slow launch answers.
    package init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable () -> Void)? = nil,
        beforeLaunchLoad: (@Sendable () -> Void)? = nil,
        writeIgnoredList: @escaping @Sendable (Data, URL) throws -> Void = LearnedTermStore.writeFile,
        beforeTermsUpdate: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.writeIgnoredList = writeIgnoredList
        self.beforeTermsUpdate = beforeTermsUpdate
        self.now = now
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in
                beforeLaunchLoad?()
                let ignoredLoad = loadIgnoredFromDisk()
                var ignored = ignoredLoad.value ?? IgnoredProjects()
                if let problem = ignoredLoad.problem {
                    state.withLock { $0.ignoredListProblem = problem }
                    ignored.isUnreadable = true
                }
                let load = loadFromDisk()
                if let problem = load.problem {
                    state.withLock { state in
                        state.terms = LearnedTerms()
                        state.terms?.ignored = ignored
                        state.problem = problem
                    }
                    onChange?()
                    return
                }
                var loaded = load.value ?? LearnedTerms()
                loaded.ignored = ignored
                // Every launch, not once: a hand fix in a worktree is keyed by
                // the joined session's directory (the commit path may not read
                // `.git`), and this is where it reaches the main checkout.
                // Idempotent, so a file with nothing to fold is not rewritten.
                let moment = now()
                let tidy: @Sendable (inout LearnedTerms) -> Int = { terms in
                    terms.foldWorktreesIntoMainCheckouts(now: moment)
                        // A checkout whose `origin` a hook or the linker already
                        // recorded gives its terms to its repository (#971).
                        + terms.linkCheckoutsToRepositories(now: moment)
                        // Proposals agents made before answers were filtered (#914).
                        + terms.dropIdentifierProposals()
                        // Records an older build kept for an ignored repo (#1006).
                        + terms.removeIgnoredProjects()
                }
                var probe = loaded
                let adopted = state.withLock { state in
                    guard state.terms == nil else { return false }
                    state.terms = loaded
                    return true
                }
                if tidy(&probe) > 0, adopted {
                    // Refused, and so not written, while the ignore list is.
                    commit { terms in
                        let tidied = tidy(&terms)
                        Log.polishing.info(
                            "Learned terms: \(tidied, privacy: .public) worktrees, checkouts, code-shaped proposals and records of ignored repos folded into their projects or dropped"
                        )
                    }
                }
            }
        }
    }

    package static func defaultFileURL() -> URL {
        return LocalvoxtralDataDirectory.url()
            .appendingPathComponent("learned-terms.json")
    }

    // MARK: Reading

    /// What is in memory, without ever reading the disk: callers are the
    /// `@MainActor` commit path and Settings, and neither may block on a
    /// volume (review, 2026-09-20). Before the launch load lands this answers
    /// empty, which costs the first dictation its remembered terms, and with
    /// the ignore list unknown, so no agent is asked for any repo until it
    /// lands (#1006).
    package func snapshot() -> LearnedTerms {
        if let terms = state.withLock({ $0.terms }) { return terms }
        var pending = LearnedTerms()
        pending.ignored.isUnreadable = fileURL != nil
        return pending
    }

    /// The confirmed spellings for one project, strongest evidence first.
    package func confirmedTerms(
        projectKey: String,
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [String] {
        snapshot().confirmedTerms(projectKey: projectKey, minimumDictations: minimumDictations)
    }

    /// The terms once the launch load has landed: answered on the write
    /// queue, behind the load and every write already queued. For the
    /// `localvoxtral` command (#721), which is off the main actor and may be
    /// the first thing to ask after launch.
    package func loadedSnapshot() async -> LearnedTerms {
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                continuation.resume(returning: state.withLock { $0.terms } ?? LearnedTerms())
            }
        }
    }

    /// Why the file was not loaded, nil when it was or when there is none
    /// yet. Answers nil until the launch load lands.
    package var problem: StoredFileProblem? {
        state.withLock { $0.problem }
    }

    /// Why `ignored-projects.json` was not loaded (#1006). Set, nothing is
    /// learned or recorded until the user moves it aside.
    package var ignoredListProblem: StoredFileProblem? {
        state.withLock { $0.ignoredListProblem }
    }

    /// Whether the last write of `ignored-projects.json` failed. The change
    /// holds in memory and is written again at the next change; the terms'
    /// file is not written meanwhile, so a relaunch finds the project as it
    /// was, not forgotten with no entry to keep it out.
    package var ignoredListUnsaved: Bool {
        state.withLock { $0.ignoredListUnsaved }
    }

    /// Terms, then the projects that hold them.
    package func summary() -> (terms: Int, projects: Int) {
        let terms = snapshot()
        return (terms.termCount, terms.projects.filter { !$0.terms.isEmpty }.count)
    }

    // MARK: Writing

    /// One dictation's resolved terms. Returns without touching the disk when
    /// there is nothing to remember, which is the common case for a sentence
    /// the recognizer got right.
    /// One dictation's resolved terms.
    ///
    /// The whole fold happens on the write queue, behind the launch load and
    /// behind any earlier record: the commit path hands over the observations
    /// and returns. That is what keeps a dictation off the disk, and it is
    /// also what makes the file's order the memory's order — two records can
    /// no longer hand the queue an older state after a newer one.
    package func record(
        _ observations: [LearnedTermObservation],
        project: LearnedTermProjectResolver.Identity
    ) {
        guard !observations.isEmpty else { return }
        let moment = now()
        mutate { terms in
            terms.record(observations, project: project, now: moment)
            let kept = terms.termCount
            Log.polishing.info(
                "Learned terms recorded: \(observations.count, privacy: .public) in project \(project.key == LearnedTermProjectResolver.shared.key ? "shared" : "keyed", privacy: .public), \(kept, privacy: .public) kept"
            )
        }
    }

    /// A spelling the user fixed a dictation to by hand, confirmed at once
    /// (`LearnedTerms.recordCorrection`). Ordered on the write queue like
    /// `record`.
    package func recordCorrection(_ term: String, project: LearnedTermProjectResolver.Identity) {
        let moment = now()
        mutate { terms in
            terms.recordCorrection(term, project: project, now: moment)
        }
        Log.polishing.info(
            "Learned terms: correction recorded in project \(project.key == LearnedTermProjectResolver.shared.key ? "shared" : "keyed", privacy: .public)"
        )
    }

    /// A project's coding agent answered its terms request
    /// (`LearnedTerms.recordProposal`, #609). Ordered on the write queue like
    /// `record`.
    package func recordProposal(
        _ terms: [String],
        line: String? = nil,
        revision: Int? = nil,
        agent: ProjectTermProposal.Agent,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    ) {
        let moment = now()
        mutate { memory in
            let added = memory.recordProposal(
                terms, line: line, revision: revision, agent: agent, project: project, excluding: excluding,
                now: moment)
            Log.polishing.info(
                "Learned terms: \(added, privacy: .public) proposed by \(agent.rawValue, privacy: .public) kept for a new project"
            )
        }
    }

    /// Terms an agent proposed through `localvoxtral terms propose`
    /// (`LearnedTerms.recordCommandProposal`, #721). Returns the terms added
    /// once the write queue has folded them in.
    package func recordCommandProposal(
        _ terms: [String],
        proposer: String,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    ) async -> [String] {
        let moment = now()
        return await withCheckedContinuation { continuation in
            mutate(
                { memory in
                    let added = memory.recordCommandProposal(
                        terms, proposer: proposer, project: project, excluding: excluding, now: moment)
                    Log.polishing.info(
                        "Learned terms: \(added.count, privacy: .public) proposed by \(proposer, privacy: .public) through the command"
                    )
                    continuation.resume(returning: added)
                },
                refused: { continuation.resume(returning: []) }
            )
        }
    }

    /// A remote host reported its project's README summary (#745).
    package func recordSummary(_ summary: String?, projectKey: String) {
        let moment = now()
        mutate { memory in
            let kept = memory.recordSummary(summary, projectKey: projectKey, now: moment)
            Log.polishing.info(
                "Learned terms: remote README summary \(kept ? (summary == nil ? "empty" : "kept") : "dropped, project gone", privacy: .public)"
            )
        }
    }

    /// A hook from a remote session named its project (#819), and its
    /// `origin`'s GitHub repository when the host sent one (#926), and the
    /// host it came from.
    package func recordRemoteReport(
        project: LearnedTermProjectIdentity, asRepository: Bool, repository: String?, hostID: String? = nil
    ) {
        let moment = now()
        mutate { memory in
            if memory.recordRemoteReport(
                project: project, asRepository: asRepository, repository: repository, hostID: hostID, now: moment
            ) {
                Log.polishing.info("Learned terms: a remote hook named a new repository")
            }
        }
    }

    /// A local checkout's `origin` (#926).
    package func recordOrigin(_ remote: ProjectRemote, projectKey: String) {
        mutate(
            { memory in memory.recordOrigin(remote, projectKey: projectKey) },
            // A checkout of an ignored repo joins its entry even before it
            // has a record, as after a first dictation that learned nothing.
            ignoring: { _, list in list.addCheckout(projectKey, ofEntryHolding: remote.key) })
    }

    /// The user's `owner/name` for a project with no GitHub `origin`.
    package func recordTypedRepository(_ repository: String, projectKey: String) {
        mutate { memory in
            let kept = memory.recordTypedRepository(repository, projectKey: projectKey)
            Log.polishing.info("Learned terms: a typed repository \(kept ? "kept" : "dropped", privacy: .public)")
        }
    }

    /// GitHub's description of a repository (#926).
    package func recordGitHub(_ facts: GitHubRepositoryFacts, repository: String) {
        let moment = now()
        mutate { memory in memory.recordGitHub(facts, repository: repository, now: moment) }
    }

    /// The "File issues here" choice for a fork.
    package func setFilesUpstream(_ upstream: Bool, repository: String) {
        mutate { memory in memory.setFilesUpstream(upstream, repository: repository) }
        Log.polishing.info("Learned terms: a fork files \(upstream ? "upstream" : "in the fork", privacy: .public)")
    }

    /// The Projects pane's Work or Personal choice for one row (#1005).
    package func setGroup(_ group: ProjectGroup?, keys: [String]) {
        mutate { memory in memory.setGroup(group, keys: keys) }
        Log.polishing.info("Learned terms: a project moved to group \(group?.rawValue ?? "none", privacy: .public)")
    }

    /// A terms request failed; the project is asked again after a day.
    package func recordProposalFailure(project: LearnedTermProjectIdentity) {
        let moment = now()
        mutate { memory in
            memory.recordProposalFailure(project: project, now: moment)
        }
    }

    /// Drops one spelling from one project: Undo, or the user reverting it.
    package func forget(_ term: String, projectKey: String) {
        mutate { terms in
            terms.forget(term, projectKey: projectKey)
        }
        Log.polishing.info("Learned terms: one term forgotten")
    }

    /// Settings' pin: keeps one spelling past decay and caps.
    package func setPinned(_ pinned: Bool, term: String, projectKey: String) {
        mutate { terms in
            terms.setPinned(pinned, term: term, projectKey: projectKey)
        }
        Log.polishing.info("Learned terms: one term \(pinned ? "pinned" : "unpinned", privacy: .public)")
    }

    /// The pin in a project's sheet: every one of the project's buckets
    /// that holds the spelling, since the sheet shows it once.
    package func setPinned(_ pinned: Bool, term: String, projectKeys: [String]) {
        mutate { terms in
            for key in projectKeys { terms.setPinned(pinned, term: term, projectKey: key) }
        }
        Log.polishing.info("Learned terms: one term \(pinned ? "pinned" : "unpinned", privacy: .public)")
    }

    /// Forget in a project's sheet: the spelling leaves every bucket of it.
    package func forget(_ term: String, projectKeys: [String]) {
        mutate { terms in
            for key in projectKeys { terms.forget(term, projectKey: key) }
        }
        Log.polishing.info("Learned terms: one term forgotten")
    }

    /// A project's Forget All.
    package func forgetTerms(projectKeys: [String]) {
        mutate { terms in terms.forgetTerms(projectKeys: projectKeys) }
        Log.polishing.info("Learned terms: \(projectKeys.count, privacy: .public) buckets forgotten")
    }

    /// Forget Project (#1006): the project's records and terms go.
    package func forgetProject(keys: [String]) {
        mutate { terms in
            let removed = terms.forgetProject(keys: keys)
            Log.polishing.info("Learned terms: a project forgotten, \(removed, privacy: .public) records removed")
        }
    }

    /// Ignore Project (#1006): forgotten, and kept out from now on.
    package func ignoreProject(key: String, name: String, keys: [String]) {
        let moment = now()
        mutate(
            { terms in
                terms.ignoreProject(key: key, name: name, keys: keys, now: moment)
                let count = terms.ignored.projects.count
                Log.polishing.info("Learned terms: a project ignored, \(count, privacy: .public) ignored")
            },
            // The entry, added to the list as another running copy left it.
            ignoring: { terms, list in
                var probe = terms
                probe.ignored = list
                probe.ignoreProject(key: key, name: name, keys: keys, now: moment)
                list = probe.ignored
            })
    }

    /// Un-ignore: the project comes back at its next dictation.
    package func unignoreProject(key: String) {
        mutate(
            { terms in
                let count = terms.ignored.projects.count
                Log.polishing.info("Learned terms: a project un-ignored, \(count, privacy: .public) ignored")
            },
            ignoring: { _, list in list.projects.removeAll { $0.key == key } })
    }

    /// Folds an imported file's projects in (`LearnedTerms.merge`), ordered
    /// on the write queue like every write. `completion` runs on that queue.
    package func importProjects(
        _ projects: [LearnedTermProject],
        completion: @escaping @Sendable (LearnedTermsExport.ImportSummary) -> Void
    ) {
        let moment = now()
        mutate(
            { terms in
                // An ignored repo's records are not imported, nor counted.
                let summary = terms.merge(importing: projects.filter { !terms.ignored.contains($0) }, now: moment)
                // Terms imported onto a linked checkout belong to its repository.
                terms.linkCheckoutsToRepositories(now: moment)
                let kept = terms.termCount
                Log.polishing.info(
                    "Learned terms imported: \(summary.terms, privacy: .public) terms in \(summary.projects, privacy: .public) projects, \(kept, privacy: .public) kept"
                )
                completion(summary)
            },
            refused: { completion(LearnedTermsExport.ImportSummary(terms: 0, projects: 0)) }
        )
    }

    /// Folds `change` in on the write queue, behind the launch load and every
    /// earlier write, so an Undo can never land before the term it undoes.
    /// While the file is refused, `change` never runs and `refused` does.
    private func mutate(
        _ change: @escaping @Sendable (inout LearnedTerms) -> Void,
        ignoring ignoredChange: (@Sendable (LearnedTerms, inout IgnoredProjects) -> Void)? = nil,
        refused: @escaping @Sendable () -> Void = {}
    ) {
        writeQueue.async { [self] in commit(change, ignoring: ignoredChange, refused: refused) }
    }

    /// `mutate`'s body, on the write queue. The launch load ran first on this
    /// queue; a store with no file starts empty.
    ///
    /// Two files, each a transaction with other running copies (#990), and
    /// the ignore list's lock is held across both, so another copy cannot
    /// un-ignore a repo and record in it between this copy reading the list
    /// and sweeping the terms it adopts. The ignore list goes first:
    /// `ignoredChange` applies to what is on disk, so another copy's ignores
    /// stay, and a crash between the two writes leaves an ignored repo's
    /// records to the next sweep, never a forgotten record with no entry to
    /// keep it out. While the list is unsaved, the terms' change holds in
    /// memory only. Then the terms: `change`, and the sweep of ignored
    /// records inside the same transaction, so it also applies to what
    /// another copy wrote.
    private func commit(
        _ change: (inout LearnedTerms) -> Void,
        ignoring ignoredChange: ((LearnedTerms, inout IgnoredProjects) -> Void)? = nil,
        refused: () -> Void = {}
    ) {
        let (memory, problem, listProblem) = state.withLock {
            ($0.terms ?? LearnedTerms(), $0.problem, $0.ignoredListProblem)
        }
        guard problem == nil, listProblem == nil else {
            Log.persistence.error("learned terms: a change was refused, a file could not be loaded")
            refused()
            return
        }
        guard let fileURL, let ignoredFileURL else {
            var terms = memory
            ignoredChange?(memory, &terms.ignored)
            change(&terms)
            terms.removeIgnoredProjects()
            state.withLock { $0.terms = terms }
            onChange?()
            return
        }
        StoredFileLock.withLock(beside: ignoredFileURL) {
            commitHoldingTheListLock(
                fileURL, ignoredFileURL, memory: memory, change: change, ignoredChange: ignoredChange,
                refused: refused)
        }
        onChange?()
    }

    private func commitHoldingTheListLock(
        _ fileURL: URL, _ ignoredFileURL: URL, memory: LearnedTerms,
        change: (inout LearnedTerms) -> Void,
        ignoredChange: ((LearnedTerms, inout IgnoredProjects) -> Void)?,
        refused: () -> Void
    ) {
        let listChange = ignoredChange.map { ignoredChange in { (list: inout IgnoredProjects) in ignoredChange(memory, &list) } }
        guard let ignored = updateIgnoredList(ignoredFileURL, memory: memory.ignored, change: listChange) else {
            refused()
            return
        }
        if !pendingListChanges.isEmpty {
            var terms = memory
            terms.ignored = ignored
            change(&terms)
            terms.removeIgnoredProjects()
            state.withLock { $0.terms = terms }
            return
        }
        beforeTermsUpdate?()
        var swept = ignored
        let update = StoredFile.update(
            fileURL, memory: memory, seen: &seen,
            decode: Self.terms(fromFileContents:),
            encode: { try Self.encoder.encode($0) },
            write: Self.writeFile,
            change: { terms in
                terms.ignored = ignored
                change(&terms)
                // The one place every write passes: whatever it recorded for
                // an ignored repo goes before it is kept or written (#1006).
                terms.removeIgnoredProjects()
                swept = terms.ignored
            })
        switch update {
        case .written(let terms):
            state.withLock { $0.terms = terms }
            hasUnsavedChanges = false
        case .failed(let terms, let error):
            state.withLock { $0.terms = terms }
            hasUnsavedChanges = true
            Log.persistence.error("learned terms: write failed: \(error.localizedDescription, privacy: .public)")
        case .refused(let problem):
            // Another copy left a file this build cannot read: keep it.
            state.withLock { state in
                state.terms = LearnedTerms()
                state.terms?.ignored = ignored
                state.problem = problem
            }
            Log.persistence.error("learned terms: a change was refused, another copy left a file this build cannot read")
            refused()
            return
        }
        if swept != ignored {
            // The sweep found a checkout of an ignored repo, such as a new
            // clone: its key joins the entry.
            _ = updateIgnoredList(ignoredFileURL, memory: ignored, change: { $0.adoptCheckouts(from: swept) })
        }
    }

    /// One change to `ignored-projects.json`, as a transaction like the
    /// terms' (`StoredFile.update`); the caller holds the list's lock. A
    /// change whose write failed waits in `pendingListChanges`, and every
    /// later update replays it onto the list as it then is on disk, so
    /// another copy's write in between loses neither copy's change. The
    /// changes are idempotent. With nothing to write it only reads the file,
    /// to pick up another copy's ignores. Returns the list, also put in
    /// memory, or nil when the file was refused.
    private func updateIgnoredList(
        _ url: URL, memory: IgnoredProjects, change: ((inout IgnoredProjects) -> Void)?
    ) -> IgnoredProjects? {
        var current = memory
        if pendingListChanges.isEmpty {
            guard let read = readIgnoredList(url, memory: memory) else { return nil }
            current = read
            guard let change else { return current }
            var probe = current
            change(&probe)
            if probe == current { return current }
        }
        let changes = pendingListChanges + (change.map { [$0] } ?? [])
        let update = StoredFile.updateHoldingTheLock(
            url, memory: current, seen: &seenIgnored,
            decode: Self.ignored(fromFileContents:),
            encode: { try Self.encoder.encode($0) },
            write: writeIgnoredList,
            change: { list in for change in changes { change(&list) } })
        switch update {
        case .written(let list):
            pendingListChanges = []
            state.withLock { state in
                state.terms?.ignored = list
                state.ignoredListUnsaved = false
            }
            return list
        case .failed(let list, let error):
            Log.persistence.error(
                "ignored projects: write failed, kept in memory until the next change: \(error.localizedDescription, privacy: .public)"
            )
            pendingListChanges = changes
            state.withLock { state in
                state.terms?.ignored = list
                state.ignoredListUnsaved = true
            }
            return list
        case .refused(let problem):
            refuseIgnoredList(problem, memory: memory)
            return nil
        }
    }

    /// The list as on disk, adopted when another copy wrote it since this
    /// one last read or wrote it. The caller holds the list's lock.
    private func readIgnoredList(_ url: URL, memory: IgnoredProjects) -> IgnoredProjects? {
        let stamp = StoredFileStamp.of(url)
        switch StoredFile.read(url) {
        case .absent:
            return memory
        case .unreadable:
            refuseIgnoredList(.unreadable, memory: memory)
            return nil
        case .bytes(let data):
            guard data != seenIgnored.bytes else { return memory }
            switch Self.ignored(fromFileContents: data) {
            case .loaded(let list):
                seenIgnored = StoredFileSeen(bytes: data, stamp: stamp)
                Log.persistence.notice("ignored projects: another running copy changed the list, adopted")
                state.withLock { $0.terms?.ignored = list }
                return list
            case .refused(let problem):
                refuseIgnoredList(problem, memory: memory)
                return nil
            case .absent:
                refuseIgnoredList(.unreadable, memory: memory)
                return nil
            }
        }
    }

    /// Another copy left a list this build cannot read: it is kept, and
    /// nothing is learned until Start Over, since any repo may be ignored.
    private func refuseIgnoredList(_ problem: StoredFileProblem, memory: IgnoredProjects) {
        Log.persistence.error("ignored projects: a change was refused, another copy left a file this build cannot read")
        state.withLock { state in
            state.ignoredListProblem = problem
            var unreadable = memory
            unreadable.isUnreadable = true
            state.terms?.ignored = unreadable
        }
    }

    /// The Start Over in Settings: moves a refused file aside
    /// (`StoredFile.moveAside`) and starts empty. Throws, keeping the refusal,
    /// when the move could not be verified.
    package func moveAsideAndStartOver() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                guard let fileURL, state.withLock({ $0.problem }) != nil else {
                    continuation.resume(throwing: StoredFile.MoveAsideFailed())
                    return
                }
                do {
                    let aside = try StoredFile.moveAside(fileURL)
                    seen = StoredFileSeen()
                    state.withLock { state in
                        // The ignore list has its own file, which still
                        // holds: an empty one here would lift every opt-out.
                        var fresh = LearnedTerms()
                        fresh.ignored = state.terms?.ignored ?? IgnoredProjects()
                        state.terms = fresh
                        state.problem = nil
                    }
                    onChange?()
                    continuation.resume(returning: aside)
                } catch {
                    Log.persistence.error(
                        "learned terms: could not move the file aside: \(String(describing: error), privacy: .public)"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Start Over for `ignored-projects.json`: moves it aside and starts
    /// with no ignored repo. Throws, keeping the refusal, when the move
    /// could not be verified.
    package func moveIgnoredListAsideAndStartOver() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                guard let ignoredFileURL, state.withLock({ $0.ignoredListProblem }) != nil else {
                    continuation.resume(throwing: StoredFile.MoveAsideFailed())
                    return
                }
                do {
                    let aside = try StoredFile.moveAside(ignoredFileURL)
                    seenIgnored = StoredFileSeen()
                    pendingListChanges = []
                    state.withLock { state in
                        state.ignoredListProblem = nil
                        state.ignoredListUnsaved = false
                        state.terms?.ignored = IgnoredProjects()
                    }
                    onChange?()
                    continuation.resume(returning: aside)
                } catch {
                    Log.persistence.error(
                        "ignored projects: could not move the file aside: \(String(describing: error), privacy: .public)"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Settings' Projects pane appeared: when another running copy wrote the
    /// file since this copy last read or wrote it, memory takes the file as
    /// it is now, and `onChange` runs. One `lstat` when nothing changed. On
    /// the write queue, behind the launch load and every queued write;
    /// returns once done. A refused file stays refused, and a failed write's
    /// change is not dropped: the next write applies it on top of the other
    /// copy's.
    package func reloadIfChanged() async {
        guard fileURL != nil else { return }
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                reloadFromDisk()
                continuation.resume()
            }
        }
    }

    /// `reloadIfChanged`'s body, on the write queue.
    private func reloadFromDisk() {
        guard let fileURL, state.withLock({ $0.problem }) == nil, !hasUnsavedChanges else { return }
        switch StoredFile.reloadIfChanged(fileURL, seen: &seen, decode: Self.terms(fromFileContents:)) {
        case nil, .absent?:
            return
        case .loaded(var terms)?:
            terms.prune(now: now())
            state.withLock { state in
                // The ignore list has its own file: the terms' file never
                // carries it, and an older copy may have recorded an ignored
                // repo there (#1006).
                terms.ignored = state.terms?.ignored ?? IgnoredProjects()
                terms.removeIgnoredProjects()
                state.terms = terms
            }
            Log.persistence.notice("learned terms: another running copy wrote the file, read again")
        case .refused(let problem)?:
            state.withLock { state in
                var fresh = LearnedTerms()
                fresh.ignored = state.terms?.ignored ?? IgnoredProjects()
                state.terms = fresh
                state.problem = problem
            }
            Log.persistence.error("learned terms: another copy left a file this build cannot read")
        }
        onChange?()
    }

    /// Blocks until the queued writes have landed. For tests and for nothing
    /// else — the app never waits on this queue.
    package func waitForPendingWrites() {
        writeQueue.sync {}
    }

    // MARK: File

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A file that does not decode — a torn write, a hand edit — or that a
    /// later build wrote is refused, never read as empty (#989): the next
    /// write would replace every learned spelling, pin and project record.
    package static func terms(fromFileContents data: Data) -> StoredFileLoad<LearnedTerms> {
        StoredFile.decode(
            LearnedTerms.self, from: data, name: "learned-terms.json",
            currentVersion: LearnedTerms.currentVersion, decoder: decoder)
    }

    /// Called on the write queue, never off it.
    private func loadFromDisk() -> StoredFileLoad<LearnedTerms> {
        guard let fileURL else { return .absent }
        let load: StoredFileLoad<LearnedTerms>
        (load, seen) = StoredFile.loadShared(fileURL, decode: Self.terms(fromFileContents:))
        guard var terms = load.value else { return load }
        // Decay applies to a file that has been sitting still, not only to one
        // being written: a project left alone for a season must not come back
        // grounding today's dictation.
        terms.prune(now: now())
        return .loaded(terms)
    }

    /// A file that does not decode, or one a later build wrote, is refused
    /// like the terms' (#989): read as empty, the next write would lift
    /// every opt-out.
    package static func ignored(fromFileContents data: Data) -> StoredFileLoad<IgnoredProjects> {
        StoredFile.decode(
            IgnoredProjects.self, from: data, name: ignoredFileName,
            currentVersion: IgnoredProjects.currentVersion, decoder: decoder)
    }

    /// Called on the write queue, never off it.
    private func loadIgnoredFromDisk() -> StoredFileLoad<IgnoredProjects> {
        guard let ignoredFileURL else { return .absent }
        let load: StoredFileLoad<IgnoredProjects>
        (load, seenIgnored) = StoredFile.loadShared(ignoredFileURL, decode: Self.ignored(fromFileContents:))
        return load
    }

    package static func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(data, to: url)
    }
}
