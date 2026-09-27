import ClaudeContextWire
import Foundation
import Synchronization

/// Where a remote project's README summary is kept (`LearnedTermStore`).
package protocol RemoteProjectSummaryStoring: Sendable {
    func snapshot() -> LearnedTerms
    func recordSummary(_ summary: String?, projectKey: String)
}

/// Quick capture for remote projects (#745), on #641's channel: the Mac
/// asks on a hook's reply, and the host answers on its own request, because
/// the repository is on the host and the Mac holds only a label for it.
///
/// - **README.** A hook from a session in a remote project the learned
///   terms hold, with no summary or a week-old one, gets
///   `X-Lvx-Readme: wanted`. The host posts its README's opening to
///   `/v1/readme`, and the Mac keeps the summary on that project, where the
///   router reads it.
/// - **Draft.** `draft` waits for the next hook from a session in the
///   routed project and puts `X-Lvx-Draft: <id>` on its reply. The host
///   posts its open issues to `/v1/draft/prompt` and gets the drafting
///   prompt back, with the capture in it; it runs #731's read-only agent in
///   its checkout and posts the output to `/v1/draft`.
///
/// Each answer is taken once, only from the session the ask went to, and
/// is filed under the project the Mac recorded at the ask. The capture text
/// goes only to that session's host, and only in the prompt reply.
public final class RemoteQuickCaptureRequests: @unchecked Sendable {
    package static let readmePath = "/v1/readme"
    package static let draftPromptPath = "/v1/draft/prompt"
    package static let draftAnswerPath = "/v1/draft"
    /// The session an answer is for: the id the hook sent, before the Mac
    /// scoped it.
    package static let sessionHeaderName = "X-Lvx-Capture-Session"
    package static let draftIDHeaderName = "X-Lvx-Draft-Id"
    /// How the host's run ended: the agent's exit status, or `timeout`,
    /// `capped` or `missing`.
    package static let draftExitHeaderName = "X-Lvx-Draft-Exit"
    /// The first shims that read the two headers.
    package static let minimumPluginVersion = "1.17.0"
    package static let minimumVibeHooksVersion = "1.3.0"
    package static let maxReadmeBytes = QuickCaptureProjects.maxRemoteReadmeBytes
    /// `gh issue list` as the host trims it: 60 issues, 240-character bodies.
    package static let maxIssueListBytes = 48 * 1024
    /// The agent's stdout. Claude Code's JSON repeats the draft in `result`
    /// and `structured_output`, and the body is capped at 12,000 characters.
    package static let maxDraftAnswerBytes = 60 * 1024
    /// A project's README is asked for at most this often per launch.
    package static let readmeAskInterval: TimeInterval = 86_400
    /// An ask waits this long for its answer, and a draft this long for a
    /// hook from its project.
    package static let askLifetime: TimeInterval = 600
    /// A draft's run: the host's 240 s watchdog and 20 s for `gh`, with room.
    package static let draftRunLifetime: TimeInterval = 600

    private struct ReadmeAsk {
        let projectKey: String
        let askedAt: Date
    }

    private struct Draft {
        let projectKey: String
        let projectName: String
        let capture: String
        let createdAt: Date
        var sessionID: String?
        var agent: ProjectTermProposal.Agent?
        var askedAt: Date?
        /// The listed issues' numbers once the host fetched its prompt; nil
        /// before, and when the host's `gh` listed none.
        var openIssues: [Int]?
        var prompted = false
        let continuation: CheckedContinuation<QuickCaptureDraft.Outcome, Never>
    }

    private struct State {
        /// Keyed by the registry's session id.
        var readmeAsks: [String: ReadmeAsk] = [:]
        var readmeAsked: [String: Date] = [:]
        var drafts: [String: Draft] = [:]
    }

    private let state = Mutex(State())
    private let store: any RemoteProjectSummaryStoring
    private let hosts: ClaudeRemoteHostRegistry
    private let registry: ClaudeSessionRegistry
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let makeID: @Sendable () -> String

    package init(
        store: any RemoteProjectSummaryStoring,
        hosts: ClaudeRemoteHostRegistry,
        registry: ClaudeSessionRegistry,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        makeID: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.store = store
        self.hosts = hosts
        self.registry = registry
        self.now = now
        self.sleep = sleep
        self.makeID = makeID
    }

    // MARK: Which hosts read the asks

    /// Whether the host's highest reported shim for `agent` reads the asks.
    package static func hostReadsTheAsks(_ host: ClaudeRemoteHost, agent: ProjectTermProposal.Agent) -> Bool {
        switch agent {
        case .claude:
            guard let report = host.reportedPluginVersion else { return false }
            return report >= .version(minimumPluginVersion)
        case .vibe:
            guard let version = host.reportedVibeHooksVersion else { return false }
            return !ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: minimumVibeHooksVersion)
        case .opencode:
            return false
        }
    }

    /// Whether THIS request's shim reads them: a session started before an
    /// update keeps the old shim.
    package static func requestReadsTheAsks(
        agent: ClaudeHookAgent, plugin: ClaudeRemotePluginVersionReport, vibe: String?
    ) -> Bool {
        switch agent {
        case .claude:
            return plugin >= .version(minimumPluginVersion)
        case .vibe:
            guard let vibe else { return false }
            return !ClaudeRemotePluginVersionCodec.isVersion(vibe, olderThan: minimumVibeHooksVersion)
        case .opencode, .codex:
            return false
        }
    }

    private static func remoteProjectKey(of workspace: ClaudeWorkspaceReference?) -> String? {
        guard case .remoteOpaque? = workspace,
              let project = LearnedTermProjectResolver.resolve(repositoryRoot: .unknown, workspace: workspace),
              project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix)
        else { return nil }
        return project.key
    }

    // MARK: The asks, on an accepted hook's reply

    package struct Asks: Equatable, Sendable {
        package var readme = false
        package var draftID: String?
    }

    /// What the reply to this accepted hook asks. `snapshot` is the
    /// session's record after the hook, and the caller has checked that the
    /// request's own shim reads the headers.
    package func asks(for snapshot: ClaudeSessionSnapshot) -> Asks {
        guard let agent = ProjectTermProposal.Agent(snapshot.agent), agent != .opencode,
              case .remote = snapshot.origin,
              let key = Self.remoteProjectKey(of: snapshot.learnedTermWorkspace)
        else { return Asks() }
        let moment = now()
        let needsSummary = store.snapshot().needsSummary(projectKey: key, now: moment)
        var asks = Asks()
        state.withLock { state in
            prune(&state, now: moment)
            if let id = state.drafts
                .filter({ $0.value.projectKey == key && $0.value.sessionID == nil })
                .min(by: { $0.value.createdAt < $1.value.createdAt })?.key
            {
                state.drafts[id]?.sessionID = snapshot.sessionID
                state.drafts[id]?.agent = agent
                state.drafts[id]?.askedAt = moment
                asks.draftID = id
            }
            if needsSummary,
               state.readmeAsks[snapshot.sessionID] == nil,
               state.readmeAsked[key].map({ moment.timeIntervalSince($0) >= Self.readmeAskInterval }) ?? true
            {
                state.readmeAsked[key] = moment
                state.readmeAsks[snapshot.sessionID] = ReadmeAsk(projectKey: key, askedAt: moment)
                asks.readme = true
            }
        }
        if asks.readme {
            Log.backends.info("Quick capture: asking a remote host for its project's README")
        }
        if asks.draftID != nil {
            Log.backends.info("Quick capture: asking a remote \(agent.rawValue, privacy: .public) session's host to draft")
        }
        return asks
    }

    // MARK: README

    /// Keeps the summary of a README opening the Mac asked `sessionID` for.
    /// False when it did not ask, or the ask expired; nothing is kept then.
    package func acceptReadme(sessionID: String, readme: Data) -> Bool {
        let moment = now()
        let key = state.withLock { state -> String? in
            prune(&state, now: moment)
            return state.readmeAsks.removeValue(forKey: sessionID)?.projectKey
        }
        guard let key else { return false }
        store.recordSummary(QuickCaptureProjects.summary(ofRemoteReadme: readme), projectKey: key)
        return true
    }

    // MARK: Draft

    /// Has a remote project's host draft `capture`. Returns once the host
    /// answers, when no session of the project is live on a host that reads
    /// the ask, or when an ask or run outlives its lifetime.
    package func draft(capture: String, project: QuickCaptureProject) async -> QuickCaptureDraft.Outcome {
        guard project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) else {
            return .notRun(.remoteProject)
        }
        var sessionFound = false
        var hostReads = false
        for session in registry.liveSessions() {
            guard case .remote = session.origin,
                  Self.remoteProjectKey(of: session.learnedTermWorkspace) == project.key,
                  let agent = ProjectTermProposal.Agent(session.agent), agent != .opencode,
                  let hostID = ClaudeRemoteSessionScope.hostID(fromScopedSessionID: session.sessionID),
                  let host = hosts.host(id: hostID), !host.isRevoked
            else { continue }
            sessionFound = true
            if Self.hostReadsTheAsks(host, agent: agent) { hostReads = true }
        }
        guard hostReads else {
            Log.backends.info(
                "Quick capture draft: \(sessionFound ? "the remote host's shim predates drafting" : "no live session of the remote project", privacy: .public)"
            )
            return .notRun(sessionFound ? .hostNeedsUpdate : .noHostSession)
        }
        let id = makeID()
        let createdAt = now()
        Log.backends.info("Quick capture draft: waiting for a hook from the remote project")
        let sleep = sleep
        let timer = Mutex<Task<Void, Never>?>(nil)
        let outcome = await withCheckedContinuation { continuation in
            state.withLock { state in
                state.drafts[id] = Draft(
                    projectKey: project.key,
                    projectName: project.name,
                    capture: capture,
                    createdAt: createdAt,
                    continuation: continuation
                )
            }
            // Started once the draft is registered, so an early expiry finds it.
            timer.withLock {
                $0 = Task { [weak self] in
                    await sleep(Self.askLifetime)
                    guard let self, !Task.isCancelled else { return }
                    guard self.isAsked(id) else {
                        self.finish(id, with: .notRun(.noHostSession), because: "no hook from the project")
                        return
                    }
                    await sleep(Self.draftRunLifetime)
                    guard !Task.isCancelled else { return }
                    self.finish(id, with: .failed(.timedOut), because: "the host's run did not answer")
                }
            }
        }
        timer.withLock { $0?.cancel() }
        return outcome
    }

    private func isAsked(_ id: String) -> Bool {
        state.withLock { $0.drafts[id]?.askedAt != nil }
    }

    private func finish(_ id: String, with outcome: QuickCaptureDraft.Outcome, because reason: String) {
        guard let draft = state.withLock({ $0.drafts.removeValue(forKey: id) }) else { return }
        Log.backends.error("Quick capture draft: remote draft ended: \(reason, privacy: .public)")
        draft.continuation.resume(returning: outcome)
    }

    /// The drafting prompt for the host that was asked, once. `issueList` is
    /// the host's `gh issue list --json number,title,body`, or empty when its
    /// `gh` listed nothing; it is untrusted and only ever quoted in the
    /// prompt. Nil when this session was not asked for this draft.
    package func prompt(draftID: String, sessionID: String, agent: ProjectTermProposal.Agent, issueList: Data) -> String? {
        let issues = issueList.isEmpty ? nil : QuickCaptureDraft.parseIssueList(issueList)
        return state.withLock { state -> String? in
            guard var draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  !draft.prompted
            else { return nil }
            let listed = issues.map { Array($0.prefix(QuickCaptureDraft.maxListedIssues)) }
            draft.prompted = true
            draft.openIssues = listed?.map(\.number)
            state.drafts[draftID] = draft
            return QuickCaptureDraft.prompt(capture: draft.capture, projectName: draft.projectName, issues: listed)
        }
    }

    /// The host's run, for the draft whose prompt this session fetched.
    /// False when it did not, or `exit` is not one the runner sends; the
    /// draft keeps waiting then.
    package func acceptDraft(
        draftID: String, sessionID: String, agent: ProjectTermProposal.Agent, exit: String?, output: Data
    ) -> Bool {
        let taken = state.withLock { state -> Draft? in
            guard let draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  draft.prompted
            else { return nil }
            return draft
        }
        guard let taken, let outcome = Self.outcome(exit: exit, output: output, agent: agent, openIssues: taken.openIssues ?? [])
        else { return false }
        guard let draft = state.withLock({ $0.drafts.removeValue(forKey: draftID) }) else { return false }
        switch outcome {
        case .draft(let result, let usage):
            Log.backends.info(
                "Quick capture draft: remote \(agent.rawValue, privacy: .public) drafted, relation \(result.relation.rawValue, privacy: .public) (\(usage?.summary ?? "usage not reported", privacy: .public))"
            )
        case .failed(let failure):
            Log.backends.error(
                "Quick capture draft: remote \(agent.rawValue, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
            )
        case .notRun:
            break
        }
        draft.continuation.resume(returning: outcome)
        return true
    }

    static func outcome(
        exit: String?, output: Data, agent: ProjectTermProposal.Agent, openIssues: [Int]
    ) -> QuickCaptureDraft.Outcome? {
        switch exit {
        case "timeout": return .failed(.timedOut)
        case "capped": return .failed(.outputTooLarge)
        case "missing": return .failed(.agentNotFound)
        case let code?:
            guard (1...3).contains(code.utf8.count), code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let status = Int32(code), status <= 255
            else { return nil }
            switch agent {
            case .claude: return QuickCaptureDraft.parseClaude(stdout: output, exitCode: status, openIssues: openIssues)
            case .vibe: return QuickCaptureDraft.parseVibeText(stdout: output, exitCode: status, openIssues: openIssues)
            case .opencode: return nil
            }
        case nil:
            return nil
        }
    }

    /// The session id an answer names, in the shape both shims send: 1 to 64
    /// ASCII letters, digits and `-`.
    package static func sessionID(in headers: [String: String]) -> String? {
        guard let value = headers[sessionHeaderName.lowercased()] else { return nil }
        return RemoteProjectTermRequests.answerSessionID(
            in: [RemoteProjectTermRequests.answerSessionHeaderName.lowercased(): value]
        )
    }

    private func prune(_ state: inout State, now moment: Date) {
        state.readmeAsks = state.readmeAsks.filter { moment.timeIntervalSince($0.value.askedAt) < Self.askLifetime }
    }
}
