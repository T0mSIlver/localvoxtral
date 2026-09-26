import ClaudeContextWire
import Foundation
import Synchronization

/// Where proposals are kept. `LearnedTermStore` in the app; the writes are
/// asynchronous there, which is why the proposer also remembers what it
/// asked this launch.
package protocol ProjectTermProposalStoring: Sendable {
    func snapshot() -> LearnedTerms
    func recordProposal(
        _ terms: [String],
        agent: ProjectTermProposal.Agent,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    )
    func recordProposalFailure(project: LearnedTermProjectIdentity)
}

/// Asks a project's coding agent for its terms after the first joined
/// dictation there (#609).
///
/// The commit path calls `dictationCommitted` once the text is inserted, and
/// it returns at once: everything else runs in a detached task, so neither
/// the dictation nor the next one waits for the run. The run is its own
/// process, never the user's session, so it cannot interrupt a turn.
///
/// The project key is `LearnedTermProjectResolver`'s, resolved here off the
/// commit path: the session directory's git root, keyed by its main checkout
/// (#652), so every worktree of a repository shares one answer. The run's
/// working directory is that git root, or the session directory outside a
/// repository. One stamp per project, whichever agent joins first.
package final class ProjectTermProposer: @unchecked Sendable {
    private let store: any ProjectTermProposalStoring
    private let runner: any ProjectTermProposalRunning
    private let now: @Sendable () -> Date
    private let trackedFiles: @Sendable (String) async -> [String]
    private let fileManager: FileManager
    /// Keys asked this launch, with when. The store's stamp lands on its own
    /// queue, so without this a dictation right behind the first one could
    /// start a second run.
    private let asked = Mutex<[String: Date]>([:])

    package init(
        store: any ProjectTermProposalStoring,
        runner: any ProjectTermProposalRunning,
        now: @escaping @Sendable () -> Date,
        trackedFiles: @escaping @Sendable (String) async -> [String] = ProjectTermProposer.gitTrackedFiles,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.runner = runner
        self.now = now
        self.trackedFiles = trackedFiles
        self.fileManager = fileManager
    }

    /// Returns the task that asks, or nil when this dictation asks nothing:
    /// the setting is off, there was no join, or the join is not a local
    /// Claude Code or Vibe session. Tests await the task; the app drops it.
    ///
    /// - Parameter excluding: the user's own terms and the suggestions they
    ///   refused, which a proposal never repeats.
    @discardableResult
    package func dictationCommitted(
        join: ClaudeSessionSnapshot?,
        enabled: Bool,
        excluding: [String]
    ) -> Task<Void, Never>? {
        guard enabled, let request = ProjectTermProposal.request(for: join) else { return nil }
        return Task.detached(priority: .utility) { [self] in
            await propose(request, excluding: excluding)
        }
    }

    private func propose(_ request: ProjectTermProposal.Request, excluding: [String]) async {
        let directory = request.workspace.path
        let gitRoot = RepoIndexing.findGitRoot(startingAt: directory, fileManager: fileManager)
        let repositoryRoot: LearnedTermProjectResolver.RepositoryRoot = gitRoot.map {
            .root($0, mainCheckout: RepoIndexing.mainCheckout(ofRoot: $0, fileManager: fileManager))
        } ?? .noRepository
        guard let project = LearnedTermProjectResolver.resolve(
            repositoryRoot: repositoryRoot,
            workspace: .local(request.workspace)
        ), project.key.hasPrefix("/") else { return }

        let started = now()
        guard store.snapshot().needsProposal(projectKey: project.key, now: started),
              claim(project.key, at: started)
        else { return }

        let workingDirectory = gitRoot ?? directory
        let files = request.agent == .vibe && gitRoot != nil ? await trackedFiles(workingDirectory) : []
        let invocation = ProjectTermProposal.invocation(
            agent: request.agent,
            workingDirectory: workingDirectory,
            trackedFiles: files
        )
        Log.backends.info(
            "Project terms: asking \(request.agent.rawValue, privacy: .public) for a new project's terms"
        )
        switch await runner.run(invocation) {
        case .terms(let raw, let usage):
            let accepted = ProjectTermProposal.acceptedTerms(raw)
            Log.backends.info(
                "Project terms: \(request.agent.rawValue, privacy: .public) answered \(raw.count, privacy: .public) terms, \(accepted.count, privacy: .public) term-shaped (\(usage?.summary ?? "usage not reported", privacy: .public))"
            )
            asked.withLock { $0[project.key] = .distantFuture }
            store.recordProposal(accepted, agent: request.agent, project: project, excluding: excluding)
        case .failed(let failure):
            Log.backends.error(
                "Project terms: \(request.agent.rawValue, privacy: .public) run failed: \(String(describing: failure), privacy: .public); retrying after a day"
            )
            store.recordProposalFailure(project: project)
        }
    }

    /// True when no run for `key` started this launch within
    /// `ProjectTermProposal.retryAfter`, and marks one as started.
    private func claim(_ key: String, at moment: Date) -> Bool {
        asked.withLock { asked in
            if let last = asked[key], moment.timeIntervalSince(last) < ProjectTermProposal.retryAfter {
                return false
            }
            asked[key] = moment
            return true
        }
    }

    /// The first `ProjectTermProposal.maxListedFiles` tracked files, for
    /// Vibe's prompt.
    package static let gitTrackedFiles: @Sendable (String) async -> [String] = { root in
        guard let output = await RepoGitRunner.lsFiles(root: root), output.exitCode == 0 else { return [] }
        return Array(
            RepoIndexing.parseNullDelimitedPaths(output.data, maxEntries: ProjectTermProposal.maxListedFiles)
        )
    }
}
