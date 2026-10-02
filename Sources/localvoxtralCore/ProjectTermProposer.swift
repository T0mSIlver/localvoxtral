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
        line: String?,
        revision: Int?,
        agent: ProjectTermProposal.Agent,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    )
    func recordProposalFailure(project: LearnedTermProjectIdentity)
    /// A checkout's `origin` names `remote` (#971); for an ignored one, the
    /// checkout joins its entry (#1006).
    func recordOrigin(_ remote: ProjectRemote, projectKey: String)
}

extension ProjectTermProposalStoring {
    /// A store that keeps no repository links has nothing to record.
    package func recordOrigin(_ remote: ProjectRemote, projectKey: String) {}
}

/// Asks a project's coding agent for its terms after the first joined
/// dictation there (#609; opencode, #642).
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
    private let origin: @Sendable (String) async -> ProjectRemote?
    private let fileManager: FileManager
    /// Keys asked this launch, with when. The store's stamp lands on its own
    /// queue, so without this a dictation right behind the first one could
    /// start a second run.
    private let asked = Mutex<[String: Date]>([:])
    /// Where a remote session's ask goes (#641). Attached once the remote
    /// listener exists; nil on a Mac with no enrolled host.
    private let remoteRequests = Mutex<RemoteProjectTermRequests?>(nil)
    private let usageRecorder: (any UsageRecording)?
    /// The mods of joined Claude Code sessions, which can answer from the
    /// session's own transcript (#1410). Attached with the broker.
    private let sessionChannels = Mutex<ClaudeModChannelHub?>(nil)

    package init(
        store: any ProjectTermProposalStoring,
        runner: any ProjectTermProposalRunning,
        now: @escaping @Sendable () -> Date,
        trackedFiles: @escaping @Sendable (String) async -> [String] = ProjectTermProposer.gitTrackedFiles,
        origin: @escaping @Sendable (String) async -> ProjectRemote? = ProjectTermProposer.gitOrigin,
        fileManager: FileManager = .default,
        usageRecorder: (any UsageRecording)? = nil
    ) {
        self.usageRecorder = usageRecorder
        self.store = store
        self.runner = runner
        self.now = now
        self.trackedFiles = trackedFiles
        self.origin = origin
        self.fileManager = fileManager
    }

    /// The remote half, handed over by whoever builds the remote listener.
    package func attachRemote(_ requests: RemoteProjectTermRequests?) {
        remoteRequests.withLock { $0 = requests }
    }

    package func attachSessionChannels(_ hub: ClaudeModChannelHub?) {
        sessionChannels.withLock { $0 = hub }
    }

    /// Returns the task that asks, or nil when this dictation starts no local
    /// run: the setting is off, there was no join, or the join is not local.
    /// A remote Claude Code or Vibe join is
    /// handed to `RemoteProjectTermRequests`, which only marks the session
    /// for its host to run on. Tests await the task; the app drops it.
    ///
    /// - Parameter excluding: the user's own terms and the suggestions they
    ///   refused, which a proposal never repeats.
    @discardableResult
    package func dictationCommitted(
        join: ClaudeSessionSnapshot?,
        enabled: Bool,
        excluding: [String]
    ) -> Task<Void, Never>? {
        guard enabled, let join else { return nil }
        guard let request = ProjectTermProposal.request(for: join) else {
            if case .remote = join.origin {
                remoteRequests.withLock { $0 }?.request(for: join, excluding: excluding)
            }
            return nil
        }
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
        guard store.snapshot().needsProposal(projectKey: project.key, now: started, revision: ProjectTermProposal.promptRevision),
              claim(project.key, at: started)
        else { return }

        // A new clone of an ignored repo has no record yet to say so; its
        // `origin` does (#1006).
        if let gitRoot, let remote = await origin(gitRoot),
           store.snapshot().isIgnored(projectKey: project.key, remote: remote)
        {
            Log.backends.info("Project terms: not asking, the repository is ignored")
            // Links the checkout, so the store drops what it learned there
            // and knows its key from now on.
            store.recordOrigin(remote, projectKey: project.key)
            return
        }
        let workingDirectory = gitRoot ?? directory
        let files: [String]
        if request.agent == .vibe {
            files = gitRoot != nil
                ? await trackedFiles(workingDirectory)
                : Self.topLevelFiles(in: workingDirectory, fileManager: fileManager)
        } else {
            files = []
        }
        let invocation = ProjectTermProposal.invocation(
            agent: request.agent,
            workingDirectory: workingDirectory,
            trackedFiles: files
        )
        Log.backends.info(
            "Project terms: asking \(request.agent.rawValue, privacy: .public) for a new project's terms"
        )
        let outcome: ProjectTermProposal.Outcome
        if let answered = await askSession(request, at: started) {
            outcome = answered
        } else {
            outcome = await runner.run(invocation)
        }
        switch outcome {
        case .terms(let raw, let usage, let line):
            usageRecorder?.record(.agentRun(date: now(), feature: .projectTerms, agent: request.agent, usage: usage))
            let accepted = ProjectTermProposal.acceptedTerms(raw)
            Log.backends.info(
                "Project terms: \(request.agent.rawValue, privacy: .public) answered \(raw.count, privacy: .public) terms, \(accepted.count, privacy: .public) term-shaped, \(line.flatMap(ProjectTermProposal.acceptedLine) == nil ? "no" : "a", privacy: .public) description (\(usage?.summary ?? "usage not reported", privacy: .public))"
            )
            asked.withLock { $0[project.key] = .distantFuture }
            // This run's prompt asked for the sentence: an answer without one
            // still counts as answered, so the project is not asked daily.
            store.recordProposal(
                accepted, line: line ?? "", revision: ProjectTermProposal.promptRevision, agent: request.agent,
                project: project, excluding: excluding)
        case .failed(let failure):
            if failure.agentRan {
                usageRecorder?.record(.agentRun(date: now(), feature: .projectTerms, agent: request.agent, usage: nil))
            }
            Log.backends.error(
                "Project terms: \(request.agent.rawValue, privacy: .public) run failed: \(String(describing: failure), privacy: .public); retrying after a day"
            )
            store.recordProposalFailure(project: project)
        }
    }

    /// The joined session's own answer through its mod, or nil: not a
    /// Claude Code session, too young, its cache likely gone, no mod, or no
    /// usable answer. Nil runs the one-shot agent instead.
    private func askSession(_ request: ProjectTermProposal.Request, at moment: Date) async -> ProjectTermProposal.Outcome? {
        guard let session = request.session,
              ProjectTermProposal.sessionMayAnswer(session, now: moment),
              let hub = sessionChannels.withLock({ $0 }),
              hub.isAttached(session.id)
        else { return nil }
        Log.backends.info("Project terms: asking the joined session through its mod")
        let reply = await hub.send(
            .init(kind: .terms, text: ProjectTermProposal.forkPrompt),
            to: session.id,
            timeout: .seconds(ProjectTermProposal.timeoutSeconds)
        )
        guard let reply, reply.ok, let text = reply.text,
              let outcome = ProjectTermProposal.outcome(forkAnswer: text, usage: reply.usage)
        else {
            Log.backends.error(
                "Project terms: the session did not answer (\(reply?.reason ?? (reply == nil ? "no reply" : "no answer object"), privacy: .public)); running the agent"
            )
            return nil
        }
        return outcome
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

    /// Outside a repository, Vibe's prompt lists the directory's own visible
    /// files instead: without a list its unified harness guesses names until
    /// the turn limit, and the run would fail again every day.
    static func topLevelFiles(in directory: String, fileManager: FileManager) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return Array(
            names
                .filter { name in
                    var isDirectory: ObjCBool = false
                    return !name.hasPrefix(".")
                        && fileManager.fileExists(atPath: directory + "/" + name, isDirectory: &isDirectory)
                        && !isDirectory.boolValue
                }
                .sorted()
                .prefix(ProjectTermProposal.maxListedFiles)
        )
    }

    /// The repository `origin` names, from git alone: no gh, whose answer
    /// can be an upstream's.
    package static let gitOrigin: @Sendable (String) async -> ProjectRemote? = { root in
        guard let output = await RepoGitRunner.run(
            arguments: ["remote", "get-url", "origin"], root: root, timeoutSeconds: 20, maxBytes: 4096
        ), !output.timedOut, output.exitCode == 0
        else { return nil }
        return ProjectRemote(remoteURL: String(decoding: output.data, as: UTF8.self))
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
