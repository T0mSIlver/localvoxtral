import ClaudeContextWire
import Foundation
import Synchronization

/// Where the projects a remote host's hooks name are kept (`LearnedTermStore`).
package protocol RemoteProjectReportStoring: AgentActivityRecording {
    func snapshot() -> LearnedTerms
    func recordRemoteReport(project: LearnedTermProjectIdentity, asRepository: Bool, repository: String?, hostID: String?)
}

/// What a remote host's hooks tell the Mac about its projects (#819, #1027),
/// so the Projects pane lists the repositories sessions run in and a
/// repository checked out on a host and on the Mac is one project.
public final class RemoteProjectReports: @unchecked Sendable {
    /// A project a hook names is recorded at most this often (#819): hooks
    /// come several times a minute, and the file is written on each record.
    package static let reportInterval: TimeInterval = 3_600

    private struct State {
        /// Keyed by project and host: when a hook's report of it was last
        /// recorded, and whether as a repository.
        var reported: [String: (at: Date, asRepository: Bool, repository: String?)] = [:]
        /// Keyed by host: the last list of repositories its agents worked in
        /// that was recorded, and when.
        var agentProjects: [String: (at: Date, entries: [AgentProjectsCodec.Entry])] = [:]
    }

    private let state = Mutex(State())
    private let store: any RemoteProjectReportStoring
    private let now: @Sendable () -> Date

    package init(
        store: any RemoteProjectReportStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    /// Records the project an accepted remote hook's session is in. Every
    /// shim version counts: an old one names its cwd label, which only
    /// stamps a project already held.
    package func noteReport(for snapshot: ClaudeSessionSnapshot) {
        guard case .remote(let channel) = snapshot.origin,
              let hostID = ClaudeRemoteSessionScope.hostID(fromChannel: channel),
              case .remoteOpaque(let label)? = snapshot.learnedTermWorkspace,
              let project = LearnedTermProjectResolver.resolve(
                  repositoryRoot: .unknown, workspace: snapshot.learnedTermWorkspace
              ),
              project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix)
        else { return }
        let asRepository = snapshot.remoteProject == label
        // The host's origin names the repository only beside its name.
        let repository = asRepository
            ? snapshot.remoteEnvironment?.repository.flatMap { ProjectRemote(header: $0) == nil ? nil : $0 }
            : nil
        // A cwd label stamps only a project a dictation already added. Until
        // then this hook records nothing, so it must not take the interval:
        // the hook right after that dictation is the one to stamp (#891).
        guard asRepository || store.snapshot().projects.contains(where: { $0.key == project.key }) else { return }
        let moment = now()
        let reportKey = project.key + "\u{0}" + hostID
        let due = state.withLock { state -> Bool in
            if let last = state.reported[reportKey],
               moment.timeIntervalSince(last.at) < Self.reportInterval,
               last.asRepository || !asRepository,
               repository == nil || last.repository == repository
            {
                return false
            }
            state.reported[reportKey] = (moment, asRepository, repository ?? state.reported[reportKey]?.repository)
            return true
        }
        guard due else { return }
        store.recordRemoteReport(project: project, asRepository: asRepository, repository: repository, hostID: hostID)
    }

    /// A host's shim listed the repositories its agents worked in (#1027),
    /// on a SessionStart. Each is recorded under `remote:<name>`, the key
    /// its sessions' hooks name it by, and linked to its `origin`. The same
    /// list from the same host is recorded at most once per
    /// `reportInterval`.
    package func noteAgentProjects(_ entries: [AgentProjectsCodec.Entry], hostID: String) {
        let repositories = entries.compactMap { entry -> AgentWorkedRepository? in
            guard let remote = ProjectRemote(header: entry.repository) else { return nil }
            return AgentWorkedRepository(
                project: LearnedTermProjectIdentity(key: LearnedTermProjectResolver.remoteKeyPrefix + entry.name, name: entry.name),
                remote: remote,
                lastActive: entry.lastActive
            )
        }
        guard !repositories.isEmpty else { return }
        let moment = now()
        let due = state.withLock { state -> Bool in
            if let last = state.agentProjects[hostID], last.entries == entries,
               moment.timeIntervalSince(last.at) < Self.reportInterval
            {
                return false
            }
            state.agentProjects[hostID] = (moment, entries)
            return true
        }
        guard due else { return }
        store.recordAgentActivity(repositories, hostID: hostID)
    }
}
