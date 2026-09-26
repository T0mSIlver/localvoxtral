import ClaudeContextWire
import Foundation
import Synchronization

/// The remote half of #609 (#641): a project on an enrolled host gets its
/// agent's terms from a run ON THE HOST, because the repository is there and
/// the Mac never holds a remote path.
///
/// The Mac only asks, in three steps, each bound to its own record of one
/// session:
/// 1. `request`, at commit: a joined remote Claude Code or Vibe session in a
///    project with no stamp marks that session as wanting terms, in memory,
///    and stamps an attempt on the project.
/// 2. `takeMark`, in the listener: the session's next accepted hook gets
///    `X-Lvx-Terms: wanted` on its reply, once. The host shim starts its
///    runner.
/// 3. `takeAnswerSlot` and `accept`, on `POST /v1/terms`: the answer is
///    stored under the project captured in step 1, never one the host names.
///
/// Nothing a host sends can open a slot: only the Mac's own commit does.
public final class RemoteProjectTermRequests: @unchecked Sendable {
    /// The answer's route, and the request header naming the session it
    /// answers for: the id the hook sent, before the Mac scoped it.
    package static let answerPath = "/v1/terms"
    package static let answerSessionHeaderName = "X-Lvx-Terms-Session"
    /// The runner posts the first 8 KiB of the agent's stdout.
    package static let maxAnswerBytes = 8 * 1024
    /// A mark waits this long for its session's next hook, and an asked
    /// session this long for the answer (the runner's watchdog is 180 s).
    package static let markLifetime: TimeInterval = 600
    package static let answerLifetime: TimeInterval = 600
    /// The first shims that read the header. An older one ignores it, so the
    /// Mac never asks a host that has not reported at least these.
    package static let minimumPluginVersion = "1.15.0"
    package static let minimumVibeHooksVersion = "1.2.0"

    package struct Pending: Equatable, Sendable {
        package let agent: ProjectTermProposal.Agent
        package let project: LearnedTermProjectIdentity
        package let excluding: [String]
        package let markedAt: Date
        /// When the header went out; nil while it waits for a hook.
        package var askedAt: Date?
    }

    private struct State {
        /// Keyed by the registry's session id (`remote:<host>:<id>`, with
        /// `vibe:` in front for Vibe).
        var pending: [String: Pending] = [:]
        /// Project keys asked this launch, with when. The store's stamp lands
        /// on its own queue, so this is what stops a second dictation right
        /// behind the first from marking again.
        var asked: [String: Date] = [:]
    }

    private let state = Mutex(State())
    private let store: any ProjectTermProposalStoring
    private let hosts: ClaudeRemoteHostRegistry
    private let now: @Sendable () -> Date

    package init(
        store: any ProjectTermProposalStoring,
        hosts: ClaudeRemoteHostRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.hosts = hosts
        self.now = now
    }

    // MARK: Step 1, at commit

    /// Marks `join` as wanting terms when it is a remote Claude Code or Vibe
    /// session, its host's shim reads the header, and its project has no
    /// stamp. Returns whether it marked. Runs on the commit path: no I/O
    /// beyond the in-memory store snapshot.
    @discardableResult
    package func request(for join: ClaudeSessionSnapshot, excluding: [String]) -> Bool {
        guard case .remote = join.origin,
              let agent = ProjectTermProposal.Agent(join.agent),
              let hostID = ClaudeRemoteSessionScope.hostID(fromScopedSessionID: join.sessionID),
              let host = hosts.host(id: hostID), !host.isRevoked,
              Self.hostReadsTheHeader(host, agent: agent),
              case .remoteOpaque? = join.learnedTermWorkspace,
              let project = LearnedTermProjectResolver.resolve(
                  repositoryRoot: .unknown, workspace: join.learnedTermWorkspace
              ),
              project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix)
        else { return false }

        let moment = now()
        guard store.snapshot().needsProposal(projectKey: project.key, now: moment) else { return false }
        let claimed = state.withLock { state -> Bool in
            prune(&state, now: moment)
            if let last = state.asked[project.key],
               moment.timeIntervalSince(last) < ProjectTermProposal.retryAfter
            {
                return false
            }
            state.asked[project.key] = moment
            state.pending[join.sessionID] = Pending(
                agent: agent, project: project, excluding: excluding, markedAt: moment, askedAt: nil
            )
            return true
        }
        guard claimed else { return false }
        // The attempt stamp: a host that never answers is asked again after
        // `ProjectTermProposal.retryAfter`, like a failed local run.
        store.recordProposalFailure(project: project)
        Log.backends.info(
            "Project terms: asking a remote \(agent.rawValue, privacy: .public) session's host for a new project's terms"
        )
        return true
    }

    /// Whether the host's recorded shim version for `agent` reads the header.
    package static func hostReadsTheHeader(_ host: ClaudeRemoteHost, agent: ProjectTermProposal.Agent) -> Bool {
        switch agent {
        case .claude:
            guard let report = host.reportedPluginVersion else { return false }
            return report >= .version(minimumPluginVersion)
        case .vibe:
            guard let version = host.reportedVibeHooksVersion else { return false }
            return !ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: minimumVibeHooksVersion)
        }
    }

    // MARK: Step 2, the next hook's reply

    /// True once per mark: the reply to this accepted hook carries the
    /// header. `sessionID` is the registry's key for the hook's session.
    package func takeMark(sessionID: String) -> Bool {
        let moment = now()
        return state.withLock { state in
            prune(&state, now: moment)
            guard var pending = state.pending[sessionID], pending.askedAt == nil else { return false }
            pending.askedAt = moment
            state.pending[sessionID] = pending
            return true
        }
    }

    // MARK: Step 3, the answer

    /// The asked slot for `sessionID`, removed: one answer per ask. Nil when
    /// the session was not asked, the header has not gone out yet, the ask
    /// expired, or the agent differs from the one asked.
    package func takeAnswerSlot(sessionID: String, agent: ProjectTermProposal.Agent) -> Pending? {
        let moment = now()
        return state.withLock { state in
            prune(&state, now: moment)
            guard let pending = state.pending[sessionID], pending.askedAt != nil, pending.agent == agent
            else { return nil }
            state.pending[sessionID] = nil
            return pending
        }
    }

    /// Reads an answer body (`{"terms": [...]}`, bare or in one code fence)
    /// and stores its term-shaped entries as `slot`'s proposals. Nil when the
    /// body is not that shape; nothing is stored then.
    package func accept(answer: Data, slot: Pending) -> Int? {
        #if DEBUG
        debugAnswerObserver.withLock { $0 }?(answer.count)
        #endif
        guard let text = String(data: answer, encoding: .utf8),
              let raw = ProjectTermProposal.termsObject(in: text)
        else { return nil }
        let accepted = ProjectTermProposal.acceptedTerms(raw)
        store.recordProposal(accepted, agent: slot.agent, project: slot.project, excluding: slot.excluding)
        return accepted.count
    }

    #if DEBUG
    private let debugAnswerObserver = Mutex<(@Sendable (Int) -> Void)?>(nil)

    /// The byte count of every answer body that reached `accept`, for the
    /// live check's report.
    package func debugObserveAnswers(_ observer: (@Sendable (Int) -> Void)?) {
        debugAnswerObserver.withLock { $0 = observer }
    }
    #endif

    /// The session id an answer names, when it is shaped like the ids both
    /// shims send: 1 to 64 ASCII letters, digits and `-`.
    package static func answerSessionID(in headers: [String: String]) -> String? {
        guard let value = headers[answerSessionHeaderName.lowercased()],
              (1...64).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                      || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                      || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                      || byte == UInt8(ascii: "-")
              })
        else { return nil }
        return value
    }

    private func prune(_ state: inout State, now moment: Date) {
        state.pending = state.pending.filter { _, pending in
            if let asked = pending.askedAt {
                return moment.timeIntervalSince(asked) < Self.answerLifetime
            }
            return moment.timeIntervalSince(pending.markedAt) < Self.markLifetime
        }
    }
}
