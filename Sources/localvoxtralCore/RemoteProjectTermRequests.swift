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
    /// The runner posts the first 16 KiB of the agent's stdout. Claude
    /// Code's result object carries the terms twice beside its usage: 3.4 KiB
    /// for 40 terms on this repository (2026-09-27).
    package static let maxAnswerBytes = 16 * 1024
    /// A Vibe run's token counts, from its host's shim (1.19.0 plugin, 1.4.0
    /// Vibe hooks) on `/v1/terms` and `/v1/draft`: `<input> <cached input>
    /// <output>`, decimal. Claude Code's ride in its result object instead.
    package static let usageHeaderName = "X-Lvx-Usage"
    /// A mark waits this long for its session's next hook, and an asked
    /// session this long for the answer (the runner's watchdog is 180 s).
    package static let markLifetime: TimeInterval = 600
    package static let answerLifetime: TimeInterval = 600
    /// The first shims that read the header. An older one ignores it, so the
    /// Mac never asks a host that has not reported at least these.
    package static let minimumPluginVersion = "1.15.0"
    package static let minimumVibeHooksVersion = "1.2.0"
    /// The first shims whose runner asks for the project's sentence too
    /// (#891). A project answered before is asked again only through them.
    package static let minimumLinePluginVersion = "1.20.0"
    package static let minimumLineVibeHooksVersion = "1.5.0"
    /// The first shims whose runner asks for names people say (#914,
    /// `ProjectTermProposal.promptRevision` 3).
    package static let minimumSpokenPluginVersion = "1.21.0"
    package static let minimumSpokenVibeHooksVersion = "1.6.0"

    package struct Pending: Equatable, Sendable {
        package let agent: ProjectTermProposal.Agent
        package let project: LearnedTermProjectIdentity
        package let excluding: [String]
        /// The prompt revision the host's runner asks with.
        package let revision: Int
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
    private let usageRecorder: (any UsageRecording)?

    package init(
        store: any ProjectTermProposalStoring,
        hosts: ClaudeRemoteHostRegistry,
        now: @escaping @Sendable () -> Date = { Date() },
        usageRecorder: (any UsageRecording)? = nil
    ) {
        self.usageRecorder = usageRecorder
        self.store = store
        self.hosts = hosts
        self.now = now
    }

    // MARK: Step 1, at commit

    /// Marks `join` as wanting terms when it is a remote Claude Code or Vibe
    /// session (opencode has no host shim), its host's shim reads the header, and its project has no
    /// stamp. Returns whether it marked. Runs on the commit path: no I/O
    /// beyond the in-memory store snapshot.
    @discardableResult
    package func request(for join: ClaudeSessionSnapshot, excluding: [String]) -> Bool {
        guard let agent = ProjectTermProposal.Agent(join.agent),
              case .remote = join.origin,
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
        let revision = Self.hostPromptRevision(host, agent: agent)
        guard store.snapshot().needsProposal(projectKey: project.key, now: moment, revision: revision)
        else { return false }
        let claimed = state.withLock { state -> Bool in
            prune(&state, now: moment)
            if let last = state.asked[project.key],
               moment.timeIntervalSince(last) < ProjectTermProposal.retryAfter
            {
                return false
            }
            state.asked[project.key] = moment
            state.pending[join.sessionID] = Pending(
                agent: agent, project: project, excluding: excluding, revision: revision, markedAt: moment,
                askedAt: nil
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
        case .opencode:
            return false
        }
    }

    /// The prompt revision the host's recorded shim for `agent` asks with:
    /// 3 asks for names people say (#914), 2 for the project's sentence too
    /// (#891), 1 for terms only.
    package static func hostPromptRevision(_ host: ClaudeRemoteHost, agent: ProjectTermProposal.Agent) -> Int {
        func atLeast(_ minimum: String) -> Bool {
            switch agent {
            case .claude:
                guard let report = host.reportedPluginVersion else { return false }
                return report >= .version(minimum)
            case .vibe:
                guard let version = host.reportedVibeHooksVersion else { return false }
                return !ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: minimum)
            case .opencode:
                return false
            }
        }
        let spoken = agent == .vibe ? minimumSpokenVibeHooksVersion : minimumSpokenPluginVersion
        let line = agent == .vibe ? minimumLineVibeHooksVersion : minimumLinePluginVersion
        if atLeast(spoken) { return 3 }
        return atLeast(line) ? 2 : 1
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

    /// Reads an answer body and stores its term-shaped entries as `slot`'s
    /// proposals, and its sentence on the project (#891). The body is Claude
    /// Code's result object from a 1.19.0 shim, or `{"terms": [...],
    /// "description": "..."}`, bare or in one code fence (Vibe, and an older
    /// shim). `reportedUsage` is a Vibe run's `X-Lvx-Usage`. Nil when the
    /// body is neither shape; nothing is stored then.
    package func accept(answer: Data, slot: Pending, reportedUsage: ProjectTermProposal.Usage? = nil) -> Int? {
        #if DEBUG
        debugAnswerObserver.withLock { $0 }?(answer.count)
        #endif
        let (parsed, usage) = Self.parse(answer: answer, agent: slot.agent)
        // The host ran the agent whatever it answered; a run that reported
        // nothing (an older shim) is counted, unpriced.
        usageRecorder?.record(
            .agentRun(date: now(), feature: .projectTerms, agent: slot.agent, usage: usage ?? reportedUsage))
        guard let parsed else { return nil }
        let accepted = ProjectTermProposal.acceptedTerms(parsed.terms)
        // Asked for the sentence and answered without one (Vibe has no
        // schema flag): still answered, or the host's `done` stamp would
        // leave the Mac asking daily for nothing.
        store.recordProposal(
            accepted, line: parsed.line ?? (slot.revision >= 2 ? "" : nil), revision: slot.revision,
            agent: slot.agent, project: slot.project, excluding: slot.excluding)
        return accepted.count
    }

    /// The terms and usage in a host's answer. Only Claude Code's result
    /// object (`"type": "result"`) carries usage.
    static func parse(
        answer: Data, agent: ProjectTermProposal.Agent
    ) -> (answer: ProjectTermProposal.Answer?, usage: ProjectTermProposal.Usage?) {
        if agent == .claude,
           let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
           object["type"] as? String == "result"
        {
            switch ProjectTermProposal.parseClaude(stdout: answer, exitCode: 0) {
            case .terms(let terms, let usage, let line):
                return (ProjectTermProposal.Answer(terms: terms, line: line), usage)
            case .failed: return (nil, nil)
            }
        }
        guard let text = String(data: answer, encoding: .utf8) else { return (nil, nil) }
        return (ProjectTermProposal.answerObject(in: text), nil)
    }

    /// A Vibe run's counts from `X-Lvx-Usage`: three decimal numbers of at
    /// most ten digits, one space apart. Anything else reads as no usage.
    package static func reportedUsage(in headers: [String: String]) -> ProjectTermProposal.Usage? {
        guard let value = headers[usageHeaderName.lowercased()] else { return nil }
        let fields = value.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({ (1...10).contains($0.utf8.count) && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } })
        else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return VibeSessionUsage.usage(inputTokens: numbers[0], cachedInputTokens: numbers[1], outputTokens: numbers[2])
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
