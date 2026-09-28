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
package final class LearnedTermStore: ProjectTermProposalStoring, RemoteProjectSummaryStoring, QuickCaptureProjectLinkStoring, @unchecked Sendable {
    private struct State {
        var terms: LearnedTerms?
        /// Set, the file on disk is left alone.
        var problem: StoredFileProblem?
        /// Set, `ignored-projects.json` is left alone, and nothing is
        /// learned: without the list, any repo could be an ignored one.
        var ignoredListProblem: StoredFileProblem?
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

    /// `fileURL` nil keeps everything in memory (tests, previews). The file is
    /// read on the write queue right away, and every later read and write is
    /// ordered behind that, so nothing else ever has to load it.
    package init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in
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
                let folded = loaded.foldWorktreesIntoMainCheckouts(now: now())
                    // A checkout whose `origin` a hook or the linker already
                    // recorded gives its terms to its repository (#971).
                    + loaded.linkCheckoutsToRepositories(now: now())
                // Proposals agents made before answers were filtered (#914),
                // and records an older build kept for an ignored repo.
                let dropped = loaded.dropIdentifierProposals() + loaded.removeIgnoredProjects()
                let adopted = state.withLock { state in
                    guard state.terms == nil else { return false }
                    state.terms = loaded
                    return true
                }
                if folded + dropped > 0, adopted, ignoredLoad.problem == nil {
                    if loaded.ignored != ignored { writeIgnored(loaded.ignored) }
                    Log.polishing.info(
                        "Learned terms: folded \(folded, privacy: .public) worktrees and checkouts into their projects, dropped \(dropped, privacy: .public) proposals shaped like code or records of ignored repos"
                    )
                    write(loaded)
                    onChange?()
                }
            }
        }
    }

    package static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("learned-terms.json")
    }

    // MARK: Reading

    /// What is in memory, without ever reading the disk: callers are the
    /// `@MainActor` commit path and Settings, and neither may block on a
    /// volume (review, 2026-09-20). Before the launch load lands this answers
    /// empty, which costs the first dictation its remembered terms and nothing
    /// else.
    package func snapshot() -> LearnedTerms {
        state.withLock { $0.terms } ?? LearnedTerms()
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
        mutate { memory in memory.recordOrigin(remote, projectKey: projectKey) }
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
        mutate { terms in
            terms.ignoreProject(key: key, name: name, keys: keys, now: moment)
            let count = terms.ignored.projects.count
            Log.polishing.info("Learned terms: a project ignored, \(count, privacy: .public) ignored")
        }
    }

    /// Un-ignore: the project comes back at its next dictation.
    package func unignoreProject(key: String) {
        mutate { terms in
            terms.unignoreProject(key: key)
            let count = terms.ignored.projects.count
            Log.polishing.info("Learned terms: a project un-ignored, \(count, privacy: .public) ignored")
        }
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
        refused: @escaping @Sendable () -> Void = {}
    ) {
        writeQueue.async { [self] in
            // The launch load ran first on this queue; a store with no file
            // starts empty.
            let changed: (terms: LearnedTerms, ignoredChanged: Bool)? = state.withLock { state in
                guard state.problem == nil, state.ignoredListProblem == nil else { return nil }
                var terms = state.terms ?? LearnedTerms()
                let ignoredBefore = terms.ignored
                change(&terms)
                // The one place every write passes: whatever it recorded for
                // an ignored repo goes before it is kept or written (#1006).
                terms.removeIgnoredProjects()
                state.terms = terms
                return (terms, terms.ignored != ignoredBefore)
            }
            guard let changed else {
                Log.persistence.error("learned terms: a change was refused, a file could not be loaded")
                refused()
                return
            }
            // The ignore list first: a crash between the two writes then
            // leaves an ignored repo's records to the next load's sweep, never
            // a forgotten record with no ignore entry to keep it out.
            if changed.ignoredChanged { writeIgnored(changed.terms.ignored) }
            write(changed.terms)
            onChange?()
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
                    state.withLock { state in
                        state.terms = LearnedTerms()
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
                    state.withLock { state in
                        state.ignoredListProblem = nil
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

    private func loadFromDisk() -> StoredFileLoad<LearnedTerms> {
        guard let fileURL else { return .absent }
        let load = StoredFile.load(
            LearnedTerms.self, from: fileURL, currentVersion: LearnedTerms.currentVersion, decoder: Self.decoder)
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

    private func loadIgnoredFromDisk() -> StoredFileLoad<IgnoredProjects> {
        guard let ignoredFileURL else { return .absent }
        return StoredFile.load(
            IgnoredProjects.self, from: ignoredFileURL, currentVersion: IgnoredProjects.currentVersion,
            decoder: Self.decoder)
    }

    /// Called on the write queue, never off it.
    private func writeIgnored(_ ignored: IgnoredProjects) {
        guard let ignoredFileURL, state.withLock({ $0.ignoredListProblem }) == nil else { return }
        do {
            let data = try Self.encoder.encode(ignored)
            try FileManager.default.createDirectory(
                at: ignoredFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: ignoredFileURL, options: .atomic)
        } catch {
            Log.persistence.error(
                "ignored projects: write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Called on the write queue, never off it.
    private func write(_ terms: LearnedTerms) {
        guard let fileURL, state.withLock({ $0.problem == nil && $0.ignoredListProblem == nil }) else { return }
        do {
            let data = try Self.encoder.encode(terms)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.persistence.error(
                "learned terms: write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
