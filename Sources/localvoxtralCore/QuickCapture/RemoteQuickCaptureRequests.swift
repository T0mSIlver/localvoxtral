import ClaudeContextWire
import Foundation
import Synchronization

/// Where a remote project's README summary is kept (`LearnedTermStore`).
package protocol RemoteProjectSummaryStoring: AgentActivityRecording {
    func snapshot() -> LearnedTerms
    func recordSummary(_ summary: String?, projectKey: String)
    func recordRemoteReport(project: LearnedTermProjectIdentity, asRepository: Bool, repository: String?, hostID: String?)
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
///   routed project and puts `X-Lvx-Draft: <id>` on its reply. A host whose
///   shim sends context (#918: plugin 1.24.0, Vibe hooks 1.9.0) asks
///   `/v1/draft/words` for the capture's search words, posts its context
///   bundle (`QuickCaptureContext`) to `/v1/draft/context`, and polls
///   `/v1/draft/check` while the Mac writes the first draft: 202 to wait,
///   204 when no check is due, 200 with the check's prompt. An older shim
///   posts its open issues to `/v1/draft/prompt` and gets the prompt to
///   draft from scratch. Either way the host runs #731's read-only agent in
///   its checkout and posts the output to `/v1/draft`.
///
/// Each answer is taken once, only from the session the ask went to, and
/// is filed under the project the Mac recorded at the ask. The capture text
/// goes only to that session's host, and only in the prompt reply.
public final class RemoteQuickCaptureRequests: @unchecked Sendable {
    package static let readmePath = "/v1/readme"
    package static let draftPromptPath = "/v1/draft/prompt"
    package static let draftAnswerPath = "/v1/draft"
    package static let draftWordsPath = "/v1/draft/words"
    package static let draftContextPath = "/v1/draft/context"
    package static let draftCheckPath = "/v1/draft/check"
    /// The session an answer is for: the id the hook sent, before the Mac
    /// scoped it.
    package static let sessionHeaderName = "X-Lvx-Capture-Session"
    package static let draftIDHeaderName = "X-Lvx-Draft-Id"
    /// How the host's run ended: the agent's exit status, or `timeout`,
    /// `capped` or `missing`.
    package static let draftExitHeaderName = "X-Lvx-Draft-Exit"
    /// The repository the host listed issues in: its origin's (#1682). A
    /// shim that sends none lists issues that link nothing.
    package static let issuesRepositoryHeaderName = "X-Lvx-Issues-Repository"
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
    /// An ask waits this long for its answer. A draft checks this often
    /// that its project still has a live session to wait for.
    package static let askLifetime: TimeInterval = 600
    /// A draft's run once asked: the host's context (`gh` and `git grep`,
    /// 20 s each), the first draft (up to 120 s), the check's 360 s
    /// watchdog, with room.
    package static let draftRunLifetime: TimeInterval = 720
    /// A project a hook names is recorded at most this often (#819): hooks
    /// come several times a minute, and the file is written on each record.
    package static let reportInterval: TimeInterval = 3_600

    private struct ReadmeAsk {
        let projectKey: String
        let askedAt: Date
    }

    private struct Draft {
        let projectKey: String
        let projectName: String
        /// Where the capture files: a listed issue may be linked only when
        /// the host listed this repository's.
        let filingRepository: String?
        let capture: String
        let createdAt: Date
        let firstDrafter: (any QuickCaptureFirstDrafting)?
        let onFirstDraft: QuickCaptureDrafter.FirstDraftHandler
        var sessionID: String?
        var agent: ProjectTermProposal.Agent?
        var askedAt: Date?
        /// The listed issues' numbers once the host sent them; nil before,
        /// and when the host's `gh` listed none.
        var openIssues: [Int]?
        var wordsSent = false
        var contextReceived = false
        /// The check's prompt once the first draft is in; `.none` when no
        /// check is due.
        var check: CheckPrompt = .pending
        var prompted = false
        let continuation: CheckedContinuation<QuickCaptureDraft.Outcome?, Never>
    }

    private enum CheckPrompt {
        case pending
        case ready(String)
        case none
    }

    private struct State {
        /// Keyed by the registry's session id.
        var readmeAsks: [String: ReadmeAsk] = [:]
        var readmeAsked: [String: Date] = [:]
        var drafts: [String: Draft] = [:]
        /// Drafts that ended with no check due, so the host's next poll
        /// hears 204 rather than a refusal.
        var noCheck: [String: Date] = [:]
        /// Keyed by project and host: when a hook's report of it was last
        /// recorded, and whether as a repository.
        var reported: [String: (at: Date, asRepository: Bool, repository: String?)] = [:]
        /// Keyed by host: the last list of repositories its agents worked in
        /// that was recorded, and when.
        var agentProjects: [String: (at: Date, entries: [AgentProjectsCodec.Entry])] = [:]
    }

    private let state = Mutex(State())
    private let store: any RemoteProjectSummaryStoring
    private let hosts: ClaudeRemoteHostRegistry
    private let registry: ClaudeSessionRegistry
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let makeID: @Sendable () -> String
    private let usageRecorder: (any UsageRecording)?

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
        },
        usageRecorder: (any UsageRecording)? = nil
    ) {
        self.usageRecorder = usageRecorder
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

    // MARK: Which projects the hooks name

    /// Records the project an accepted remote hook's session is in, so quick
    /// capture lists the repositories sessions run in and not a label none
    /// reports any more (#819). Every shim version counts: an old one names
    /// its cwd label, which only stamps a project already held.
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
            Log.backends.notice("Quick capture: asking a remote \(agent.rawValue, privacy: .public) session's host to draft")
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

    /// Has a remote project's host draft `capture`, in two stages when its
    /// shim sends context. Returns the check once the host answers, nil
    /// when no check was due, or why none ran: no session of the project is
    /// live on a host that reads the ask, or the host's run outlived its
    /// lifetime.
    package func draft(
        capture: String,
        project: QuickCaptureProject,
        firstDrafter: (any QuickCaptureFirstDrafting)? = nil,
        onFirstDraft: @escaping QuickCaptureDrafter.FirstDraftHandler = { _ in true }
    ) async -> QuickCaptureDraft.Outcome? {
        guard project.key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) else {
            return .notRun(.remoteProject)
        }
        let (sessionFound, hostReads) = liveSessions(of: project.key)
        guard hostReads else {
            Log.backends.notice(
                "Quick capture draft: \(sessionFound ? "the remote host's shim predates drafting" : "no live session of the remote project", privacy: .public)"
            )
            return .notRun(sessionFound ? .hostNeedsUpdate : .noHostSession)
        }
        let id = makeID()
        let createdAt = now()
        Log.backends.notice("Quick capture draft: waiting for a hook from the remote project")
        let sleep = sleep
        let timer = Mutex<Task<Void, Never>?>(nil)
        let outcome = await withCheckedContinuation { continuation in
            state.withLock { state in
                state.drafts[id] = Draft(
                    projectKey: project.key,
                    projectName: project.name,
                    filingRepository: project.issueRepository,
                    capture: capture,
                    createdAt: createdAt,
                    firstDrafter: firstDrafter,
                    onFirstDraft: onFirstDraft,
                    continuation: continuation
                )
            }
            // Started once the draft is registered, so an early expiry finds it.
            timer.withLock {
                $0 = Task { [weak self] in
                    // A session sends hooks only while it works, and the
                    // user may capture while every session of the project
                    // is idle: the draft waits for as long as one is live.
                    while true {
                        await sleep(Self.askLifetime)
                        guard let self, !Task.isCancelled else { return }
                        if self.isAsked(id) { break }
                        guard self.liveSessions(of: project.key).hostReads else {
                            self.finish(id, with: .notRun(.noHostSession), because: "no hook from the project")
                            return
                        }
                    }
                    guard let self else { return }
                    await sleep(Self.draftRunLifetime)
                    guard !Task.isCancelled else { return }
                    self.finish(id, with: .failed(.timedOut), because: "the host's run did not answer")
                }
            }
        }
        timer.withLock { $0?.cancel() }
        return outcome
    }

    /// Whether a session of the project is live on an enrolled host, and
    /// whether one of those hosts' shims reads the asks.
    private func liveSessions(of projectKey: String) -> (sessionFound: Bool, hostReads: Bool) {
        var sessionFound = false
        var hostReads = false
        for session in registry.liveSessions() {
            guard case .remote = session.origin,
                  Self.remoteProjectKey(of: session.learnedTermWorkspace) == projectKey,
                  let agent = ProjectTermProposal.Agent(session.agent), agent != .opencode,
                  let hostID = ClaudeRemoteSessionScope.hostID(fromScopedSessionID: session.sessionID),
                  let host = hosts.host(id: hostID), !host.isRevoked
            else { continue }
            sessionFound = true
            if Self.hostReadsTheAsks(host, agent: agent) { hostReads = true }
        }
        return (sessionFound, hostReads)
    }

    private func isAsked(_ id: String) -> Bool {
        state.withLock { $0.drafts[id]?.askedAt != nil }
    }

    private func finish(_ id: String, with outcome: QuickCaptureDraft.Outcome?, because reason: String) {
        guard let draft = state.withLock({ $0.drafts.removeValue(forKey: id) }) else { return }
        Log.backends.error("Quick capture draft: remote draft ended: \(reason, privacy: .public)")
        // A host that fetched the prompt started its agent, answer or not.
        if draft.prompted, let agent = draft.agent, let outcome {
            QuickCaptureDraft.recordUsage(of: outcome, agent: agent, date: now(), to: usageRecorder)
        }
        draft.continuation.resume(returning: outcome)
    }

    /// The drafting prompt for a host whose shim predates first drafts,
    /// once: the agent drafts from scratch. `issueList` is the host's
    /// `gh issue list --json number,title,body`, or empty when its `gh`
    /// listed nothing; it is untrusted and only ever quoted in the prompt.
    /// `listedRepository` is the repository it says it listed: another than
    /// the capture's lists issues that are not the capture's, so none is
    /// quoted or linked. Nil when this session was not asked for this draft,
    /// or already sent context.
    package func prompt(
        draftID: String, sessionID: String, agent: ProjectTermProposal.Agent, issueList: Data,
        listedRepository: String? = nil
    ) -> String? {
        let issues = issueList.isEmpty ? nil : QuickCaptureDraft.parseIssueList(issueList)
        return state.withLock { state -> String? in
            guard var draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  !draft.prompted, !draft.contextReceived
            else { return nil }
            var listed = issues.map { Array($0.prefix(QuickCaptureDraft.maxListedIssues)) }
            if listed != nil, !Self.issuesLink(listed: listedRepository, filing: draft.filingRepository) {
                Log.backends.notice("Quick capture draft: the host listed another repository's issues; none quoted or linked")
                listed = nil
            }
            draft.prompted = true
            draft.openIssues = listed?.map(\.number)
            state.drafts[draftID] = draft
            return QuickCaptureDraft.prompt(capture: draft.capture, projectName: draft.projectName, issues: listed)
        }
    }

    // MARK: Two stages (#918)

    /// The capture's search words for the host's `git grep`, one per line,
    /// once. They are the capture's own words, going only where the capture
    /// itself goes. Nil when this session was not asked for this draft.
    package func words(draftID: String, sessionID: String, agent: ProjectTermProposal.Agent) -> String? {
        state.withLock { state -> String? in
            guard var draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  !draft.wordsSent, !draft.prompted
            else { return nil }
            draft.wordsSent = true
            state.drafts[draftID] = draft
            return QuickCaptureContext.searchWords(in: draft.capture).map { $0 + "\n" }.joined()
        }
    }

    /// The host's context bundle, once, from the session asked. Starts the
    /// first draft; the host polls `checkPrompt` for what follows. False
    /// when this session was not asked, or already answered. Open issues
    /// listed in another repository than the capture's (`listedRepository`,
    /// as in `prompt`) are dropped.
    package func acceptContext(
        draftID: String, sessionID: String, agent: ProjectTermProposal.Agent, bundle: Data,
        listedRepository: String? = nil
    ) -> Bool {
        var parsed = QuickCaptureContext.parse(bundle: bundle)
        var dropped = false
        let taken = state.withLock { state -> Draft? in
            guard var draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  !draft.contextReceived, !draft.prompted
            else { return nil }
            if parsed.openIssues != nil, !Self.issuesLink(listed: listedRepository, filing: draft.filingRepository) {
                parsed.openIssues = nil
                dropped = true
            }
            draft.contextReceived = true
            draft.openIssues = parsed.openIssues?.map(\.number)
            state.drafts[draftID] = draft
            return draft
        }
        guard let taken else { return false }
        if dropped {
            Log.backends.notice("Quick capture draft: the host listed another repository's issues; none quoted or linked")
        }
        let context = parsed
        Log.backends.notice(
            "Quick capture draft: remote context received: \(QuickCaptureDrafter.summary(of: context), privacy: .public)"
        )
        let now = now
        Task { [weak self] in
            var firstDraft: QuickCaptureDraft.Draft?
            var proceed = true
            if let firstDrafter = taken.firstDrafter {
                let started = now()
                let first = await firstDrafter.firstDraft(
                    capture: taken.capture, projectName: taken.projectName, context: context
                )
                QuickCaptureDrafter.logFirstDraft(first, seconds: QuickCaptureDrafter.seconds(since: started, now: now()))
                proceed = await taken.onFirstDraft(first)
                if case .draft(let draft, _) = first {
                    if draft.kind != .issue { proceed = false }
                    firstDraft = draft
                }
            }
            self?.setCheck(
                draftID: draftID,
                proceed
                    ? .ready(QuickCaptureDraft.prompt(
                        capture: taken.capture, projectName: taken.projectName,
                        issues: context.openIssues, firstDraft: firstDraft
                    ))
                    : .none
            )
        }
        return true
    }

    private func setCheck(draftID: String, _ check: CheckPrompt) {
        let ended = state.withLock { state -> Draft? in
            guard state.drafts[draftID] != nil else { return nil }
            if case .none = check {
                state.noCheck[draftID] = now()
                return state.drafts.removeValue(forKey: draftID)
            }
            state.drafts[draftID]?.check = check
            return nil
        }
        if let ended {
            Log.backends.notice("Quick capture draft: no check due for the remote draft")
            ended.continuation.resume(returning: nil)
        }
        #if DEBUG
        debugCheckDecided.withLock { $0 }()
        #endif
    }

    #if DEBUG
    /// Test seam: runs once a remote draft's check is decided, so a suite
    /// awaits it instead of polling `/v1/draft/check`.
    package let debugCheckDecided = Mutex<@Sendable () -> Void>({})
    #endif

    package enum CheckReply: Equatable, Sendable {
        /// Not asked, or the host skipped a step: refused.
        case notAsked
        /// The first draft is still being written: poll again.
        case wait
        /// No check is due: the host stops.
        case done
        /// The check's prompt; the host runs its agent on it.
        case prompt(String)
    }

    /// The host's poll after its context.
    package func checkPrompt(draftID: String, sessionID: String, agent: ProjectTermProposal.Agent) -> CheckReply {
        state.withLock { state -> CheckReply in
            if state.noCheck.removeValue(forKey: draftID) != nil { return .done }
            guard var draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  draft.contextReceived, !draft.prompted
            else { return .notAsked }
            switch draft.check {
            case .pending: return .wait
            case .none: return .done
            case .ready(let prompt):
                draft.prompted = true
                state.drafts[draftID] = draft
                return .prompt(prompt)
            }
        }
    }

    /// The host's run, for the draft whose prompt this session fetched.
    /// False when it did not, or `exit` is not one the runner sends; the
    /// draft keeps waiting then. `reportedUsage` is a Vibe run's
    /// `X-Lvx-Usage`; Claude Code's usage is in its output.
    package func acceptDraft(
        draftID: String, sessionID: String, agent: ProjectTermProposal.Agent, exit: String?, output: Data,
        reportedUsage: ProjectTermProposal.Usage? = nil
    ) -> Bool {
        let taken = state.withLock { state -> Draft? in
            guard let draft = state.drafts[draftID], draft.sessionID == sessionID, draft.agent == agent,
                  draft.prompted
            else { return nil }
            return draft
        }
        guard let taken,
              var outcome = Self.outcome(exit: exit, output: output, agent: agent, openIssues: taken.openIssues ?? [])?
                  .reporting(reportedUsage)
        else { return false }
        if case .draft(let result, let usage) = outcome {
            outcome = .draft(result.keepingFiles(result.filesRead, agent: agent), usage: usage)
        }
        guard let draft = state.withLock({ $0.drafts.removeValue(forKey: draftID) }) else { return false }
        QuickCaptureDraft.recordUsage(of: outcome, agent: agent, date: now(), to: usageRecorder)
        switch outcome {
        case .draft(let result, let usage):
            Log.backends.notice(
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

    /// Whether the issues a host listed in `listed` may be linked from a
    /// capture filed in `filing`: only when both are named and the same.
    static func issuesLink(listed: String?, filing: String?) -> Bool {
        guard let listed, let filing else { return false }
        return listed.caseInsensitiveCompare(filing) == .orderedSame
    }

    /// The repository a host's request says it listed issues in.
    package static func issuesRepository(in headers: [String: String]) -> String? {
        headers[issuesRepositoryHeaderName.lowercased()].flatMap { QuickCaptureInbox.isRepository($0) ? $0 : nil }
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
        state.noCheck = state.noCheck.filter { moment.timeIntervalSince($0.value) < Self.askLifetime }
    }
}
